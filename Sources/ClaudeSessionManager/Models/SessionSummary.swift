import Foundation

/// Lightweight metadata about a single Claude Code session (.jsonl file).
/// Everything here is cheap enough to compute for hundreds of sessions and is
/// safe to pass across actor boundaries.
struct SessionSummary: Identifiable, Hashable, Sendable {
    /// Session UUID — matches the file name stem and the `sessionId` field.
    let id: String
    let fileURL: URL

    /// Name of the parent folder (Claude's encoded cwd), used to group sessions.
    let projectFolder: String
    /// Real working directory, read from a message line when available.
    let cwd: String
    let gitBranch: String?
    let claudeVersion: String?

    /// Best available human title: last `ai-title`, else first user prompt.
    var title: String
    let firstPrompt: String?
    let lastPrompt: String?

    let messageCount: Int
    let models: [String]
    let totalOutputTokens: Int

    let createdAt: Date?
    /// Timestamp of the last actual user/assistant message (not metadata) — used
    /// to order the list by most-recent conversation, ignoring metadata touches.
    let lastActivityAt: Date?
    let modifiedAt: Date
    let fileSize: Int

    /// Approx context tokens used at the last turn (input + cache read/creation).
    let latestContextTokens: Int
    /// Peak context tokens observed across the session (used to auto-detect a
    /// 1M-context session when it exceeds the 200k default).
    let maxContextTokens: Int

    /// Set once, when a scan tags a session as belonging to a remote host's
    /// mirrored cache (nil for local sessions). `remoteHostID` matches
    /// `RemoteHost.id`, so a remote path can always be reconstructed as
    /// `<host.remoteRoot>/<projectFolder>/<id>.jsonl`.
    var remoteHostID: String? = nil
    var remoteDisplayName: String? = nil

    /// Folder the session is grouped under: for a worktree session the parent
    /// repository (so all of a repo's worktrees share one project), else nil
    /// (meaning `workingDirectory`). Set by `enriched(with:)`.
    var projectRoot: String? = nil
    /// Worktree name when the session ran in a git worktree.
    var worktreeName: String? = nil
    /// Archived in the Claude desktop app.
    var isArchived = false

    /// True when the session contains at least one real conversation turn.
    var hasConversation: Bool { messageCount > 0 }

    /// True for a session mirrored from a remote (SSH) host.
    var isRemote: Bool { remoteHostID != nil }

    /// Best timestamp for sorting: last conversation, else file mtime.
    var sortDate: Date { lastActivityAt ?? modifiedAt }

    /// Resolve the context-window limit for display given the user's setting.
    /// `.auto` bumps to 1M once a session's observed usage exceeds 200k.
    func contextWindow(mode: ContextWindowMode) -> Int {
        switch mode {
        case .k200: return 200_000
        case .m1: return 1_000_000
        case .auto: return maxContextTokens > 200_000 ? 1_000_000 : 200_000
        }
    }

    /// A readable project name: last path component of the grouping folder.
    var projectName: String {
        isScratch ? "Scratch" : (groupingRoot as NSString).lastPathComponent
    }

    /// The folder this session is grouped under (see `projectRoot`).
    var groupingRoot: String { projectRoot ?? workingDirectory }

    /// A desktop-app session started without a project folder: it runs in a
    /// throwaway `…/Claude/scratch-workspaces/…/scratch-<date>-<id>` folder.
    var isScratch: Bool { workingDirectory.contains("/Claude/scratch-workspaces/") }

    /// Full working directory for display / launching.
    var workingDirectory: String {
        cwd.isEmpty ? Self.decodeFolder(projectFolder) : cwd
    }

    /// Best-effort decode of Claude's encoded folder name back into a path.
    /// Lossy (real segments may contain "-"), so only a fallback for display.
    static func decodeFolder(_ folder: String) -> String {
        guard folder.hasPrefix("-") else { return folder }
        return "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// True for throwaway sessions that tools spawn in the system temp dir —
    /// e.g. Claude's "session analyst" summarizer at `$TMPDIR/claude-analysis-<uuid>`.
    /// Hidden by default so the list only shows real work.
    var isEphemeral: Bool {
        let path = workingDirectory
        if path.contains("/claude-analysis-") { return true }
        let tempRoots = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        return tempRoots.contains { path.hasPrefix($0) }
    }

    /// Stand-in for a session that doesn't have a file yet (a brand-new
    /// session whose terminal is starting up).
    static func placeholder(id: String, fileURL: URL, projectFolder: String, cwd: String,
                            title: String) -> SessionSummary {
        SessionSummary(
            id: id, fileURL: fileURL, projectFolder: projectFolder, cwd: cwd,
            gitBranch: nil, claudeVersion: nil, title: title,
            firstPrompt: nil, lastPrompt: nil,
            messageCount: 0, models: [], totalOutputTokens: 0,
            createdAt: nil, lastActivityAt: nil, modifiedAt: Date(), fileSize: 0,
            latestContextTokens: 0, maxContextTokens: 0)
    }

    /// A copy completed with what the desktop app knows (its title, the
    /// worktree's parent repo, archived state), and with worktree sessions
    /// grouped under their repository even when the desktop has no record.
    func enriched(with desktop: DesktopSessionInfo?) -> SessionSummary {
        var copy = self
        if let desktop {
            if let t = desktop.title { copy.title = t }
            copy.projectRoot = desktop.originCwd
            copy.worktreeName = desktop.worktreeName
            copy.isArchived = desktop.isArchived
        }
        if copy.projectRoot == nil, let wt = Self.worktreeParent(of: workingDirectory) {
            copy.projectRoot = wt.root
            copy.worktreeName = copy.worktreeName ?? wt.name
        }
        return copy
    }

    /// `/repo/.claude/worktrees/<name>[/…]` → (`/repo`, `<name>`).
    static func worktreeParent(of path: String) -> (root: String, name: String)? {
        guard let r = path.range(of: "/.claude/worktrees/") else { return nil }
        let name = path[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        let root = String(path[..<r.lowerBound])
        return root.isEmpty || name.isEmpty ? nil : (root, name)
    }

    /// A copy with a new title (used after rename / when restoring a stored title).
    func withTitle(_ newTitle: String) -> SessionSummary {
        var copy = self
        copy.title = newTitle
        return copy
    }

    /// A copy tagged as belonging to a remote host (applied once, by the scan
    /// that discovers it in that host's mirrored cache directory).
    func withRemote(hostID: String, displayName: String) -> SessionSummary {
        var copy = self
        copy.remoteHostID = hostID
        copy.remoteDisplayName = displayName
        return copy
    }
}

/// Context-window limit used for token-usage display (persisted via
/// @AppStorage, so the raw values must stay stable).
enum ContextWindowMode: String, CaseIterable {
    case auto
    case k200 = "200k"
    case m1 = "1m"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .k200: return "200K"
        case .m1: return "1M"
        }
    }
}
