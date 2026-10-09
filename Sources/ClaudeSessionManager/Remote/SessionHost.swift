import Foundation
import Combine
import Darwin

/// A Claude Code process the app doesn't own, from `~/.claude/sessions/<pid>.json`.
struct ExternalSession: Equatable {
    let pid: Int32
    let sessionID: String
    /// e.g. "claude-desktop", "cli".
    let entrypoint: String?
    /// "idle" / "busy" as the CLI reports it.
    let status: String?

    var whereLabel: String {
        switch entrypoint {
        case "claude-desktop": return "Claude Desktop"
        case "cli", nil: return "a terminal"
        default: return entrypoint!
        }
    }
}

/// Owns every session the app runs headless. One owner per session: a
/// session already running somewhere else (a terminal, Claude Desktop, the
/// app's embedded terminal) is never driven from here — two writers on one
/// transcript is the bug class that sinks similar tools.
@MainActor
final class SessionHost: ObservableObject {
    /// Keyed by CLI session id once known; new sessions start under their host id.
    @Published private(set) var sessions: [String: HostedSession] = [:]
    /// Session id of a just-started new session, once Claude announced it.
    @Published private(set) var recentlyStarted: String?

    private var transports: [UUID: ClaudeTransport] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    /// Builds the transport; swapped in tests.
    var makeTransport: (ClaudeLaunch) -> ClaudeTransport = { ProcessClaudeTransport(launch: $0) }
    /// Where the CLI's pid files live; swapped in tests.
    var sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")

    func hosted(_ sessionID: String) -> HostedSession? {
        guard let s = sessions[sessionID], s.phase != .exited else { return nil }
        return s
    }

    enum HostError: LocalizedError {
        case busyElsewhere(ExternalSession)
        case inEmbeddedTerminal
        var errorDescription: String? {
            switch self {
            case .busyElsewhere(let e): return "This session is open in \(e.whereLabel) (pid \(e.pid)). Close it there first."
            case .inEmbeddedTerminal: return "This session is running in the app's terminal. Close the terminal first."
            }
        }
    }

    /// Why the app can't drive `sessionID` right now, if it can't.
    func blocker(for sessionID: String) -> HostError? {
        if TerminalManager.shared.session(for: sessionID) != nil { return .inEmbeddedTerminal }
        if let ext = cachedExternalSessions()[sessionID] { return .busyElsewhere(ext) }
        return nil
    }

    // Views ask on every render (including each streamed token); the pid
    // files only change when processes start or stop.
    private var externalCache: (at: Date, value: [String: ExternalSession])?

    private func cachedExternalSessions() -> [String: ExternalSession] {
        if let c = externalCache, Date().timeIntervalSince(c.at) < 2 { return c.value }
        let value = Self.externalSessions(excluding: ownPIDs, dir: sessionsDir)
        externalCache = (Date(), value)
        return value
    }

    /// Start driving an existing session (resumes it in a new headless process).
    @discardableResult
    func resume(_ summary: SessionSummary, permissionMode: String = "default") throws -> HostedSession {
        if let live = hosted(summary.id) { return live }
        if let blocker = blocker(for: summary.id) { throw blocker }
        let cwd = FileManager.default.fileExists(atPath: summary.workingDirectory)
            ? summary.workingDirectory : NSHomeDirectory()
        let session = try launch(ClaudeLaunch(cwd: cwd, resume: summary.id, permissionMode: permissionMode))
        sessions[summary.id] = session
        return session
    }

    /// Start a brand-new session in `cwd` with a first message.
    @discardableResult
    func startNew(in cwd: String, prompt: String, permissionMode: String = "default",
                  model: String? = nil) throws -> HostedSession {
        let session = try launch(ClaudeLaunch(cwd: cwd, resume: nil, permissionMode: permissionMode, model: model))
        let provisional = "host-\(session.id.uuidString)"
        sessions[provisional] = session
        session.send(prompt)
        // Re-key under the CLI's id once it's announced.
        subscriptions[session.id] = session.$sessionID.compactMap { $0 }.first().sink { [weak self, weak session] id in
            guard let self, let session else { return }
            self.sessions.removeValue(forKey: provisional)
            self.sessions[id] = session
            self.recentlyStarted = id
        }
        return session
    }

    func stopAll() { sessions.values.forEach { $0.stop() } }

    // MARK: - Internals

    private var ownPIDs: Set<Int32> { Set(transports.values.compactMap(\.pid)) }

    private func launch(_ launch: ClaudeLaunch) throws -> HostedSession {
        let transport = makeTransport(launch)
        let session = HostedSession(cwd: launch.cwd, resume: launch.resume,
                                    permissionMode: launch.permissionMode, transport: transport)
        try session.start()
        transports[session.id] = transport
        return session
    }

    /// Live Claude Code processes by session id, read from the CLI's own
    /// pid files (stale files of dead processes are ignored).
    static func externalSessions(excluding own: Set<Int32> = [],
                                 dir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions"))
        -> [String: ExternalSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [String: ExternalSession] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sid = obj["sessionId"] as? String,
                  !own.contains(pid), isAlive(pid) else { continue }
            result[sid] = ExternalSession(pid: pid, sessionID: sid,
                                          entrypoint: obj["entrypoint"] as? String, status: obj["status"] as? String)
        }
        return result
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
