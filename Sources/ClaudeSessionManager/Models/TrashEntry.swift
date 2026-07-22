import Foundation

/// A session that has been moved to the app-managed trash.
struct TrashEntry: Identifiable, Hashable, Sendable {
    /// Unique per trashed file (a session could, in theory, be trashed twice).
    var id: String { trashedURL.lastPathComponent }

    let summary: SessionSummary   // summary.fileURL points at the trashed copy
    let trashedURL: URL
    let metaURL: URL
    let originalPath: String
    let deletedAt: Date
    /// Set when this was a remote session — its original was already removed
    /// from the host at trash-time; recovering re-uploads it there.
    var remoteAlias: String? = nil
    var remoteDisplayName: String? = nil
    var remoteRoot: String? = nil

    var originalFolder: String {
        (originalPath as NSString).deletingLastPathComponent
    }
}

/// Sidecar JSON written next to each trashed session so it can be restored.
struct TrashMeta: Codable, Sendable {
    let originalPath: String
    let projectFolder: String
    let title: String
    let deletedAt: Date
    var remoteAlias: String? = nil
    var remoteDisplayName: String? = nil
    var remoteRoot: String? = nil
}
