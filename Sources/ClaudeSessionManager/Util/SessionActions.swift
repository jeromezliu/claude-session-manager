import Foundation
import AppKit

/// File-level operations on sessions. Kept deliberately conservative so we never
/// corrupt a transcript that Claude Code might resume later.
enum SessionActions {

    enum ActionError: LocalizedError {
        case renameFailed(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .renameFailed(let m): return "Rename failed: \(m)"
            case .launchFailed(let m): return "Couldn't continue session: \(m)"
            }
        }
    }

    /// Rename by appending a fresh `ai-title` event line — exactly what Claude Code
    /// does when it (re)generates a title. Last one wins, and the message DAG is
    /// untouched, so resuming the session is unaffected. For a remote session,
    /// the event is appended on the host itself over SSH, then the mirror is
    /// resynced so the change shows up locally.
    static func rename(_ session: SessionSummary, to newTitle: String, remoteHostStore: RemoteHostStore? = nil) async throws {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ActionError.renameFailed("Title is empty.") }

        let line: [String: Any] = [
            "type": "ai-title",
            "aiTitle": title,
            "sessionId": session.id
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            throw ActionError.renameFailed("Could not encode title.")
        }

        if let hostID = session.remoteHostID {
            guard let hostStore = remoteHostStore,
                  let host = await hostStore.host(withID: hostID) else {
                throw ActionError.renameFailed("This session's remote host is no longer configured.")
            }
            let remotePath = "\(host.remoteRoot)/\(session.projectFolder)/\(session.id).jsonl"
            let cmd = "printf '%s\\n' \(RemoteShell.shellQuote(jsonString)) >> \(RemoteShell.quoteRemotePath(remotePath))"
            let out: RemoteShell.Output
            do {
                out = try await RemoteShell.sshRun(host: host, remoteCommand: cmd)
            } catch {
                throw ActionError.renameFailed(error.localizedDescription)
            }
            guard out.succeeded else {
                throw ActionError.renameFailed(out.stderr.isEmpty ? "ssh command failed" : out.stderr)
            }
            await hostStore.syncProjectFolder(host, session.projectFolder)
            return
        }

        var payload = data
        payload.append(0x0A) // newline

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: session.fileURL)
        } catch {
            throw ActionError.renameFailed(error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            throw ActionError.renameFailed(error.localizedDescription)
        }
    }

    /// Resume the session in Claude Code, in a new Terminal window at its cwd.
    ///
    /// Writes a temporary `.command` script and opens it with Terminal via
    /// `/usr/bin/open`. This avoids sending Apple events (which need Automation
    /// permission that an ad-hoc-signed app can't reliably obtain), and the
    /// script inherits PATH from the login shell so `claude` resolves.
    static func continueInClaude(_ session: SessionSummary, remoteHost: RemoteHost? = nil) throws {
        let script: String
        if session.isRemote {
            guard let host = remoteHost else {
                throw ActionError.launchFailed("This session's remote host is no longer configured.")
            }
            let remoteCmd = "cd \(RemoteShell.quoteRemotePath(session.workingDirectory)) 2>/dev/null; " +
                            "claude --resume \(RemoteShell.shellQuote(session.id))"
            // Terminal.app gives ssh a real TTY, so password/passphrase auth
            // just prompts there — no askpass plumbing needed for this path.
            let sshArgs = RemoteShell.sshArgs(for: host, context: .interactive)
                .map(shellQuote).joined(separator: " ")
            script = """
            #!/bin/bash
            clear
            echo "▶ Resuming Claude session \(session.id) on \(host.endpoint)"
            exec ssh -t \(sshArgs) \(shellQuote(remoteCmd))
            """
        } else {
            let dir = session.workingDirectory
            let cdTarget = FileManager.default.fileExists(atPath: dir) ? dir : NSHomeDirectory()
            script = """
            #!/bin/bash
            cd \(shellQuote(cdTarget)) || exit 1
            clear
            echo "▶ Resuming Claude session \(session.id)"
            exec claude --resume \(shellQuote(session.id))
            """
        }

        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory
            .appendingPathComponent("resume-\(session.id)")
            .appendingPathExtension("command")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw ActionError.launchFailed(error.localizedDescription)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", scriptURL.path]
        do {
            try proc.run()
        } catch {
            throw ActionError.launchFailed(error.localizedDescription)
        }
    }

    static func revealInFinder(_ session: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    static func copySessionID(_ session: SessionSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
    }

    // MARK: - Quoting helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
