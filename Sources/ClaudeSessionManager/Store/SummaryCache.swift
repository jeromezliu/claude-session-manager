import Foundation

/// Caches parsed session summaries keyed by file path, so repeated scans
/// (triggered by the auto-refresh watcher) do as little work as possible:
///
/// - unchanged file (same mtime + size) → cached summary, no I/O;
/// - file that only grew (Claude appends) → resume parsing at the byte where
///   the last parse stopped, instead of re-reading a possibly 100 MB file;
/// - anything else → full re-parse.
///
/// The cache is persisted to Application Support, so a cold launch only
/// parses files that changed since the app last ran.
final class SummaryCache: @unchecked Sendable {
    static let shared = SummaryCache(fileURL: AppPaths.support.appendingPathComponent("summary-cache.json"))

    /// Bump whenever `SummaryState` or the parse logic changes meaning, so
    /// stale persisted state is discarded instead of resumed.
    private static let formatVersion = 1
    /// Bytes hashed at the start of the file to detect a rewrite (same path,
    /// different content) that happens to be at least as long as before.
    private static let fingerprintLength = 4096

    struct Entry: Codable {
        var mtime: TimeInterval
        var size: Int
        /// Byte offset where parsing stopped (≤ size; a partial last line is left unread).
        var offset: UInt64
        /// Hash of the first `fingerprintLength` bytes, checked before resuming.
        var fingerprint: UInt64
        var fingerprintLength: Int
        var state: SessionParser.SummaryState
    }

    private struct Stored: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    private var dirty = false
    private let lock = NSLock()

    /// `fileURL == nil` → in-memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == Self.formatVersion {
            entries = stored.entries
        }
    }

    /// Return the summary for `url`, parsing only what changed since last time.
    func summary(for url: URL, mtime: Date, size: Int) -> SessionSummary? {
        let key = url.path
        let stamp = mtime.timeIntervalSince1970

        lock.lock()
        let cached = entries[key]
        lock.unlock()

        if let cached, cached.mtime == stamp, cached.size == size {
            return cached.state.summary(for: url, mtime: mtime, size: size)
        }

        let entry: Entry
        if let cached, size >= cached.size, cached.offset > 0,
           Self.fingerprint(of: url, length: cached.fingerprintLength) == cached.fingerprint,
           let resumed = SessionParser.summaryState(for: url, resuming: cached.state, from: cached.offset) {
            // Appended to: continue from where the previous parse stopped.
            entry = Self.makeEntry(url: url, mtime: stamp, size: size, offset: resumed.offset, state: resumed.state)
        } else {
            guard let fresh = SessionParser.summaryState(for: url) else { return nil }
            entry = Self.makeEntry(url: url, mtime: stamp, size: size, offset: fresh.offset, state: fresh.state)
        }

        lock.lock()
        entries[key] = entry
        dirty = true
        lock.unlock()
        return entry.state.summary(for: url, mtime: mtime, size: size)
    }

    /// Write the cache to disk if anything changed, dropping entries whose
    /// file no longer exists (trashed sessions, removed remote hosts, …).
    func persistIfNeeded() {
        guard let fileURL else { return }
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let fm = FileManager.default
        entries = entries.filter { fm.fileExists(atPath: $0.key) }
        let snapshot = Stored(version: Self.formatVersion, entries: entries)
        dirty = false
        lock.unlock()

        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // Best effort: the cache only saves work, it never holds data.
        }
    }

    private static func makeEntry(url: URL, mtime: TimeInterval, size: Int, offset: UInt64,
                                  state: SessionParser.SummaryState) -> Entry {
        let length = min(Int(offset), fingerprintLength)
        return Entry(mtime: mtime, size: size, offset: offset,
                     fingerprint: fingerprint(of: url, length: length), fingerprintLength: length, state: state)
    }

    /// FNV-1a of the file's first `length` bytes (0 when unreadable/empty).
    private static func fingerprint(of url: URL, length: Int) -> UInt64 {
        guard length > 0, let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: length) else { return 0 }
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
