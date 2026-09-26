import AppKit
import Combine

/// Tracks running session terminals (one per session). Observable so the detail
/// pane can show/hide the embedded terminal split as sessions start and end.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private init() {}

    @Published private(set) var sessions: [String: TerminalSession] = [:]
    /// Set to the real id when a new session's terminal is re-keyed on adoption,
    /// so the UI can move its selection/active-terminal reference over.
    @Published private(set) var recentlyAdopted: String?
    private var observers: [String: AnyCancellable] = [:]
    /// Injected once at startup (SessionStore.init) so remote-tagged sessions
    /// can resolve their host config when a terminal is opened for them.
    weak var hostStore: RemoteHostStore?

    /// Start (or focus) a terminal for a session. New terminals begin embedded.
    func continueSession(_ session: SessionSummary) {
        if let existing = sessions[session.id] {
            existing.focus()
            return
        }
        let host = session.remoteHostID.flatMap { hostStore?.host(withID: $0) }
        register(TerminalSession(session: session, remoteHost: host, onEnd: endHandler))
    }

    /// Start a brand-new Claude session (no --resume), embedded by default.
    /// Returns the synthetic id so the caller can show it in the detail pane.
    @discardableResult
    func newSession(inDirectory dir: URL) -> String {
        let id = Self.newSessionID()
        let summary = SessionSummary.placeholder(
            id: id, fileURL: dir.appendingPathComponent("\(id).jsonl"),
            projectFolder: dir.lastPathComponent, cwd: dir.path,
            title: "New session · \(dir.lastPathComponent)")
        return register(TerminalSession(session: summary, resume: false,
                                        onAdopt: adoptHandler, onEnd: endHandler))
    }

    /// Start a brand-new Claude session on a remote host (no --resume),
    /// embedded by default. `dir` is a path on the remote host.
    @discardableResult
    func newSession(remoteDir dir: String, host: RemoteHost, hostStore: RemoteHostStore) -> String {
        let id = Self.newSessionID()
        let folderName = TerminalSession.encodedFolder(for: dir)
        let summary = SessionSummary.placeholder(
            id: id,
            fileURL: hostStore.localCacheDir(for: host).appendingPathComponent(folderName)
                .appendingPathComponent("\(id).jsonl"),
            projectFolder: folderName, cwd: dir,
            title: "New session · \(host.displayName)")
            .withRemote(hostID: host.id, displayName: host.displayName)
        return register(TerminalSession(session: summary, resume: false, newSessionHost: host, hostStore: hostStore,
                                        onAdopt: adoptHandler, onEnd: endHandler))
    }

    private static func newSessionID() -> String { "new-" + UUID().uuidString }

    private var endHandler: (String) -> Void {
        { [weak self] id in
            self?.observers[id] = nil
            self?.sessions[id] = nil
        }
    }

    private var adoptHandler: (String, SessionSummary) -> Void {
        { [weak self] oldID, real in self?.adopt(oldID: oldID, to: real) }
    }

    /// Track a terminal under its current id. Re-publishes its changes (e.g.
    /// isPoppedOut) so views observing the manager — like the detail pane —
    /// re-evaluate the split visibility.
    @discardableResult
    private func register(_ terminal: TerminalSession) -> String {
        let id = terminal.id
        observers[id] = terminal.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions[id] = terminal
        return id
    }

    /// Re-key a new session's terminal from its synthetic id to the real session
    /// id Claude created, so the list row + activity indicator + selection all
    /// resolve to the same running terminal.
    private func adopt(oldID: String, to real: SessionSummary) {
        guard let terminal = sessions[oldID], oldID != real.id else { return }
        sessions.removeValue(forKey: oldID)
        observers[oldID] = nil
        terminal.id = real.id
        register(terminal)
        recentlyAdopted = real.id
    }

    func session(for id: String) -> TerminalSession? { sessions[id] }

    func end(_ id: String) { sessions[id]?.terminate() }
}
