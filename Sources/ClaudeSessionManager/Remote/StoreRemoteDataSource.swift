import Foundation
import Combine

/// Serves the app's session list (with groups, categories and live state)
/// to remote clients.
@MainActor
final class StoreRemoteDataSource: RemoteDataSource {
    private let store: SessionStore
    private let host: SessionHost

    init(store: SessionStore, host: SessionHost) {
        self.store = store
        self.host = host
    }

    func remoteSessions() -> [RemoteSessionInfo] {
        // Map each session to the category of the group/project section it sits in.
        var categoryOfSession: [String: String] = [:]
        for item in store.sidebarItems {
            if case .category(let c) = item {
                for section in c.sections { for s in section.sessions { categoryOfSession[s.id] = c.name } }
            }
        }
        return store.visibleSessions.map { s in
            let blocker: String?
            switch host.blocker(for: s.id) {
            case .busyElsewhere(let e)?: blocker = e.whereLabel
            case .inEmbeddedTerminal?: blocker = "the Mac's terminal"
            case nil: blocker = nil
            }
            return RemoteSessionInfo(
                id: s.id, title: s.title, project: s.projectName, group: store.group(of: s.id),
                category: categoryOfSession[s.id], updatedAt: s.sortDate, messageCount: s.messageCount,
                lastPrompt: s.lastPrompt, isRemoteHost: s.isRemote,
                hostedPhase: host.hosted(s.id)?.phase, busyElsewhere: blocker)
        }
    }

    func summary(for sessionID: String) -> SessionSummary? {
        store.sessions.first { $0.id == sessionID }
    }

    var sessionsChanged: AnyPublisher<Void, Never> {
        store.objectWillChange.merge(with: host.objectWillChange).map { _ in () }.eraseToAnyPublisher()
    }
}
