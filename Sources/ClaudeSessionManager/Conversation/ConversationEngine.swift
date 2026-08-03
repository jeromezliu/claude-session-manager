import Foundation
import Combine

/// Drives a native, chat-style conversation with Claude Code for one session by
/// spawning `claude -p … --output-format stream-json` per turn and parsing the
/// streamed events into renderable `TranscriptEvent`s. Follow-up turns resume
/// the session id emitted by the previous turn's `init` event, so the real
/// `~/.claude/projects` transcript keeps growing (persistence preserved).
///
/// Tool use is governed by the `permissionMode` the user picks — headless
/// `claude -p` runs tools per that mode and the user's existing allow/deny
/// rules; it does not surface answerable per-tool prompts.
@MainActor
final class ConversationEngine: ObservableObject, Identifiable {
    let session: SessionSummary
    var id: String { session.id }

    /// Rendered conversation: prior transcript (seeded) + live turns appended.
    @Published private(set) var messages: [TranscriptEvent] = []
    @Published private(set) var isRunning = false
    /// Human-readable current action, e.g. "Thinking", "Running: npm test".
    @Published private(set) var phase: String = ""
    /// Seconds elapsed in the current turn (ticks while running).
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queued: [String] = []
    @Published var errorText: String?

    /// Model + permission mode — initialised from the session's last-used values.
    @Published var model: String = "default"
    @Published var permissionMode: String = "default"

    /// Conversation mode drives a local `claude`; remote sessions keep the terminal.
    var isSupported: Bool { !session.isRemote }

    /// The real session this conversation has been writing to, once its first
    /// turn created it. Lets "Open Terminal" on a brand-new session resume the
    /// same session (preserving history) instead of starting a fresh one.
    var liveSessionSummary: SessionSummary? {
        guard let sid = currentSessionID, !sid.isEmpty else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(TerminalSession.encodedFolder(for: workingDir))
            .appendingPathComponent("\(sid).jsonl")
        return SessionParser.summary(for: url)
    }

    /// A brand-new session with no id yet (first turn omits `--resume`).
    let isDraft: Bool
    /// Called once when a draft's real session id first appears, so the manager
    /// can re-key this engine and the list can find it.
    var onAdoptSessionID: ((String) -> Void)?

    private var currentSessionID: String?
    private var workingDir: String

    private var process: Process?
    private var stderrTail = ""
    private var gotResult = false
    private var didAdopt = false
    private var nextID = 2_000_000_000
    private var turnStart: Date?
    private var turnTimer: Timer?

    init(session: SessionSummary, isDraft: Bool = false) {
        self.session = session
        self.isDraft = isDraft
        self.currentSessionID = session.id.isEmpty ? nil : session.id
        let fm = FileManager.default
        self.workingDir = fm.fileExists(atPath: session.workingDirectory)
            ? session.workingDirectory : NSHomeDirectory()
        // Seed with the existing transcript so the chat reads as one continuous
        // conversation. Best-effort; a brand-new/empty session just starts blank.
        self.messages = isDraft ? [] : SessionParser.transcript(for: session.fileURL)
        if let last = messages.map(\.id).max() { nextID = max(nextID, last + 1) }
        // Pick up the model / permission mode the session was last using.
        if !isDraft {
            let s = Self.detectSettings(session.fileURL)
            model = s.model
            permissionMode = s.permissionMode
        }
    }

