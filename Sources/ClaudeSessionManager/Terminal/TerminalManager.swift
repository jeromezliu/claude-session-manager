import AppKit

/// Tracks open in-app terminal windows, one per session. Re-opening a session
/// that already has a window just focuses it instead of spawning a duplicate.
@MainActor
final class TerminalManager {
    static let shared = TerminalManager()
    private init() {}

    private var controllers: [String: SessionTerminalController] = [:]

    func open(_ session: SessionSummary) {
        if let existing = controllers[session.id] {
            existing.focus()
            return
        }
        let controller = SessionTerminalController(session: session) { [weak self] in
            self?.controllers[session.id] = nil
        }
        controllers[session.id] = controller
        controller.focus()
    }
}
