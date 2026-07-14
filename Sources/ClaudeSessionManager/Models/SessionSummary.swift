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
    let title: String
    let firstPrompt: String?
    let lastPrompt: String?

    let messageCount: Int
    let models: [String]
    let totalOutputTokens: Int

    let createdAt: Date?
    let modifiedAt: Date
    let fileSize: Int

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
        SessionSummary(
            id: id, fileURL: fileURL, projectFolder: projectFolder,
            cwd: cwd, gitBranch: gitBranch, claudeVersion: claudeVersion,
            title: newTitle, firstPrompt: firstPrompt, lastPrompt: lastPrompt,
            messageCount: messageCount, models: models,
            totalOutputTokens: totalOutputTokens, createdAt: createdAt,
            modifiedAt: modifiedAt, fileSize: fileSize
        )
    }
}