    // MARK: - Sending

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard isSupported else {
            errorText = "Conversation mode is local-only. Use the terminal for remote sessions."
            return
        }
        // `!command` is a local shell escape (like the interactive CLI): run it
        // in the session's directory and show the output directly, instead of
        // routing it through the model (whose Bash-tool output the chat hides).
        if prompt.hasPrefix("!") {
            let cmd = String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty { runLocalShell(cmd) }
            return
        }
        append(kind: .user, blocks: [.text(prompt)])
        if isRunning {
            queued.append(prompt)          // chain behind the running turn
        } else {
            startTurn(prompt)
        }
    }

    func stop() {
        queued.removeAll()
        if let p = process, p.isRunning { p.terminate() }
    }

    // MARK: - Turn lifecycle

    private func startTurn(_ prompt: String) {
        isRunning = true
        gotResult = false
        errorText = nil
        stderrTail = ""
        phase = "Thinking"
        turnStart = Date()
        elapsed = 0
        turnTimer?.invalidate()
        turnTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.turnStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }

        // Headless `claude -p` governs tools by permission mode + the user's
        // existing allow/deny rules; it does not surface per-tool prompts we
        // can answer (verified against the CLI). So the mode IS the control.
        var args = ["-p", prompt,
                    "--output-format", "stream-json",
                    "--verbose",
                    "--permission-mode", permissionMode]
        if let sid = currentSessionID, !sid.isEmpty { args += ["--resume", sid] }
        if model != "default" { args += ["--model", model] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ClaudeCLI.binaryPath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        proc.environment = ClaudeCLI.turnEnvironment()

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Some modes (e.g. `manual`) wait on stdin for a control channel we
        // don't speak; hand them an immediate EOF so a turn can never stall.
        proc.standardInput = FileHandle.nullDevice

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                DispatchQueue.main.async { self.handle(obj) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.stderrTail += s }
        }
        proc.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self.turnDidExit(code: code) }
        }

        do {
            try proc.run()
        } catch {
            isRunning = false
            errorText = "Failed to launch claude: \(error.localizedDescription)"
            return
        }
        process = proc
    }

    private func turnDidExit(code: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        turnTimer?.invalidate()
        turnTimer = nil
        turnStart = nil

        if !gotResult && code != 0 {
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            errorText = tail.isEmpty ? "claude exited with code \(code)" : tail
        }
        isRunning = false
        phase = ""

        // Dispatch the next queued prompt, resuming the (possibly new) session id.
        if !queued.isEmpty {
            let next = queued.removeFirst()
            startTurn(next)
        }
    }

    // MARK: - Stream parsing

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "system":
            if obj["subtype"] as? String == "init",
               let sid = obj["session_id"] as? String, !sid.isEmpty {
                currentSessionID = sid       // resume THIS id on the next turn
                if isDraft && !didAdopt {     // a new session just got its real id
                    didAdopt = true
                    onAdoptSessionID?(sid)
                }
            }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return }
            let model = msg["model"] as? String
            var blocks: [TranscriptEvent.Block] = []
            for b in (msg["content"] as? [[String: Any]] ?? []) {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.isEmpty {
                        blocks.append(.text(t)); phase = "writing"
                    }
                case "thinking":
                    if let t = b["thinking"] as? String, !t.isEmpty {
                        blocks.append(.thinking(t)); phase = "thinking"
                    }
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    let input = b["input"] as? [String: Any] ?? [:]
                    blocks.append(.toolUse(name: name, input: Self.prettyJSON(b["input"])))
                    phase = Self.describe(tool: name, input: input)
                default:
                    break
                }
            }
            if !blocks.isEmpty { append(kind: .assistant, blocks: blocks, model: model) }
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return }
            var blocks: [TranscriptEvent.Block] = []
            for b in (msg["content"] as? [[String: Any]] ?? []) where b["type"] as? String == "tool_result" {
                let isError = b["is_error"] as? Bool ?? false
                blocks.append(.toolResult(text: Self.stringifyToolResult(b["content"]), isError: isError))
            }
            if !blocks.isEmpty { append(kind: .system, blocks: blocks) }
        case "result":
            gotResult = true
            if obj["is_error"] as? Bool == true {
                errorText = (obj["result"] as? String) ?? "Claude reported an error"
            }
            append(kind: .meta, blocks: [.note(resultNote(obj))])
        default:
            break
        }
    }

    private func resultNote(_ obj: [String: Any]) -> String {
        var parts: [String] = []
        if let ms = obj["duration_ms"] as? Int, ms > 0 {
            parts.append(String(format: "%.1fs", Double(ms) / 1000))
        }
        if let cost = obj["total_cost_usd"] as? Double, cost > 0 {
            parts.append(String(format: "$%.4f", cost))
        }
        return parts.isEmpty ? "done" : "done · " + parts.joined(separator: " · ")
    }

    // MARK: - Local shell escape (`!cmd`)

    private func runLocalShell(_ cmd: String) {
        append(kind: .user, blocks: [.text("! " + cmd)])
        let dir = workingDir
        Task.detached(priority: .userInitiated) {
            let output = Self.runShell(cmd, cwd: dir)
            await MainActor.run { self.append(kind: .shell, blocks: [.text(output)]) }
        }
    }

    /// Run one shell command via the login shell (so PATH/aliases resolve),
    /// returning combined stdout+stderr with a trailing exit-code note on
    /// failure. Reads the pipe to EOF before waiting, so large output can't
    /// deadlock the process.
    nonisolated static func runShell(_ cmd: String, cwd: String) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "failed to run: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            let note = "[exit \(p.terminationStatus)]"
            out = out.isEmpty ? note : out + "\n" + note
        }
        return out.isEmpty ? "(no output)" : out
    }

    private func append(kind: TranscriptEvent.Kind, blocks: [TranscriptEvent.Block], model: String? = nil) {
        let event = TranscriptEvent(id: nextID, kind: kind, timestamp: Date(), model: model, blocks: blocks)
        nextID += 1
        messages.append(event)
    }

    // MARK: - JSON helpers

    static func prettyJSON(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        if let d = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return String(describing: any)
    }

    static func stringifyToolResult(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return prettyJSON(any)
    }

    // MARK: - Session settings + activity labels

    private static let knownModes: Set<String> = ["plan", "default", "acceptEdits", "bypassPermissions"]

    /// Best-effort read of the last model + permission mode the session used.
    static func detectSettings(_ url: URL) -> (model: String, permissionMode: String) {
        var model = "default"
        var mode = "default"
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return (model, mode) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "permission-mode":
                if let p = o["permissionMode"] as? String, knownModes.contains(p) { mode = p }
            case "assistant":
                // Keep the concrete id (e.g. claude-opus-4-8) rather than an
                // alias, so the picker shows exactly what the session ran and
                // a follow-up turn stays on that same model.
                if let m = (o["message"] as? [String: Any])?["model"] as? String,
                   m != "<synthetic>", !m.isEmpty {
                    model = m
                }
            default:
                break
            }
        }
        return (model, mode)
    }

    /// A short human label for what a tool call is doing.
    static func describe(tool: String, input: [String: Any]) -> String {
        func base(_ key: String) -> String {
            ((input[key] as? String) as NSString?)?.lastPathComponent ?? ""
        }
        switch tool {
        case "Bash":
            let cmd = (input["command"] as? String ?? "")
                .split(separator: "\n").first.map(String.init) ?? ""
            return "Running: " + (cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd)
        case "Read":            return "Reading \(base("file_path"))"
        case "Write":           return "Writing \(base("file_path"))"
        case "Edit", "MultiEdit": return "Editing \(base("file_path"))"
        case "Grep":            return "Searching code"
        case "Glob":            return "Finding files"
        case "WebFetch":        return "Fetching \(input["url"] as? String ?? "a page")"
        case "WebSearch":       return "Searching the web"
        case "Task":            return "Running a subagent"
        case "TodoWrite":       return "Updating the task list"
        default:                return tool
        }
    }
}
