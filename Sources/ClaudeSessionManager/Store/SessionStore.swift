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
    case skills
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

    let remoteHostStore: RemoteHostStore
    /// One watcher per root: "local" for `rootPath`, plus one keyed by alias
    /// for each enabled remote host's mirrored cache dir.
    private var watchers: [String: DirectoryWatcher] = [:]

    init(remoteHosts: RemoteHostStore) {
        self.remoteHostStore = remoteHosts
    }

    /// Whether to include throwaway temp-dir sessions (analysis logs, etc.).
    @AppStorage("showTemporarySessions") var showTemporarySessions = false {
        didSet { Task { await reload() } }
    }

    /// Context-window limit used for token-usage display: "auto", "200k", "1m".
    @AppStorage("contextWindowMode") var contextWindowMode = "auto"

    /// Default working directory for new sessions (remembered across launches).
    @AppStorage("newSessionDir") var newSessionDir: String = SessionStore.defaultNewSessionDir

    static var defaultNewSessionDir: String {
        let ws = (NSHomeDirectory() as NSString).appendingPathComponent("Workspace")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: ws, isDirectory: &isDir), isDir.boolValue { return ws }
        return NSHomeDirectory()
    }

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
        let remoteRoots = enabledRemoteRoots()

        let result: Result<ScanResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let local = try Self.scan(root: root, includeTemp: includeTemp)
                return .success(Self.mergingRemotes(local, remoteRoots: remoteRoots, includeTemp: includeTemp))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let r): groups = r.groups; hiddenCount = r.hidden
        case .failure(let e): errorMessage = e.localizedDescription; groups = []; hiddenCount = 0
        }
        await loadTrash()
        ensureWatchers()
        isLoading = false
    }

    /// (alias, displayName, local mirror dir) for every enabled remote host.
    private func enabledRemoteRoots() -> [(alias: String, displayName: String, cacheDir: URL)] {
        remoteHostStore.hosts.filter { $0.enabled }.map {
            (alias: $0.alias, displayName: $0.displayName, cacheDir: remoteHostStore.localCacheDir(for: $0))
        }
    }

    /// Scan every enabled remote host's mirrored cache dir, tag the results
    /// with that host's alias, and fold them into the local scan result.
    /// A host that hasn't synced yet (cache dir missing/empty) just contributes nothing.
    nonisolated private static func mergingRemotes(
        _ local: ScanResult,
        remoteRoots: [(alias: String, displayName: String, cacheDir: URL)],
        includeTemp: Bool
    ) -> ScanResult {
        var groups = local.groups
        var hidden = local.hidden
        for r in remoteRoots {
            guard let remote = try? Self.scan(root: r.cacheDir, includeTemp: includeTemp) else { continue }
            let tagged = remote.groups.map { group -> ProjectGroup in
                ProjectGroup(id: "\(r.alias):\(group.id)", name: group.name, path: group.path,
                             sessions: group.sessions.map { $0.withRemote(alias: r.alias, displayName: r.displayName) })
            }
            groups += tagged
            hidden += remote.hidden
        }
        groups.sort { ($0.sessions.first?.sortDate ?? .distantPast) > ($1.sessions.first?.sortDate ?? .distantPast) }
        return ScanResult(groups: groups, hidden: hidden)
    }

    /// Watch every root (local + each enabled remote host's mirrored cache)
    /// so the list auto-refreshes when files change. Cheap to call repeatedly —
    /// only missing/stale watchers are (re)created.
    private func ensureWatchers() {
        var wanted: [String: String] = ["local": rootPath]
        for r in enabledRemoteRoots() { wanted[r.alias] = r.cacheDir.path }

        for key in watchers.keys where wanted[key] == nil {
            watchers[key] = nil
        }
        for (key, path) in wanted where watchers[key] == nil {
            // FSEvents needs the directory to exist before it can watch it —
            // a remote host's cache dir may not exist yet on its first launch,
            // ahead of that host's first sync.
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            watchers[key] = DirectoryWatcher(path: path) { [weak self] in
                Task { await self?.refreshQuietly() }
            }
        }
    }

    /// A rescan that doesn't toggle the loading spinner (for background refresh).
    func refreshQuietly() async {
        let root = rootURL
        let includeTemp = showTemporarySessions
        let remoteRoots = enabledRemoteRoots()
        let result = await Task.detached(priority: .utility) {
            guard let local = try? Self.scan(root: root, includeTemp: includeTemp) else { return nil as ScanResult? }
            return Self.mergingRemotes(local, remoteRoots: remoteRoots, includeTemp: includeTemp)
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
        Task {
            do {
                try await SessionActions.rename(session, to: title, remoteHostStore: remoteHostStore)
                updateSession(session.id) { $0 = $0.withTitle(title) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Move a session to the app-managed trash.
    func delete(_ session: SessionSummary) {
        Task {
            do {
                try await TrashManager.trash(session, remoteHostStore: remoteHostStore)
                for i in groups.indices {
                    groups[i].sessions.removeAll { $0.id == session.id }
                }
                groups.removeAll { $0.sessions.isEmpty }
                await loadTrash()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Move several sessions to the trash at once.
    func deleteMany(_ ids: Set<String>) {
        let targets = groups.flatMap { $0.sessions }.filter { ids.contains($0.id) }
        Task {
            var failed = false
            for session in targets {
                do { try await TrashManager.trash(session, remoteHostStore: remoteHostStore) }
                catch { errorMessage = error.localizedDescription; failed = true }
            }
            for i in groups.indices {
                groups[i].sessions.removeAll { ids.contains($0.id) }
            }
            groups.removeAll { $0.sessions.isEmpty }
            await loadTrash()
            if !failed { errorMessage = nil }
        }
    }

    /// Start a brand-new Claude session in an internal terminal. Returns its id.
    @discardableResult
    func newSession(inDirectory dir: URL) -> String {
        TerminalManager.shared.newSession(inDirectory: dir)
    }

    /// Start a brand-new Claude session on a remote host, in an SSH-backed
    /// internal terminal. `dir` is a path on the remote host (no local FS
    /// browsing is possible there, so it's typed in by the user).
    @discardableResult
    func newSession(remoteDir dir: String, host: RemoteHost) -> String {
        TerminalManager.shared.newSession(remoteDir: dir, host: host, hostStore: remoteHostStore)
    }

    /// Restore a trashed session, then refresh both lists.
    func recover(_ entry: TrashEntry) {
        Task {
            do {
                try await TrashManager.recover(entry, remoteHostStore: remoteHostStore)
                trashEntries.removeAll { $0.id == entry.id }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
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
