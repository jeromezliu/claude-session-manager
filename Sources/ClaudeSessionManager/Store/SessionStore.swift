import Foundation
import SwiftUI

/// A project = a folder of sessions, grouped for the sidebar.
struct ProjectGroup: Identifiable, Hashable {
    let id: String          // projectFolder
    let name: String        // friendly name
    let path: String        // working directory
    var sessions: [SessionSummary]
}

enum ViewMode: String, Hashable {
    case sessions
    case trash
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var groups: [ProjectGroup] = []
    @Published var trashEntries: [TrashEntry] = []
    @Published var viewMode: ViewMode = .sessions
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    /// Count of temp/ephemeral sessions excluded from the current scan.
    @Published var hiddenCount = 0

    private var watcher: DirectoryWatcher?
    private var watchedPath: String?

    /// Whether to include throwaway temp-dir sessions (analysis logs, etc.).
    @AppStorage("showTemporarySessions") var showTemporarySessions = false {
        didSet { Task { await reload() } }
    }

    /// Context-window limit used for token-usage display: "auto", "200k", "1m".
    @AppStorage("contextWindowMode") var contextWindowMode = "auto"

    /// Root directory to scan. Persisted across launches.
    @AppStorage("rootPath") var rootPath: String = SessionStore.defaultRoot {
        didSet { Task { await reload() } }
    }

    static var defaultRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

    var totalSessions: Int { groups.reduce(0) { $0 + $1.sessions.count } }

