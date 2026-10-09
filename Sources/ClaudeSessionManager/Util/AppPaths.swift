import Foundation

/// Locations the app owns on disk.
enum AppPaths {
    /// `~/Library/Application Support/ClaudeSessionManager` (temp dir as a last resort).
    /// Dev-only: `CSM_SUPPORT_DIR` points it elsewhere, so test runs never
    /// touch the user's real groups, cache or trash.
    static var support: URL {
        if let dev = ProcessInfo.processInfo.environment["CSM_SUPPORT_DIR"], !dev.isEmpty {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeSessionManager", isDirectory: true)
    }
}
