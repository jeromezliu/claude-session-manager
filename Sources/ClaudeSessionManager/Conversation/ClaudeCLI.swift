import Foundation

/// Locates the `claude` binary and builds the environment for spawning it from
/// a GUI app (which, unlike a terminal, has no login-shell PATH).
enum ClaudeCLI {
    /// Absolute path to the `claude` executable, resolved once.
    static let binaryPath: String = resolveBinary()

    /// The user's login-shell PATH, so spawned tools (git, node, …) resolve.
    static let loginPATH: String = loginShellOutput("printf %s \"$PATH\"")
        ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private static func resolveBinary() -> String {
        if let p = loginShellOutput("command -v claude"), !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    private static func loginShellOutput(_ cmd: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Environment for a turn: inherit the app's, strip Claude Code / Anthropic
    /// session markers (else a nested `claude` won't persist its transcript —
    /// same gotcha the embedded terminal handles), and inject the login PATH.
    static func turnEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where
            key == "CLAUDECODE" || key == "AI_AGENT" || key == "BAGGAGE" ||
            key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") {
            env.removeValue(forKey: key)
        }
        env["PATH"] = loginPATH
        return env
    }

    /// Path to *this* app's own executable — launched as the permission MCP
    /// server via `--permission-bridge`.
    static var selfExecutablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "claude-session-manager"
    }
}
