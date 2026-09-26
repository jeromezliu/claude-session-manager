import XCTest
@testable import ClaudeSessionManager

final class ParserTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ type: String, _ extra: String = "", ts: String = "2026-07-14T10:00:00.000Z") -> String {
        #"{"type":"\#(type)","timestamp":"\#(ts)","cwd":"/Users/me/proj"\#(extra.isEmpty ? "" : "," + extra)}"#
    }
    private func user(_ text: String, ts: String = "2026-07-14T10:00:00.000Z") -> String {
        line("user", #""message":{"role":"user","content":"\#(text)"}"#, ts: ts)
    }
    private func assistant(_ text: String, model: String = "claude-x", out: Int = 5, ctx: Int = 100,
                           ts: String = "2026-07-14T10:00:00.000Z") -> String {
        line("assistant", #""message":{"model":"\#(model)","content":[{"type":"text","text":"\#(text)"}],"usage":{"output_tokens":\#(out),"input_tokens":\#(ctx)}}"#, ts: ts)
    }

    private func write(_ lines: [String], trailingNewline: Bool = true, name: String = "s") throws -> URL {
        let url = dir.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
    }

    // MARK: - Summary

    func testSummaryFields() throws {
        let url = try write([
            user("first question"),
            assistant("answer", model: "m1", out: 7, ctx: 300),
            #"{"type":"ai-title","aiTitle":"Nice Title"}"#,
            "not json at all",
            user("second", ts: "2026-07-14T11:00:00Z"),
            assistant("again", model: "m2", out: 3, ctx: 50, ts: "2026-07-14T11:00:00Z"),
        ])
        let s = try XCTUnwrap(SessionParser.summary(for: url))
        XCTAssertEqual(s.title, "Nice Title")
        XCTAssertEqual(s.cwd, "/Users/me/proj")
        XCTAssertEqual(s.firstPrompt, "first question")
        XCTAssertEqual(s.lastPrompt, "second")
        XCTAssertEqual(s.messageCount, 4)
        XCTAssertEqual(s.models, ["m1", "m2"])
        XCTAssertEqual(s.totalOutputTokens, 10)
        XCTAssertEqual(s.latestContextTokens, 50)
        XCTAssertEqual(s.maxContextTokens, 300)
        XCTAssertNotNil(s.createdAt)
        XCTAssertEqual(s.lastActivityAt?.timeIntervalSince1970, s.createdAt.map { $0.timeIntervalSince1970 + 3600 })
    }

    func testTitleFallsBackToFirstPrompt() throws {
        let url = try write([user(String(repeating: "a", count: 100))])
        XCTAssertEqual(SessionParser.summary(for: url)?.title.count, 80)
        let empty = try write([], name: "empty")
        XCTAssertEqual(SessionParser.summary(for: empty)?.title, "(untitled session)")
    }

    func testPartialTrailingLineIsLeftForLater() throws {
        let url = try write([user("one"), #"{"type":"user","mess"#], trailingNewline: false)
        let first = try XCTUnwrap(SessionParser.summaryState(for: url))
        XCTAssertEqual(first.state.messageCount, 1)
        try append(#"age":{"content":"two"}}"# + "\n", to: url)
        let resumed = try XCTUnwrap(SessionParser.summaryState(for: url, resuming: first.state, from: first.offset))
        XCTAssertEqual(resumed.state.messageCount, 2)
        XCTAssertEqual(resumed.state.lastPrompt, "two")
    }

    func testCompleteTrailingLineWithoutNewlineIsConsumed() throws {
        let url = try write([user("one"), user("two")], trailingNewline: false)
        let r = try XCTUnwrap(SessionParser.summaryState(for: url))
        XCTAssertEqual(r.state.messageCount, 2)
        XCTAssertEqual(Int(r.offset), try Data(contentsOf: url).count)
    }

    func testIncrementalSummaryMatchesFullParse() throws {
        let url = try write([user("q1"), assistant("a1")])
        let first = try XCTUnwrap(SessionParser.summaryState(for: url))
        try append([user("q2"), assistant("a2", model: "m9", out: 11, ctx: 999)].joined(separator: "\n") + "\n", to: url)
        let resumed = try XCTUnwrap(SessionParser.summaryState(for: url, resuming: first.state, from: first.offset))
        let full = try XCTUnwrap(SessionParser.summaryState(for: url))
        XCTAssertEqual(resumed.offset, full.offset)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        XCTAssertEqual(try enc.encode(resumed.state), try enc.encode(full.state))
    }

    // MARK: - Transcript

    func testTranscriptIncrementalKeepsStableIDs() throws {
        let url = try write([user("q1"), #"{"type":"ai-title","aiTitle":"t"}"#, assistant("a1")])
        let first = try XCTUnwrap(SessionParser.transcriptEvents(for: url))
        XCTAssertEqual(first.events.map(\.id), [0, 2])
        try append(user("q2") + "\n\n" + assistant("a2") + "\n", to: url)
        let more = try XCTUnwrap(SessionParser.transcriptEvents(for: url, from: first.cursor))
        let full = SessionParser.transcript(for: url)
        XCTAssertEqual(first.events + more.events, full)
        XCTAssertEqual(full.map(\.id), [0, 2, 3, 4])
    }

    // MARK: - SummaryCache

    func testSummaryCacheResumesAndDetectsRewrite() throws {
        let cache = SummaryCache(fileURL: nil)
        let url = try write([user("q1")])
        func stat() throws -> (Date, Int) {
            var url = url
            url.removeAllCachedResourceValues()
            let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (v.contentModificationDate!, v.fileSize!)
        }
        var (m, sz) = try stat()
        XCTAssertEqual(cache.summary(for: url, mtime: m, size: sz)?.messageCount, 1)

        try append(user("q2") + "\n", to: url)
        (m, sz) = try stat()
        XCTAssertEqual(cache.summary(for: url, mtime: m, size: sz)?.lastPrompt, "q2")

        // Rewritten with different (longer) content: must not resume.
        _ = try write([user("zz"), user("yy"), user("xx")])
        (m, sz) = try stat()
        let s = cache.summary(for: url, mtime: m.addingTimeInterval(1), size: sz)
        XCTAssertEqual(s?.firstPrompt, "zz")
        XCTAssertEqual(s?.messageCount, 3)
    }

    func testSummaryCachePersists() throws {
        let store = dir.appendingPathComponent("cache.json")
        let url = try write([user("persisted")])
        let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let a = SummaryCache(fileURL: store)
        XCTAssertNotNil(a.summary(for: url, mtime: v.contentModificationDate!, size: v.fileSize!))
        a.persistIfNeeded()

        // Make the file unreadable-as-parsed: a hit must come from the cache.
        let b = SummaryCache(fileURL: store)
        try FileManager.default.removeItem(at: url)
        try "".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(b.summary(for: url, mtime: v.contentModificationDate!, size: v.fileSize!)?.firstPrompt, "persisted")
    }
}
