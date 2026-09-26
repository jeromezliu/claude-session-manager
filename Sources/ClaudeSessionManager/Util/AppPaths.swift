import Foundation

/// Locations the app owns on disk.
enum AppPaths {
    /// `~/Library/Application Support/ClaudeSessionManager` (temp dir as a last resort).
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeSessionManager", isDirectory: true)
    }
}
