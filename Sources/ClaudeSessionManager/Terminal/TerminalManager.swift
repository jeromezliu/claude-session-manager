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

    /// Start (or focus) a terminal for a session. New terminals begin embedded.
    func continueSession(_ session: SessionSummary) {
        if let existing = sessions[session.id] {
            existing.focus()
            return
        }
        let terminal = TerminalSession(session: session) { [weak self] id in
            self?.observers[id] = nil
            self?.sessions[id] = nil
        }
        // Re-publish when a session changes (e.g. isPoppedOut) so views observing
        // the manager — like the detail pane — re-evaluate the split visibility.
        observers[session.id] = terminal.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions[session.id] = terminal
    }

    /// Start a brand-new Claude session (no --resume), embedded by default.
    /// Returns the synthetic id so the caller can show it in the detail pane.
    @discardableResult
    func newSession(inDirectory dir: URL) -> String {
        let id = "new-" + UUID().uuidString
        let summary = SessionSummary(
            id: id,
            fileURL: dir.appendingPathComponent("\(id).jsonl"),
            projectFolder: dir.lastPathComponent,
            cwd: dir.path,
            gitBranch: nil, claudeVersion: nil,
            title: "New session · \(dir.lastPathComponent)",
            firstPrompt: nil, lastPrompt: nil,
            messageCount: 0, models: [], totalOutputTokens: 0,
            createdAt: nil, lastActivityAt: nil, modifiedAt: Date(), fileSize: 0,
            latestContextTokens: 0, maxContextTokens: 0)

        let terminal = TerminalSession(
            session: summary, resume: false,
            onAdopt: { [weak self] oldID, real in self?.adopt(oldID: oldID, to: real) },
            onEnd: { [weak self] id in
                self?.observers[id] = nil
                self?.sessions[id] = nil
            })
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
        sessions[real.id] = terminal
        observers[real.id] = terminal.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        recentlyAdopted = real.id
    }

    func session(for id: String) -> TerminalSession? { sessions[id] }

    func end(_ id: String) { sessions[id]?.terminate() }
}
