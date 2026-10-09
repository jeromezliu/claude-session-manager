import Foundation

/// What the Claude desktop app knows about one of its Code sessions.
struct DesktopSessionInfo: Sendable, Hashable {
    /// Desktop's own id (`local_<uuid>`); the CLI session id is the map key.
    let desktopID: String
    let title: String?
    /// The folder the session was started from. For a worktree session this
    /// is the parent repository, not the worktree.
    let originCwd: String?
    let worktreeName: String?
    let isArchived: Bool
}

/// Read-only snapshot of the desktop app's session metadata and sidebar
/// groups, keyed by CLI session id (the `.jsonl` file name).
struct DesktopSnapshot: Sendable {
    var sessions: [String: DesktopSessionInfo] = [:]
    /// Group names in the desktop sidebar's order.
    var groupNames: [String] = []
    /// CLI session id → desktop group name.
    var groupOfSession: [String: String] = [:]

    static let empty = DesktopSnapshot()
}

/// Loads `DesktopSnapshot` from `~/Library/Application Support/Claude`.
///
/// These are the desktop app's private files, so this never writes them and
/// treats every field as optional: if the format changes, the affected data
/// is simply missing and the app falls back to what the `.jsonl` provides.
/// Files are re-read only when their modification date changes.
final class DesktopMetadata: @unchecked Sendable {
    static let shared = DesktopMetadata(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Claude", isDirectory: true))

    let root: URL
    private let lock = NSLock()
    private var sessionFiles: [String: (mtime: Date, info: DesktopSessionInfo, cliID: String)] = [:]
    private var config: (mtime: Date, groups: [String], assignments: [String: String])?

    init(root: URL) { self.root = root }

    var sessionsDir: URL { root.appendingPathComponent("claude-code-sessions", isDirectory: true) }
    private var configURL: URL { root.appendingPathComponent("claude_desktop_config.json") }

    func snapshot() -> DesktopSnapshot {
        lock.lock(); defer { lock.unlock() }
        refreshSessionFiles()
        refreshConfig()

        var snap = DesktopSnapshot()
        var cliOfDesktopID: [String: String] = [:]
        for entry in sessionFiles.values {
            snap.sessions[entry.cliID] = entry.info
            cliOfDesktopID[entry.info.desktopID] = entry.cliID
        }
        if let config {
            snap.groupNames = config.groups
            for (desktopID, group) in config.assignments {
                if let cli = cliOfDesktopID[desktopID] { snap.groupOfSession[cli] = group }
            }
        }
        return snap
    }

    // MARK: - Session files: claude-code-sessions/<account>/<org>/local_*.json

    private func refreshSessionFiles() {
        let fm = FileManager.default
        var seen = Set<String>()
        let scopes = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for account in scopes {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                    let key = url.path
                    seen.insert(key)
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if let cached = sessionFiles[key], cached.mtime == mtime { continue }
                    if let parsed = Self.parseSessionFile(url) {
                        sessionFiles[key] = (mtime, parsed.info, parsed.cliID)
                    } else {
                        sessionFiles[key] = nil
                    }
                }
            }
        }
        for key in sessionFiles.keys where !seen.contains(key) { sessionFiles[key] = nil }
    }

    static func parseSessionFile(_ url: URL) -> (info: DesktopSessionInfo, cliID: String)? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let desktopID = obj["sessionId"] as? String,
              let cliID = obj["cliSessionId"] as? String, !cliID.isEmpty else { return nil }
        let nonEmpty = { (k: String) in (obj[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return (DesktopSessionInfo(desktopID: desktopID,
                                   title: nonEmpty("title"),
                                   originCwd: nonEmpty("originCwd"),
                                   worktreeName: nonEmpty("worktreeName"),
                                   isArchived: (obj["isArchived"] as? Bool) ?? false),
                cliID)
    }

    // MARK: - Sidebar groups: claude_desktop_config.json

    private func refreshConfig() {
        let mtime = (try? configURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let mtime else { config = nil; return }
        if let config, config.mtime == mtime { return }
        let parsed = (try? Data(contentsOf: configURL)).flatMap(Self.parseGroups)
        config = (mtime, parsed?.groups ?? [], parsed?.assignments ?? [:])
    }

    /// Groups live under `preferences.epitaxyPrefs["dframe-group-scopes"]`,
    /// one scope per account/org: `groups` is `[{id, name}]` in sidebar order,
    /// `assignments` maps `"code:<desktop session id>"` to a group id.
    /// Returns group names and desktop session id → group name.
    static func parseGroups(_ data: Data) -> (groups: [String], assignments: [String: String])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let prefs = (obj["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any],
              let scopes = prefs["dframe-group-scopes"] as? [String: Any] else { return nil }
        var names: [String] = []
        var assignments: [String: String] = [:]
        for case let scope as [String: Any] in scopes.values {
            var nameOfID: [String: String] = [:]
            for case let g as [String: Any] in (scope["groups"] as? [Any]) ?? [] {
                guard let id = g["id"] as? String,
                      let name = (g["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                nameOfID[id] = name
                if !names.contains(name) { names.append(name) }
            }
            for (key, value) in (scope["assignments"] as? [String: Any]) ?? [:] {
                guard key.hasPrefix("code:"), let gid = value as? String, let name = nameOfID[gid] else { continue }
                assignments[String(key.dropFirst("code:".count))] = name
            }
        }
        return (names, assignments)
    }
}
