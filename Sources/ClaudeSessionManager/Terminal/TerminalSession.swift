import AppKit
import SwiftUI
import SwiftTerm

/// Owns one running session terminal: a PTY-backed `LocalProcessTerminalView`
/// plus the process behind it. The view can be hosted either embedded in the
/// detail split or in a floating window — reparenting the view does not affect
/// the underlying process, so it moves freely between the two.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    /// The manager's key for this terminal. For a new session it starts as a
    /// synthetic id and is re-keyed to the real session id once adopted.
    var id: String
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
    /// Called when a new session's real file is detected: (oldID, realSummary).
    private let onAdopt: ((String, SessionSummary) -> Void)?
    private let resume: Bool
    /// The resolved host config for a remote-tagged session — supplies the
    /// ssh destination, port, and auth for the PTY-backed `ssh` process.
    private let remoteHost: RemoteHost?
    /// Set only for a brand-new session on a remote host (`resume == false`);
    /// used to poll for the session file via scoped rsync instead of local FS.
    private let newSessionHost: RemoteHost?
    private let hostStore: RemoteHostStore?

    init(session: SessionSummary, resume: Bool = true, remoteHost: RemoteHost? = nil,
         newSessionHost: RemoteHost? = nil, hostStore: RemoteHostStore? = nil,
         onAdopt: ((String, SessionSummary) -> Void)? = nil,
         onEnd: @escaping (String) -> Void) {
        self.id = session.id
        self.session = session
        self.resume = resume
        self.remoteHost = remoteHost ?? newSessionHost
        self.newSessionHost = newSessionHost
        self.hostStore = hostStore
        self.onAdopt = onAdopt
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

        let command: String
        let sendDelay: TimeInterval
        let localAdoptionCwd: String

        if session.isRemote {
            guard let host = remoteHost else {
                hasExited = true
                view.feed(text: "\r\n\u{1b}[31mThis session's remote host is no longer configured.\u{1b}[0m\r\n")
                return
            }
            // Remote: the PTY-backed process is `ssh` itself; `cd` into the
            // remote cwd once connected instead of using `currentDirectory`
            // (which only applies to the local ssh client process). Password
            // auth is auto-answered from the Keychain via the askpass helper.
            let envDict = RemoteShell.environment(for: host, base: envDict)
            let env = envDict.map { "\($0.key)=\($0.value)" }
            view.startProcess(executable: "/usr/bin/ssh",
                              args: ["-t"] + RemoteShell.sshArgs(for: host, context: .interactive),
                              environment: env,
                              execName: nil, currentDirectory: NSHomeDirectory())
            sendDelay = 1.5   // SSH handshake is slower than a local shell login
            localAdoptionCwd = ""   // unused: remote adoption doesn't touch the local FS
            if ProcessInfo.processInfo.environment["CSM_TERM_TEST"] == "1" {
                command = "echo '### internal terminal OK'; echo \"cwd=$PWD\"\n"
            } else if resume {
                command = "cd \(RemoteShell.quoteRemotePath(session.workingDirectory)) 2>/dev/null; " +
                          "claude --resume \(RemoteShell.shellQuote(session.id))\n"
            } else {
                // No 2>/dev/null here: if the typed directory doesn't exist,
                // the user should see cd's error instead of Claude silently
                // starting a session in the remote home directory.
                command = "cd \(RemoteShell.quoteRemotePath(session.workingDirectory)) && claude\n"
            }
        } else {
            let env = envDict.map { "\($0.key)=\($0.value)" }
            let cwd = fm.fileExists(atPath: session.workingDirectory) ? session.workingDirectory : NSHomeDirectory()
            view.startProcess(executable: shell, args: ["-l"], environment: env,
                              execName: nil, currentDirectory: cwd)
            sendDelay = 0.6
            localAdoptionCwd = cwd
            if ProcessInfo.processInfo.environment["CSM_TERM_TEST"] == "1" {
                command = "echo '### internal terminal OK'; echo \"cwd=$PWD\"\n"
            } else if resume {
                command = "claude --resume \(RemoteShell.shellQuote(session.id))\n"
            } else {
                command = "claude\n"   // brand-new session
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelay) { [weak self] in
            guard let self, !self.hasExited else { return }
            let bytes = Array(command.utf8)
            self.view.send(source: self.view, data: bytes[...])
        }

        // For a brand-new session, watch for the real session file Claude
        // creates, then adopt it so the detail shows the transcript.
        if !resume && ProcessInfo.processInfo.environment["CSM_TERM_TEST"] != "1" {
            if let host = newSessionHost, let hostStore {
                beginAdoptionRemote(host: host, hostStore: hostStore, remoteDir: session.workingDirectory)
            } else {
                beginAdoption(cwd: localAdoptionCwd)
            }
        }
    }

    // MARK: - New-session adoption

    /// Claude encodes a cwd into a projects folder name by replacing every
    /// non-alphanumeric character with "-" (verified against real folders:
    /// "/", ".", spaces and "~" all become "-").
    nonisolated static func encodedFolder(for path: String) -> String {
        String(path.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    private func beginAdoption(cwd: String) {
        let projectDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(Self.encodedFolder(for: cwd))
        let existing = Self.jsonlIDs(in: projectDir)
        Task { await pollForAdoption(in: projectDir, existing: existing, remote: nil) }
    }

    /// Remote counterpart of `beginAdoption`: there's no local FS to watch, so
    /// each poll tick scoped-rsyncs the one project folder first, then checks
    /// the mirrored copy with the same logic as the local path.
    private func beginAdoptionRemote(host: RemoteHost, hostStore: RemoteHostStore, remoteDir: String) {
        Task { [weak self] in
            // Claude derives the projects folder name from the *absolute* cwd,
            // so a typed `~/x` or relative path must be resolved on the host
            // first — otherwise this would poll a folder that never appears.
            var dir = remoteDir
            if let out = try? await RemoteShell.sshRun(
                    host: host,
                    remoteCommand: "cd \(RemoteShell.quoteRemotePath(remoteDir)) && pwd"),
               out.succeeded {
                let resolved = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !resolved.isEmpty { dir = resolved }
            }
            guard let self else { return }
            let encoded = Self.encodedFolder(for: dir)
            let localDir = hostStore.localCacheDir(for: host).appendingPathComponent(encoded, isDirectory: true)
            await self.pollForAdoption(in: localDir, existing: Self.jsonlIDs(in: localDir),
                                       remote: (host, hostStore, encoded))
        }
    }

    private static func jsonlIDs(in dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "jsonl" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Poll `dir` (every 1.5s, up to 2 minutes) for a session file that wasn't
    /// there before launch, and adopt it once it holds a real conversation turn
    /// (not just startup metadata). For a remote host, the folder is re-synced
    /// from the host before each check.
    private func pollForAdoption(in dir: URL, existing: Set<String>,
                                 remote: (host: RemoteHost, store: RemoteHostStore, folder: String)?) async {
        for _ in 0..<80 {
            guard adoptedSummary == nil, !hasExited else { return }
            if let remote { await remote.store.syncProjectFolder(remote.host, remote.folder) }

            if let newest = Self.newestJSONL(in: dir, excluding: existing),
               var summary = SessionParser.summary(for: newest), summary.messageCount > 0 {
                if let host = remote?.host {
                    summary = summary.withRemote(hostID: host.id, displayName: host.displayName)
                }
                let oldID = id
                adoptedSummary = summary
                onAdopt?(oldID, summary)   // let the manager re-key this terminal to the real id
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private static func newestJSONL(in dir: URL, excluding existing: Set<String>) -> URL? {
        let key = URLResourceKey.contentModificationDateKey
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [key])) ?? []
        let mtime = { (u: URL) in (try? u.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast }
        return files
            .filter { $0.pathExtension == "jsonl" && !existing.contains($0.deletingPathExtension().lastPathComponent) }
            .max { mtime($0) < mtime($1) }
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
