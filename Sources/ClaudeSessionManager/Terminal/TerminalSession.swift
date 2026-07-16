import AppKit
import SwiftUI
import SwiftTerm

/// Owns one running session terminal: a PTY-backed `LocalProcessTerminalView`
/// plus the process behind it. The view can be hosted either embedded in the
/// detail split or in a floating window — reparenting the view does not affect
/// the underlying process, so it moves freely between the two.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    let id: String
    let session: SessionSummary
    let view: ActivityTerminalView
    let activity = TerminalActivity()

    @Published var isPoppedOut = false
    @Published var hasExited = false
    /// For new (fresh) sessions: the real session file Claude created, once
    /// detected. The detail pane uses this so the actual conversation shows.
    @Published var adoptedSummary: SessionSummary?

    /// Summary to display: the adopted real session if known, else the original.
    var displaySummary: SessionSummary { adoptedSummary ?? session }

    private var windowController: NSWindowController?
    private let onEnd: (String) -> Void
    private let resume: Bool
    private var adoptAttempts = 0

    init(session: SessionSummary, resume: Bool = true, onEnd: @escaping (String) -> Void) {
        self.id = session.id
        self.session = session
        self.resume = resume
        self.onEnd = onEnd
        self.view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        super.init()
        view.processDelegate = self
        view.onOutput = { [weak self] in self?.activity.noteOutput() }
        start()
    }

    // MARK: - Launch

    private func start() {
        let fm = FileManager.default
        let cwd = fm.fileExists(atPath: session.workingDirectory) ? session.workingDirectory : NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var envDict = ProcessInfo.processInfo.environment

        // CRITICAL: strip Claude Code / Anthropic session markers the app may
        // have inherited (e.g. when launched from within a Claude session). If
        // `claude` sees CLAUDECODE / CLAUDE_CODE_SESSION_ID / etc. it runs as a
        // nested child and does NOT persist the interactive transcript to
        // ~/.claude/projects — so resumed work would silently vanish. Removing
        // them makes the embedded terminal a clean, top-level Claude session.
        for key in envDict.keys where
            key == "CLAUDECODE" || key == "AI_AGENT" || key == "BAGGAGE" ||
            key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") {
            envDict.removeValue(forKey: key)
        }

        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        let env = envDict.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: shell, args: ["-l"], environment: env,
                          execName: nil, currentDirectory: cwd)

        let command: String
        if ProcessInfo.processInfo.environment["CSM_TERM_TEST"] == "1" {
            command = "echo '### internal terminal OK'; echo \"cwd=$PWD\"\n"
        } else if resume {
            command = "claude --resume \(Self.shellQuote(session.id))\n"
        } else {
            command = "claude\n"   // brand-new session
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.hasExited else { return }
            let bytes = Array(command.utf8)
            self.view.send(source: self.view, data: bytes[...])
        }

        // For a brand-new session, watch the project folder for the real session
        // file Claude creates, then adopt it so the detail shows the transcript.
        if !resume && ProcessInfo.processInfo.environment["CSM_TERM_TEST"] != "1" {
            beginAdoption(cwd: cwd)
        }
    }

    // MARK: - New-session adoption

    /// Claude encodes a cwd into a projects folder name by replacing every
    /// non-alphanumeric character with "-" (verified against real folders:
    /// "/", ".", spaces and "~" all become "-").
    static func encodedFolder(for path: String) -> String {
        String(path.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    private func beginAdoption(cwd: String) {
        let projectsRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        let projectDir = projectsRoot.appendingPathComponent(Self.encodedFolder(for: cwd))
        let existing = Self.jsonlIDs(in: projectDir)
        pollForAdoption(projectDir: projectDir, existing: existing)
    }

    private static func jsonlIDs(in dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "jsonl" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    private func pollForAdoption(projectDir: URL, existing: Set<String>) {
        adoptAttempts += 1
        guard adoptedSummary == nil, !hasExited, adoptAttempts <= 80 else { return }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: projectDir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let fresh = files.filter {
            $0.pathExtension == "jsonl" && !existing.contains($0.deletingPathExtension().lastPathComponent)
        }
        let newest = fresh.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        // Adopt only once a real conversation turn exists (not just startup metadata).
        if let newest, let summary = SessionParser.summary(for: newest), summary.messageCount > 0 {
            adoptedSummary = summary
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pollForAdoption(projectDir: projectDir, existing: existing)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Embed / pop out

    func popOut() {
        if isPoppedOut {
            windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PoppedTerminalView(session: self))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 900, height: 560))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Continue · \(session.title)"
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        let wc = NSWindowController(window: window)
        windowController = wc
        isPoppedOut = true
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring the floating window back into the main-window split (keeps running).
    func popIn() {
        windowController?.window?.close()   // triggers windowWillClose cleanup
    }

    func focus() {
        if isPoppedOut { windowController?.window?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func terminate() {
        if !hasExited { view.terminate() }
        if let w = windowController?.window {
            w.delegate = nil
            w.close()
        }
        windowController = nil
        onEnd(id)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        windowController?.window?.title = title.isEmpty ? "Continue · \(session.title)" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
        activity.stop()
        let suffix = exitCode.map { " · exit \($0)" } ?? ""
        view.feed(text: "\r\n\u{1b}[2m[session ended\(suffix) — close this terminal]\u{1b}[0m\r\n")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard isPoppedOut else { return }
        // Detach the view so it survives the window and can re-embed.
        view.removeFromSuperview()
        windowController = nil
        isPoppedOut = false
    }
}
