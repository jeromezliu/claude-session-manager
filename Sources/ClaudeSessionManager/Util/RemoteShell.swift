import Foundation

/// Shells out to the system `ssh`/`rsync`/`scp` binaries, building every
/// invocation from a `RemoteHost`'s in-app config (hostname, port, username,
/// key file or Keychain password). Kept as one small helper so every
/// remote-aware call site (host store, rename, trash, recover, terminal
/// adoption) runs processes the same safe way: arguments are passed as an
/// array (never interpolated into a shell string) for the *local* invocation,
/// so a user-typed hostname or path can't break out via shell metacharacters
/// at that layer. Only the remote command string that `ssh` hands to the
/// *remote* shell needs manual quoting — see `shellQuote`.
///
/// Password auth: OpenSSH refuses to take a password from arguments or stdin,
/// so a tiny `ssh-askpass` helper script is used (`SSH_ASKPASS_REQUIRE=force`)
/// that echoes `$CSM_SSH_PASSWORD` — the password is fetched from the Keychain
/// and handed to the child process through its environment only.
enum RemoteShell {

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    enum RemoteShellError: LocalizedError {
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .launchFailed(let m): return m
            }
        }
    }

    /// How the ssh process will run, which decides how auth prompts are handled.
    enum Context {
        /// No TTY (Process pipes): key auth runs BatchMode, password auth goes
        /// through the askpass helper. Anything interactive would just hang.
        case batch
        /// A real PTY (embedded terminal): no BatchMode, so a key passphrase
        /// or host-key confirmation can still be answered in the terminal.
        case interactive
    }

    // MARK: - Argument building

    /// Common `-o`/`-i` options for a host (everything except the port, which
    /// is spelled `-p` for ssh but `-P` for scp — callers add it themselves).
    static func options(for host: RemoteHost, context: Context) -> [String] {
        var opts = ["-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"]
        switch host.authMethod {
        case .privateKey:
            if !host.identityFile.isEmpty {
                opts += ["-i", (host.identityFile as NSString).expandingTildeInPath,
                         "-o", "IdentitiesOnly=yes"]
            }
            if context == .batch { opts += ["-o", "BatchMode=yes"] }
        case .password:
            opts += ["-o", "NumberOfPasswordPrompts=1",
                     "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        return opts
    }

    /// Full argument list for `ssh` up to (and including) the destination.
    static func sshArgs(for host: RemoteHost, context: Context) -> [String] {
        options(for: host, context: context) + ["-p", String(host.port), host.destination]
    }

    /// The `-e` remote-shell string for `rsync`. rsync splits this on spaces
    /// but honors quotes, so the identity path is shell-quoted.
    static func rsyncRemoteShell(for host: RemoteHost) -> String {
        (["ssh"] + options(for: host, context: .batch) + ["-p", String(host.port)])
            .map { $0.contains(where: { " '\"\\".contains($0) }) ? shellQuote($0) : $0 }
            .joined(separator: " ")
    }

    /// Environment for a child ssh/rsync/scp process. For password auth this
    /// injects the askpass helper plus the Keychain password; for key auth the
    /// inherited environment is returned unchanged.
    static func environment(for host: RemoteHost,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard host.authMethod == .password,
              let password = SSHKeychain.password(for: host.id),
              let askpass = try? askpassScriptURL() else { return base }
        var env = base
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["CSM_SSH_PASSWORD"] = password
        // Older OpenSSH only consults SSH_ASKPASS when DISPLAY is set.
        if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        return env
    }

    /// Lazily writes the askpass helper (0700) into Application Support.
    static func askpassScriptURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("ClaudeSessionManager/csm-askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$CSM_SSH_PASSWORD\"\n"
        let fm = FileManager.default
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Process execution

    /// Run a local binary (ssh/rsync/scp) with the given arguments and capture output.
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 30) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            if let environment { proc.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            // Never let ssh/rsync fall back to an interactive password prompt —
            // there is no PTY here to answer one, and it would just hang.
            proc.standardInput = FileHandle.nullDevice

            proc.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: Output(status: p.terminationStatus, stdout: out, stderr: err))
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: RemoteShellError.launchFailed(error.localizedDescription))
                return
            }

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if proc.isRunning { proc.terminate() }
            }
        }
    }

    /// Run a command string on a remote host over ssh (batch context).
    /// `remoteCommand` is interpreted by the *remote* shell, so callers must
    /// `shellQuote` any interpolated paths/ids themselves before composing it.
    @discardableResult
    static func sshRun(host: RemoteHost, remoteCommand: String, timeout: TimeInterval = 20) async throws -> Output {
        try await run("/usr/bin/ssh",
                      sshArgs(for: host, context: .batch) + [remoteCommand],
                      environment: environment(for: host),
                      timeout: timeout)
    }

    /// Copy a local file to `remotePath` on the host over scp.
    @discardableResult
    static func scpUpload(host: RemoteHost, localPath: String, remotePath: String,
                          timeout: TimeInterval = 60) async throws -> Output {
        try await run("/usr/bin/scp",
                      options(for: host, context: .batch)
                          + ["-P", String(host.port), localPath,
                             "\(host.destination):\(homeRelative(remotePath))"],
                      environment: environment(for: host),
                      timeout: timeout)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote a remote path while still letting the remote shell expand a
    /// leading `~/` — quoting the whole path would make `~` a literal
    /// directory name (`rm '~/x'` → "No such file or directory").
    static func quoteRemotePath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + shellQuote(String(path.dropFirst(2))) }
        return shellQuote(path)
    }

    /// scp/rsync resolve relative remote paths against the login home, which
    /// is more portable than hoping the server expands `~` in a file spec.
    static func homeRelative(_ path: String) -> String {
        if path == "~" { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path
    }
}
