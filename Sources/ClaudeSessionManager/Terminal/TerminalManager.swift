import AppKit
import Combine

/// Tracks running session terminals (one per session). Observable so the detail
/// pane can show/hide the embedded terminal split as sessions start and end.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private init() {}

    @Published private(set) var sessions: [String: TerminalSession] = [:]
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

    func session(for id: String) -> TerminalSession? { sessions[id] }

    func end(_ id: String) { sessions[id]?.terminate() }
}
