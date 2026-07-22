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
    /// mirrored cache (nil for local sessions). `remoteAlias` matches
    /// `RemoteHost.alias`, so a remote path can always be reconstructed as
    /// `<host.remoteRoot>/<projectFolder>/<id>.jsonl`.
    var remoteAlias: String? = nil
    var remoteDisplayName: String? = nil

    /// True when the session contains at least one real conversation turn.
    var hasConversation: Bool { messageCount > 0 }

    /// True for a session mirrored from a remote (SSH) host.
    var isRemote: Bool { remoteAlias != nil }

    /// Best timestamp for sorting: last conversation, else file mtime.
    var sortDate: Date { lastActivityAt ?? modifiedAt }

    /// Resolve the context-window limit for display given the user's setting.
    /// "auto" bumps to 1M once a session's observed usage exceeds 200k.
    func contextWindow(mode: String) -> Int {
        switch mode {
        case "200k": return 200_000
        case "1m": return 1_000_000
        default: return maxContextTokens > 200_000 ? 1_000_000 : 200_000
        }
    }

    /// A readable project name derived from the cwd (last path component).
    var projectName: String {
        let path = cwd.isEmpty ? Self.decodeFolder(projectFolder) : cwd
        return (path as NSString).lastPathComponent
    }

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

    /// A copy with a new title (used after rename / when restoring a stored title).
    func withTitle(_ newTitle: String) -> SessionSummary {
        var copy = self
        copy.title = newTitle
        return copy
    }

    /// A copy tagged as belonging to a remote host (applied once, by the scan
    /// that discovers it in that host's mirrored cache directory).
    func withRemote(alias: String, displayName: String) -> SessionSummary {
        var copy = self
        copy.remoteAlias = alias
        copy.remoteDisplayName = displayName
        return copy
    }
}
