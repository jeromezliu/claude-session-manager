import Foundation
import Combine

/// Keeps one `ConversationEngine` per session id, so switching away and back in
/// the sidebar preserves a running conversation (mirrors `TerminalManager`).
@MainActor
final class ConversationManager: ObservableObject {
    static let shared = ConversationManager()

    @Published private(set) var engines: [String: ConversationEngine] = [:]

    func engine(for session: SessionSummary) -> ConversationEngine {
        if let existing = engines[session.id] { return existing }
        let engine = ConversationEngine(session: session)
        engines[session.id] = engine
        return engine
    }

    /// A fresh conversation for a brand-new session in `dir`. Once its real
    /// session id appears, the engine re-registers under that id so selecting
    /// the (now-listed) session reuses the same live conversation.
    func newConversation(inDirectory dir: URL) -> ConversationEngine {
        let engine = ConversationEngine(session: .newDraft(cwd: dir.path), isDraft: true)
        engine.onAdoptSessionID = { [weak self, weak engine] realID in
            guard let self, let engine else { return }
            self.engines[realID] = engine
        }
        return engine
    }

    func existing(_ id: String) -> ConversationEngine? { engines[id] }
}
