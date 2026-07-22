import Foundation

/// Shells out to the system `ssh`/`rsync`/`scp` binaries. Kept as one small
/// helper so every remote-aware call site (host store, rename, trash,
/// recover, terminal adoption) runs processes the same safe way: arguments
/// are passed as an array (never interpolated into a shell string) for the
/// *local* invocation, so a user-typed alias or path can't break out via
/// shell metacharacters at that layer. Only the remote command string that
/// `ssh` hands to the *remote* shell needs manual quoting — see `shellQuote`.
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

    /// Run a local binary (ssh/rsync/scp) with the given arguments and capture output.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments

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

    /// Run a command string on a remote host over `ssh -o BatchMode=yes <alias> "<cmd>"`.
    /// `remoteCommand` is interpreted by the *remote* shell, so callers must
    /// `shellQuote` any interpolated paths/ids themselves before composing it.
    @discardableResult
    static func sshRun(alias: String, remoteCommand: String, timeout: TimeInterval = 20) async throws -> Output {
        try await run("/usr/bin/ssh",
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, remoteCommand],
                       timeout: timeout)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
