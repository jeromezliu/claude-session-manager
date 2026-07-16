import Foundation

/// Caches parsed `SessionSummary` values keyed by file path + (mtime, size) so
/// repeated scans (triggered by the auto-refresh watcher) only re-parse files
/// that actually changed.
final class SummaryCache {
    static let shared = SummaryCache()

    private struct Entry { let mtime: TimeInterval; let size: Int; let summary: SessionSummary }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    /// Return a cached summary if the file is unchanged, else parse, cache, return.
    func summary(for url: URL, mtime: Date, size: Int) -> SessionSummary? {
        let key = url.path
        let stamp = mtime.timeIntervalSince1970

        lock.lock()
        if let e = entries[key], e.mtime == stamp, e.size == size {
            lock.unlock()
            return e.summary
        }
        lock.unlock()

        guard let summary = SessionParser.summary(for: url) else { return nil }
        lock.lock()
        entries[key] = Entry(mtime: stamp, size: size, summary: summary)
        lock.unlock()
        return summary
    }
}
