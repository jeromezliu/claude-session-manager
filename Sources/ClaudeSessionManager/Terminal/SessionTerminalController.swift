import AppKit
import SwiftTerm

/// A standalone in-app terminal window that resumes one Claude session.
/// Uses SwiftTerm's `LocalProcessTerminalView`, which spawns a real PTY-backed
/// login shell; we then type `claude --resume <id>` into it for the user.
@MainActor
final class SessionTerminalController: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    private let session: SessionSummary
    private let onClose: () -> Void
    private let terminalView: LocalProcessTerminalView
    private var didExit = false

    init(session: SessionSummary, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose

        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        terminalView = LocalProcessTerminalView(frame: frame)
        terminalView.autoresizingMask = [.width, .height]

        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Continue · \(session.title)"
        window.contentView = terminalView
        window.center()
        window.tabbingMode = .disallowed

        super.init(window: window)

        window.delegate = self
        terminalView.processDelegate = self
        start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Launch

    private func start() {
        let fm = FileManager.default
        let cwd = fm.fileExists(atPath: session.workingDirectory) ? session.workingDirectory : NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Inherit the app environment so HOME/USER/PATH exist; a login shell
        // (-l) then augments PATH from the user's profile so `claude` resolves.
        var envDict = ProcessInfo.processInfo.environment
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        let env = envDict.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(executable: shell, args: ["-l"], environment: env,
                                  execName: nil, currentDirectory: cwd)

        // Give the shell a moment to source its profile, then type the command.
        // In test mode, run a harmless command instead of launching Claude.
        let command: String
        if ProcessInfo.processInfo.environment["CSM_TERM_TEST"] == "1" {
            command = "echo '### internal terminal OK'; echo \"cwd=$PWD\"; echo \"claude: $(command -v claude || echo NOT-FOUND)\"\n"
        } else {
            command = "claude --resume \(Self.shellQuote(session.id))\n"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.didExit else { return }
            let bytes = Array(command.utf8)
            self.terminalView.send(source: self.terminalView, data: bytes[...])
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window?.title = title.isEmpty ? "Continue · \(session.title)" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        didExit = true
        let suffix = exitCode.map { " · exit \($0)" } ?? ""
        terminalView.feed(text: "\r\n\u{1b}[2m[session ended\(suffix) — you can close this window]\u{1b}[0m\r\n")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !didExit { terminalView.terminate() }
        onClose()
    }
}
