import Foundation
import SwiftUI

enum ViewMode: String, Hashable {
    case sessions
    case skills
    case trash
}

@MainActor
final class SessionStore: ObservableObject {
    /// Every scanned session (local + remote mirrors), newest first, already
    /// enriched with desktop metadata and local title overrides.
    @Published private(set) var sessions: [SessionSummary] = []
    /// Desktop app metadata (titles, groups) from the last scan.
    @Published private(set) var desktop = DesktopSnapshot.empty
    /// Groups and titles set in this app (persisted).
    @Published private(set) var localMeta = LocalSessionMeta.load()
    @Published var trashEntries: [TrashEntry] = []
    @Published var viewMode: ViewMode = .sessions
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    /// Count of temp/ephemeral sessions excluded from the current scan.
    @Published var hiddenTemporaryCount = 0

    let remoteHostStore: RemoteHostStore
    /// One watcher per root: "local" for `rootPath`, "desktop" for the desktop
    /// app's session metadata, plus one keyed by host id for each enabled
    /// remote host's mirrored cache dir.
    private var watchers: [String: DirectoryWatcher] = [:]

    init(remoteHosts: RemoteHostStore) {
        self.remoteHostStore = remoteHosts
        TerminalManager.shared.hostStore = remoteHosts
    }

    /// Whether to include throwaway temp-dir sessions (analysis logs, etc.).
    @AppStorage("showTemporarySessions") var showTemporarySessions = false {
        didSet { Task { await reload() } }
    }

    /// Whether to list sessions archived in the Claude desktop app.
    @AppStorage("showArchivedSessions") var showArchivedSessions = false

    /// Sidebar layout: by group (desktop + local) or by project.
    @AppStorage("sessionOrganization") var organization = SessionOrganization.groups

    /// Context-window limit used for token-usage display.
    @AppStorage("contextWindowMode") var contextWindowMode = ContextWindowMode.auto

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

    // MARK: - Derived views

    private var archivedHidden: Bool { !showArchivedSessions }

    /// Sessions currently listed: archived ones dropped unless shown, then
    /// the search filter (which also matches a session's group name).
    var visibleSessions: [SessionSummary] {
        let base = archivedHidden ? sessions.filter { !$0.isArchived } : sessions
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { s in
            s.matches(q) || (group(of: s.id)?.lowercased().contains(q) ?? false)
        }
    }

    /// Sidebar sections for the current organization.
    var sections: [SessionSection] {
        SessionGrouping.sections(for: visibleSessions, organization: organization,
                                 local: localMeta, desktop: desktop)
    }

    /// Top-level sidebar entries: categories (holding groups/projects), then
    /// the uncategorized sections.
    var sidebarItems: [SidebarItem] { SessionGrouping.layout(sections, local: localMeta) }

    /// Sessions not listed: temporary ones (when hidden) + archived ones.
    var hiddenCount: Int {
        hiddenTemporaryCount + (archivedHidden ? sessions.filter(\.isArchived).count : 0)
    }

    func visibleSession(withID id: SessionSummary.ID) -> SessionSummary? {
        visibleSessions.first { $0.id == id }
    }

