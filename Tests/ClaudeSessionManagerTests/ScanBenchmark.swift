import XCTest
@testable import ClaudeSessionManager

/// Times parsing against the real ~/.claude/projects. Opt-in (CSM_BENCH=1)
/// since it depends on local data; run in release for meaningful numbers:
///   CSM_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter ScanBenchmark
final class ScanBenchmark: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CSM_BENCH"] == "1", "set CSM_BENCH=1 to run")
    }

    func testColdSummaryParse() throws {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && !$0.pathComponents.contains("subagents") }
        let start = Date()
        let parsed = files.compactMap { SessionParser.summary(for: $0) }
        print("BENCH cold summary parse: \(parsed.count) files in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }

    func testLargestTranscriptParse() throws {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard let biggest = files.max(by: { size($0) < size($1) }) else { return }
        let start = Date()
        let events = SessionParser.transcript(for: biggest)
        print("BENCH full transcript parse: \(size(biggest) / 1_000_000) MB, \(events.count) events in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }
}

/// Opt-in parity check: dumps a fingerprint of every real session's summary
/// and transcript to CSM_GOLDEN (write mode if the file is absent, compare
/// mode if present). Used to prove a parser rewrite changes no output.
final class ParserGolden: XCTestCase {
    func testGolden() throws {
        guard let path = ProcessInfo.processInfo.environment["CSM_GOLDEN"] else { throw XCTSkip("set CSM_GOLDEN") }
        // Point CSM_GOLDEN_ROOT at a frozen copy (`cp -cR ~/.claude/projects …`)
        // so live sessions being written don't show up as false mismatches.
        let root = ProcessInfo.processInfo.environment["CSM_GOLDEN_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
        let stable = files.map { f -> String in
            guard let s = SessionParser.summary(for: f) else { return "\(f.path.replacingOccurrences(of: root.path, with: ""))\tnil" }
            let t = SessionParser.transcript(for: f)
            let tx = t.map { e in "\(e.id)/\(e.kind)/\(e.timestamp?.timeIntervalSince1970 ?? 0)/\(e.model ?? "")/\(e.blocks)" }.joined(separator: "\u{1}")
            let summary = "\(s.title)|\(s.cwd)|\(s.gitBranch ?? "")|\(s.claudeVersion ?? "")|\(s.firstPrompt ?? "")|\(s.lastPrompt ?? "")|\(s.messageCount)|\(s.models)|\(s.totalOutputTokens)|\(s.createdAt?.timeIntervalSince1970 ?? 0)|\(s.lastActivityAt?.timeIntervalSince1970 ?? 0)|\(s.latestContextTokens)|\(s.maxContextTokens)"
            return "\(f.path.replacingOccurrences(of: root.path, with: ""))\t\(summary)\t\(t.count)\t\(tx.utf8.count)\t\(fnv(tx))"
        }.joined(separator: "\n")
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let a = existing.split(separator: "\n"), b = stable.split(separator: "\n")
            XCTAssertEqual(a.count, b.count)
            for (x, y) in zip(a, b) where x != y { XCTFail("mismatch:\n  old: \(x.prefix(400))\n  new: \(y.prefix(400))") }
        } else {
            try stable.write(toFile: path, atomically: true, encoding: .utf8)
            print("GOLDEN written: \(files.count) files")
        }
    }

    private func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

final class ScanCacheBenchmark: XCTestCase {
    /// Full `SessionStore.scan` path: cold (empty cache, parallel parse),
    /// warm (persisted cache reloaded, as on the next launch), and one
    /// appended-to file (the live-session case).
    func testScanColdWarmAppend() throws {
        guard ProcessInfo.processInfo.environment["CSM_BENCH"] == "1",
              let rootPath = ProcessInfo.processInfo.environment["CSM_GOLDEN_ROOT"] else { throw XCTSkip("set CSM_BENCH=1 and CSM_GOLDEN_ROOT") }
        let root = URL(fileURLWithPath: rootPath)
        func time(_ label: String, _ body: () throws -> Void) rethrows {
            let t = Date(); try body()
            print("BENCH \(label): \(String(format: "%.3f", Date().timeIntervalSince(t)))s")
        }
        let cacheFile = FileManager.default.temporaryDirectory.appendingPathComponent("csm-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheFile) }
        let cold = SummaryCache(fileURL: cacheFile)
        try time("scan cold (parallel)") { _ = try SessionStore.scan(root: root, includeTemp: true, cache: cold) }
        try time("persist cache") { cold.persistIfNeeded() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: cacheFile.path))?[.size] as? Int) ?? 0
        print("BENCH cache file: \(size / 1024) KB")
        try time("next launch: load cache + scan") {
            let warm = SummaryCache(fileURL: cacheFile)
            _ = try SessionStore.scan(root: root, includeTemp: true, cache: warm)
        }

        // Live session: append one line to the biggest file and re-summarize.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let fsize = { (u: URL) in ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0 }
        let big = files.max { fsize($0) < fsize($1) }!
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("csm-bench-big.jsonl")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: big, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let live = SummaryCache(fileURL: nil)
        try time("big file first summary (\(fsize(copy) / 1_000_000) MB)") {
            _ = live.summary(for: copy, mtime: Date(timeIntervalSince1970: 1), size: fsize(copy))
        }
        let h = try FileHandle(forWritingTo: copy)
        try h.seekToEnd(); try h.write(contentsOf: Data(#"{"type":"user","message":{"content":"appended"}}"#.utf8 + [0x0A])); try h.close()
        try time("big file after append (incremental)") {
            let s = live.summary(for: copy, mtime: Date(timeIntervalSince1970: 2), size: fsize(copy))
            XCTAssertEqual(s?.lastPrompt, "appended")
        }
    }
}