    /// Groups after applying the search filter.
    var filteredGroups: [ProjectGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.sessions.filter { $0.matches(q) }
            let groupMatch = group.name.lowercased().contains(q) || group.path.lowercased().contains(q)
            if groupMatch { return group }
            guard !matches.isEmpty else { return nil }
            return ProjectGroup(id: group.id, name: group.name, path: group.path, sessions: matches)
        }
    }

    /// Trashed entries after applying the search filter.
    var filteredTrash: [TrashEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return trashEntries }
        return trashEntries.filter { $0.summary.matches(q) || $0.originalPath.lowercased().contains(q) }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        let root = rootURL
        let includeTemp = showTemporarySessions

        let result: Result<ScanResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try Self.scan(root: root, includeTemp: includeTemp))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let r): groups = r.groups; hiddenCount = r.hidden
        case .failure(let e): errorMessage = e.localizedDescription; groups = []; hiddenCount = 0
        }
        await loadTrash()
        ensureWatcher()
        isLoading = false
    }

    /// Watch the projects root so the list auto-refreshes when files change.
    private func ensureWatcher() {
        guard watchedPath != rootPath else { return }
        watchedPath = rootPath
        watcher = DirectoryWatcher(path: rootPath) { [weak self] in
            Task { await self?.refreshQuietly() }
        }
    }

    /// A rescan that doesn't toggle the loading spinner (for background refresh).
    func refreshQuietly() async {
        let root = rootURL
        let includeTemp = showTemporarySessions
        let result = await Task.detached(priority: .utility) {
            try? Self.scan(root: root, includeTemp: includeTemp)
        }.value
        if let r = result {
            groups = r.groups
            hiddenCount = r.hidden
        }
        await loadTrash()
    }

    func loadTrash() async {
        trashEntries = await Task.detached(priority: .userInitiated) { TrashManager.list() }.value
    }

    // MARK: - Scanning (runs off the main actor)

    struct ScanResult: Sendable {
        let groups: [ProjectGroup]
        let hidden: Int
    }

    nonisolated static func scan(root: URL, includeTemp: Bool) throws -> ScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "ClaudeSessionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Folder not found: \(root.path)"])
        }

        // Find every *.jsonl under the root (any nesting), with attributes.
        var files: [(url: URL, mtime: Date, size: Int)] = []
        if let en = fm.enumerator(at: root,
                                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((url,
                              vals?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                              vals?.fileSize ?? 0))
            }
        }

        // Parse (cached by mtime+size), then drop throwaway temp-dir sessions.
        let parsed: [SessionSummary] = files.compactMap {
            SummaryCache.shared.summary(for: $0.url, mtime: $0.mtime, size: $0.size)
        }
        let summaries = includeTemp ? parsed : parsed.filter { !$0.isEphemeral }
        let hidden = parsed.count - summaries.count

        var byFolder: [String: [SessionSummary]] = [:]
        for s in summaries { byFolder[s.projectFolder, default: []].append(s) }

        var groups: [ProjectGroup] = byFolder.map { folder, sessions in
            // Latest conversation first within each project.
            let sorted = sessions.sorted { $0.sortDate > $1.sortDate }
            let sample = sorted.first
            return ProjectGroup(
                id: folder,
                name: sample?.projectName ?? SessionSummary.decodeFolder(folder),
                path: sample?.workingDirectory ?? SessionSummary.decodeFolder(folder),
                sessions: sorted
            )
        }
        // Most-recently-active projects first.
        groups.sort { ($0.sessions.first?.sortDate ?? .distantPast) > ($1.sessions.first?.sortDate ?? .distantPast) }
        return ScanResult(groups: groups, hidden: hidden)
    }

    // MARK: - Mutations

    func rename(_ session: SessionSummary, to title: String) {
        do {
            try SessionActions.rename(session, to: title)
            updateSession(session.id) { $0 = $0.withTitle(title) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move a session to the app-managed trash.
    func delete(_ session: SessionSummary) {
        do {
            try TrashManager.trash(session)
            for i in groups.indices {
                groups[i].sessions.removeAll { $0.id == session.id }
            }
            groups.removeAll { $0.sessions.isEmpty }
            Task { await loadTrash() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move several sessions to the trash at once.
    func deleteMany(_ ids: Set<String>) {
        let targets = groups.flatMap { $0.sessions }.filter { ids.contains($0.id) }
        var failed = false
        for session in targets {
            do { try TrashManager.trash(session) }
            catch { errorMessage = error.localizedDescription; failed = true }
        }
        for i in groups.indices {
            groups[i].sessions.removeAll { ids.contains($0.id) }
        }
        groups.removeAll { $0.sessions.isEmpty }
        Task { await loadTrash() }
        if !failed { errorMessage = nil }
    }

    /// Start a brand-new Claude session in an internal terminal window.
    func newSession(inDirectory dir: URL) {
        TerminalManager.shared.newSession(inDirectory: dir)
    }

    /// Restore a trashed session, then refresh both lists.
    func recover(_ entry: TrashEntry) {
        do {
            try TrashManager.recover(entry)
            trashEntries.removeAll { $0.id == entry.id }
            Task { await reload() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Permanently delete one trashed session.
    func purge(_ entry: TrashEntry) {
        do {
            try TrashManager.purge(entry)
            trashEntries.removeAll { $0.id == entry.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Permanently delete everything in the trash.
    func emptyTrash() {
        do {
            try TrashManager.empty()
            trashEntries.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resume the session in the internal terminal (SwiftTerm-backed), embedded
    /// in the detail split by default.
    func continueSession(_ session: SessionSummary) {
        TerminalManager.shared.continueSession(session)
    }

    /// Resume the session in the external Terminal.app instead.
    func openInExternalTerminal(_ session: SessionSummary) {
        do { try SessionActions.continueInClaude(session) }
        catch { errorMessage = error.localizedDescription }
    }

    private func updateSession(_ id: String, _ mutate: (inout SessionSummary) -> Void) {
        for gi in groups.indices {
            if let si = groups[gi].sessions.firstIndex(where: { $0.id == id }) {
                var s = groups[gi].sessions[si]
                mutate(&s)
                groups[gi].sessions[si] = s
                return
            }
        }
    }
}

extension SessionSummary {
    func matches(_ q: String) -> Bool {
        title.lowercased().contains(q)
        || id.lowercased().contains(q)
        || (firstPrompt?.lowercased().contains(q) ?? false)
        || (lastPrompt?.lowercased().contains(q) ?? false)
        || workingDirectory.lowercased().contains(q)
        || (gitBranch?.lowercased().contains(q) ?? false)
    }
}
