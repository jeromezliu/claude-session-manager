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

    private var windowController: NSWindowController?
    private let onEnd: (String) -> Void

    init(session: SessionSummary, onEnd: @escaping (String) -> Void) {
        self.id = session.id
        self.session = session
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
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        let env = envDict.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: shell, args: ["-l"], environment: env,
                          execName: nil, currentDirectory: cwd)

        let command: String
        if ProcessInfo.processInfo.environment["CSM_TERM_TEST"] == "1" {
            command = "echo '### internal terminal OK'; echo \"cwd=$PWD\"; echo \"claude: $(command -v claude || echo NOT-FOUND)\"\n"
        } else {
            command = "claude --resume \(Self.shellQuote(session.id))\n"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.hasExited else { return }
            let bytes = Array(command.utf8)
            self.view.send(source: self.view, data: bytes[...])
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
