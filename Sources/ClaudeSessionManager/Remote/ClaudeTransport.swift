import Foundation

/// The process behind a hosted session: writes JSON lines to the CLI's stdin
/// and delivers its stdout lines. A protocol so `HostedSession` can be driven
/// by recorded fixtures in tests.
@MainActor
protocol ClaudeTransport: AnyObject {
    /// Called on the main actor for every complete stdout line that is a JSON object.
    var onMessage: (([String: Any]) -> Void)? { get set }
    /// Called once when the process ends (exit status, last stderr text).
    var onExit: ((Int32, String) -> Void)? { get set }
    /// The child's pid while running (nil for fakes).
    var pid: Int32? { get }
    func start() throws
    func send(_ object: [String: Any])
    func terminate()
}

/// Launch options for one hosted `claude -p` process.
struct ClaudeLaunch: Equatable {
    var cwd: String
    /// Resume this session; nil starts a new one.
    var resume: String?
    var permissionMode: String = "default"
    var model: String?

    var arguments: [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--permission-prompt-tool", "stdio",
                 "--permission-mode", permissionMode]
        if let resume { a += ["--resume", resume] }
        if let model { a += ["--model", model] }
        return a
    }
}

/// Runs the real `claude` binary.
@MainActor
final class ProcessClaudeTransport: ClaudeTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    let launch: ClaudeLaunch
    private let process = Process()
    private let stdin = Pipe()
    private var stdoutBuffer = Data()
    private var stderrTail = ""

    init(launch: ClaudeLaunch) { self.launch = launch }

    /// The child's pid once started (so the host can tell its own processes
    /// apart from sessions running elsewhere).
    var pid: Int32? { process.isRunning ? process.processIdentifier : nil }

    func start() throws {
        guard let binary = ClaudeEnvironment.claudePath else {
            throw NSError(domain: "ClaudeSessionManager", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "Couldn't find the claude CLI. Install it, or make sure your login shell's PATH includes it."])
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        process.environment = ClaudeEnvironment.childEnvironment
        process.standardInput = stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            Task { @MainActor in self?.consume(stdout: chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.stderrTail = String((self?.stderrTail ?? "") + text).suffix(4000).description }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self?.onExit?(status, self?.stderrTail ?? "")
            }
        }
        try process.run()
    }

    func send(_ object: [String: Any]) {
        guard process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        stdin.fileHandleForWriting.write(data)
    }

    func terminate() {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.close()   // EOF lets the CLI finish cleanly…
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }       // …SIGTERM if it doesn't.
        }
    }

    private func consume(stdout chunk: Data) {
        guard !chunk.isEmpty else { return }
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                onMessage?(obj)
            }
        }
    }
}

/// Where `claude` is and what environment it should see. An app launched
/// from Finder has a minimal PATH, so both come from the user's login shell
/// (once), with Claude Code's own session markers removed — otherwise the
/// child would run as a nested session and not persist its transcript.
enum ClaudeEnvironment {
    static let loginEnvironment: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ProcessInfo.processInfo.environment }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
        }
        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }()

    static var childEnvironment: [String: String] {
        loginEnvironment.filter { key, _ in
            !(key == "CLAUDECODE" || key == "AI_AGENT" || key == "BAGGAGE"
              || key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_"))
        }
    }

    static let claudePath: String? = {
        let fm = FileManager.default
        let path = loginEnvironment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/claude" }
            + ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()
}