    /// Trashed entries after applying the search filter.
    var filteredTrash: [TrashEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return trashEntries }
        return trashEntries.filter { $0.summary.matches(q) || $0.originalPath.lowercased().contains(q) }
    }

    // MARK: - Groups

    /// The group a session is filed under (local assignment, else desktop).
    func group(of id: String) -> String? {
        SessionGrouping.group(of: id, local: localMeta, desktop: desktop)
    }

    /// Every known group name, in sidebar order.
    var allGroups: [String] { SessionGrouping.allGroups(local: localMeta, desktop: desktop) }

    /// Groups that come from Claude Desktop (read-only: renamed/deleted there).
    func isDesktopGroup(_ name: String) -> Bool { desktop.groupNames.contains(name) }

    /// File sessions under `name` (nil = ungroup). Matching the desktop's own
    /// assignment just clears the local override, so later desktop changes
    /// show through again.
    func assign(_ ids: Set<String>, toGroup name: String?) {
        var meta = localMeta
        for id in ids {
            if name == desktop.groupOfSession[id] {
                meta.assignments[id] = nil
            } else {
                meta.assignments[id] = name ?? ""
            }
        }
        if let name, !isDesktopGroup(name), !meta.groups.contains(name) { meta.groups.append(name) }
        saveMeta(meta)
    }

    /// Create a group (or return the existing one with that name, ignoring case).
    @discardableResult
    func createGroup(named raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = allGroups.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        var meta = localMeta
        meta.groups.append(name)
        saveMeta(meta)
        return name
    }

    /// Rename a group created in this app.
    func renameGroup(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old, !isDesktopGroup(old) else { return }
        guard !allGroups.contains(where: { $0 != old && $0.caseInsensitiveCompare(new) == .orderedSame }) else {
            errorMessage = "A group named “\(new)” already exists."
            return
        }
        var meta = localMeta
        meta.groups = meta.groups.map { $0 == old ? new : $0 }
        for (id, g) in meta.assignments where g == old { meta.assignments[id] = new }
        // Section ids embed the group name; keep its category.
        if let c = meta.categoryOfSection.removeValue(forKey: "group:\(old)") {
            meta.categoryOfSection["group:\(new)"] = c
        }
        saveMeta(meta)
    }

    /// Delete a group created in this app; its sessions become ungrouped
    /// (or fall back to their desktop group, if any).
    func deleteGroup(_ name: String) {
        guard !isDesktopGroup(name) else { return }
        var meta = localMeta
        meta.groups.removeAll { $0 == name }
        meta.assignments = meta.assignments.filter { $0.value != name }
        meta.categoryOfSection["group:\(name)"] = nil
        saveMeta(meta)
    }

    // MARK: - Categories

    func category(ofSection id: String) -> String? {
        localMeta.categoryOfSection[id].flatMap { localMeta.categories.contains($0) ? $0 : nil }
    }

    /// Create a category (or return the existing one with that name, ignoring case).
    @discardableResult
    func createCategory(named raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = localMeta.categories.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        var meta = localMeta
        meta.categories.append(name)
        saveMeta(meta)
        return name
    }

    /// File a group/project section under `name` (nil = back to top level).
    func moveSection(_ sectionID: String, toCategory name: String?) {
        var meta = localMeta
        meta.categoryOfSection[sectionID] = name
        saveMeta(meta)
    }

    func renameCategory(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        guard !localMeta.categories.contains(where: { $0 != old && $0.caseInsensitiveCompare(new) == .orderedSame }) else {
            errorMessage = "A category named “\(new)” already exists."
            return
        }
        var meta = localMeta
        meta.categories = meta.categories.map { $0 == old ? new : $0 }
        for (id, c) in meta.categoryOfSection where c == old { meta.categoryOfSection[id] = new }
        saveMeta(meta)
    }

    /// Delete a category; its groups and projects return to the top level.
    func deleteCategory(_ name: String) {
        var meta = localMeta
        meta.categories.removeAll { $0 == name }
        meta.categoryOfSection = meta.categoryOfSection.filter { $0.value != name }
        saveMeta(meta)
    }

    private func saveMeta(_ meta: LocalSessionMeta) {
        localMeta = meta
        do { try meta.save() } catch { errorMessage = "Couldn't save groups: \(error.localizedDescription)" }
    }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        errorMessage = nil
        switch await scanAll(priority: .userInitiated) {
        case .success(let r): apply(r)
        case .failure(let e): errorMessage = e.localizedDescription; sessions = []; hiddenTemporaryCount = 0
        }
        await loadTrash()
        ensureWatchers()
        isLoading = false
    }

    /// A rescan that doesn't toggle the loading spinner or surface errors
    /// (for background refresh).
    func refreshQuietly() async {
        if case .success(let r) = await scanAll(priority: .utility) { apply(r) }
        await loadTrash()
    }

    private func apply(_ r: ScanResult) {
        desktop = r.desktop
        sessions = r.sessions.map { s in localMeta.titles[s.id].map { s.withTitle($0) } ?? s }
        hiddenTemporaryCount = r.hidden
    }

    /// Scan the local root plus every enabled remote mirror off the main
    /// actor, then persist whatever the summary cache learned.
    private func scanAll(priority: TaskPriority) async -> Result<ScanResult, Error> {
        let root = rootURL
        let includeTemp = showTemporarySessions
        let remoteRoots = enabledRemoteRoots()
        return await Task.detached(priority: priority) {
            defer { SummaryCache.shared.persistIfNeeded() }
            do {
                let desktop = DesktopMetadata.shared.snapshot()
                let local = try Self.scan(root: root, includeTemp: includeTemp, desktop: desktop)
                return .success(Self.mergingRemotes(local, remoteRoots: remoteRoots, includeTemp: includeTemp))
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// (host id, displayName, local mirror dir) for every enabled remote host.
    private func enabledRemoteRoots() -> [(hostID: String, displayName: String, cacheDir: URL)] {
        remoteHostStore.hosts.filter { $0.enabled }.map {
            (hostID: $0.id, displayName: $0.displayName, cacheDir: remoteHostStore.localCacheDir(for: $0))
        }
    }

    /// Scan every enabled remote host's mirrored cache dir, tag the results
    /// with that host's id, and fold them into the local scan result.
    /// A host that hasn't synced yet (cache dir missing/empty) just contributes nothing.
    nonisolated private static func mergingRemotes(
        _ local: ScanResult,
        remoteRoots: [(hostID: String, displayName: String, cacheDir: URL)],
        includeTemp: Bool
    ) -> ScanResult {
        var sessions = local.sessions
        var hidden = local.hidden
        for r in remoteRoots {
            guard let remote = try? Self.scan(root: r.cacheDir, includeTemp: includeTemp) else { continue }
            sessions += remote.sessions.map { $0.withRemote(hostID: r.hostID, displayName: r.displayName) }
            hidden += remote.hidden
        }
        sessions.sort { $0.sortDate > $1.sortDate }
        return ScanResult(sessions: sessions, hidden: hidden, desktop: local.desktop)
    }

    /// Watch every root (local + each enabled remote host's mirrored cache)
    /// so the list auto-refreshes when files change. Cheap to call repeatedly —
    /// only missing/stale watchers are (re)created.
    private func ensureWatchers() {
        var wanted: [String: String] = ["local": rootPath]
        for r in enabledRemoteRoots() { wanted[r.hostID] = r.cacheDir.path }
        // Desktop titles / archive state change there; only watch if it exists
        // (never create folders inside another app's support directory).
        let desktopDir = DesktopMetadata.shared.sessionsDir.path
        if FileManager.default.fileExists(atPath: desktopDir) { wanted["desktop"] = desktopDir }

        for key in watchers.keys where wanted[key] == nil {
            watchers[key] = nil
        }
        for (key, path) in wanted where watchers[key] == nil {
            // FSEvents needs the directory to exist before it can watch it —
            // a remote host's cache dir may not exist yet on its first launch,
            // ahead of that host's first sync.
            if key != "desktop" {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            watchers[key] = DirectoryWatcher(path: path) { [weak self] in
                Task { await self?.refreshQuietly() }
            }
        }
    }

    func loadTrash() async {
        trashEntries = await Task.detached(priority: .userInitiated) { TrashManager.list() }.value
    }

    // MARK: - Scanning (runs off the main actor)

    struct ScanResult: Sendable {
        /// Newest first.
        let sessions: [SessionSummary]
        let hidden: Int
        var desktop = DesktopSnapshot.empty
    }

    /// Parse every `.jsonl` under `root` (newest first), enriched with
    /// `desktop` metadata. Temporary sessions are dropped unless `includeTemp`.
    nonisolated static func scan(root: URL, includeTemp: Bool, desktop: DesktopSnapshot = .empty,
                                 cache: SummaryCache = .shared) throws -> ScanResult {
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
                // Skip subagent transcripts (<project>/<session-id>/subagents/
                // agent-*.jsonl): they belong to a parent session and would
                // otherwise show up as a duplicate session of their own.
                guard !url.pathComponents.contains("subagents") else { continue }
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((url,
                              vals?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                              vals?.fileSize ?? 0))
            }
        }

        // Parse (cached by mtime+size), then drop throwaway temp-dir sessions.
        let parsed = parseConcurrently(files, cache: cache).map { $0.enriched(with: desktop.sessions[$0.id]) }
        let kept = includeTemp ? parsed : parsed.filter { !$0.isEphemeral }
        return ScanResult(sessions: kept.sorted { $0.sortDate > $1.sortDate },
                          hidden: parsed.count - kept.count, desktop: desktop)
    }

    /// Parse (or fetch from cache) every file, spread across cores — a cold
    /// cache means reading hundreds of MB of JSONL. Keeps `files` order.
    nonisolated private static func parseConcurrently(_ files: [(url: URL, mtime: Date, size: Int)],
                                                      cache: SummaryCache) -> [SessionSummary] {
        var results = [SessionSummary?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let f = files[i]
            let summary = cache.summary(for: f.url, mtime: f.mtime, size: f.size)
            lock.lock(); results[i] = summary; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    // MARK: - Mutations

    func rename(_ session: SessionSummary, to title: String) {
        Task {
            do {
                try await SessionActions.rename(session, to: title, remoteHostStore: remoteHostStore)
                // Also keep it locally: for a desktop session the desktop's
                // title would otherwise win over the appended ai-title.
                var meta = localMeta
                meta.titles[session.id] = title.trimmingCharacters(in: .whitespacesAndNewlines)
                saveMeta(meta)
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
                removeSessions([session.id])
                await loadTrash()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Move several sessions to the trash at once.
    func deleteMany(_ ids: Set<String>) {
        let targets = sessions.filter { ids.contains($0.id) }
        Task {
            var trashed: Set<String> = []
            var failures: [String] = []
            for session in targets {
                do {
                    try await TrashManager.trash(session, remoteHostStore: remoteHostStore)
                    trashed.insert(session.id)
                } catch {
                    failures.append("“\(session.title)”: \(error.localizedDescription)")
                }
            }
            // Only drop the ones that actually moved — a failed one stays listed.
            removeSessions(trashed)
            await loadTrash()
            if !failures.isEmpty {
                errorMessage = "Couldn't move \(failures.count) of \(targets.count) sessions to Trash:\n"
                    + failures.joined(separator: "\n")
            }
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
            Task { await loadTrash() }   // show whatever couldn't be deleted
        }
    }

    /// Resume the session in the internal terminal (SwiftTerm-backed), embedded
    /// in the detail split by default.
    func continueSession(_ session: SessionSummary) {
        TerminalManager.shared.continueSession(session)
    }

    /// Resume the session in the external Terminal.app instead.
    func openInExternalTerminal(_ session: SessionSummary) {
        let host = session.remoteHostID.flatMap { remoteHostStore.host(withID: $0) }
        do { try SessionActions.continueInClaude(session, remoteHost: host) }
        catch { errorMessage = error.localizedDescription }
    }

    private func removeSessions(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
    }

    private func updateSession(_ id: String, _ mutate: (inout SessionSummary) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
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
