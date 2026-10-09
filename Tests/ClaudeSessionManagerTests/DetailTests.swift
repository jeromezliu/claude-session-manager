import XCTest
@testable import ClaudeSessionManager

final class DetailTests: XCTestCase {

    // MARK: - Conversation

    private func ev(_ id: Int, _ kind: TranscriptEvent.Kind, _ blocks: [TranscriptEvent.Block]) -> TranscriptEvent {
        TranscriptEvent(id: id, kind: kind, timestamp: nil, model: kind == .assistant ? "claude-x" : nil, blocks: blocks)
    }

    func testFoldsToolWorkBetweenPromptAndReply() {
        let events = [
            ev(0, .user, [.text("fix the bug")]),
            ev(1, .assistant, [.thinking("hmm"), .toolUse(name: "Bash", input: "ls")]),
            ev(2, .user, [.toolResult(text: "a b", isError: false)]),
            ev(3, .assistant, [.toolUse(name: "Edit", input: "x"), .toolUse(name: "Bash", input: "make")]),
            ev(4, .user, [.toolResult(text: "boom", isError: true)]),
            ev(5, .attachment, [.note("Attachment: env")]),
            ev(6, .assistant, [.text("Fixed it.")]),
            ev(7, .user, [.text("thanks")]),
        ]
        let items = ConversationBuilder.items(from: events)
        XCTAssertEqual(items.map(\.id), ["p0", "a1", "n5", "r6", "p7"])
        guard case .activity(let a) = items[1] else { return XCTFail() }
        XCTAssertEqual(a.callCount, 3)
        XCTAssertEqual(a.toolCounts.first?.name, "Bash")
        XCTAssertEqual(a.toolCounts.first?.count, 2)
        XCTAssertTrue(a.hasError)
    }

    func testMetaTurnsAreNotPrompts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try [#"{"type":"user","isMeta":true,"message":{"content":"Caveat: generated"}}"#,
             #"{"type":"user","message":{"content":"real"}}"#].joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let items = ConversationBuilder.items(from: SessionParser.transcript(for: url))
        XCTAssertEqual(items.map(\.id), ["n0", "p1"])
    }

    // MARK: - Insights

    func testInsightsCollectOutputs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-i-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = [
            #"{"type":"pr-link","prNumber":3,"prUrl":"https://github.com/o/r/pull/3","prRepository":"o/r"}"#,
            #"{"type":"pr-link","prNumber":3,"prUrl":"https://github.com/o/r/pull/3","prRepository":"o/r"}"#,
            #"{"type":"system","subtype":"away_summary","content":"Goal was X; done Y. Next: Z. (disable recaps in /config)","timestamp":"2026-08-27T04:12:07.891Z"}"#,
            #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/r/a.swift"}},{"type":"tool_use","name":"Write","input":{"file_path":"/r/a.swift"}},{"type":"tool_use","name":"SendUserFile","input":{"files":["/tmp/out.csv"],"caption":"the data"}}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let r = try XCTUnwrap(SessionParser.transcriptEvents(for: url))
        XCTAssertEqual(r.insights.pullRequests.map(\.number), [3])
        XCTAssertEqual(r.insights.recap, "Goal was X; done Y. Next: Z.")
        XCTAssertNotNil(r.insights.recapDate)
        XCTAssertEqual(r.insights.compactions, 1)
        XCTAssertEqual(r.insights.editedFiles, ["/r/a.swift": 2])
        XCTAssertEqual(r.insights.deliveredFiles.map(\.path), ["/tmp/out.csv"])
        XCTAssertEqual(r.insights.deliveredFiles.first?.caption, "the data")
    }

    func testInsightsCollectArtifactsAndRepublishUpdatesInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        func publish(_ use: String, title: String) -> [String] {
            [#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(use)","name":"Artifact","input":{"file_path":"/w/page.html","description":"Delivery notes"}}]}}"#,
             #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(use)","content":"Published"}]},"toolUseResult":{"url":"https://claude.ai/code/artifact/abc","path":"/w/page.html","artifact_id":"abc","title":"\#(title)"}}"#]
        }
        let lines = publish("t1", title: "Draft") + publish("t2", title: "Final")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(SessionParser.transcriptEvents(for: url)).insights.artifacts
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.first?.title, "Final")
        XCTAssertEqual(a.first?.url, "https://claude.ai/code/artifact/abc")
        XCTAssertEqual(a.first?.path, "/w/page.html")
        XCTAssertEqual(a.first?.description, "Delivery notes")
    }

    func testCustomTitleWinsOverAITitle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-t-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try [#"{"type":"custom-title","customTitle":"Mine"}"#, #"{"type":"ai-title","aiTitle":"Generated"}"#]
            .joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionParser.summary(for: url)?.title, "Mine")
    }

    // MARK: - Markdown

    func testMarkdownBlocks() {
        let md = """
        ## Two fixes

        **Bold** paragraph
        continues here.

        - one
          - nested
        2. second

        ```swift
        let x = 1
        ```

        > quoted
        > more

        | a | b |
        |---|:-:|
        | 1 | 2 |

        ---
        """
        XCTAssertEqual(Markdown.parse(md), [
            .heading(level: 2, text: "Two fixes"),
            .paragraph("**Bold** paragraph\ncontinues here."),
            .listItem(marker: "•", indent: 0, text: "one"),
            .listItem(marker: "•", indent: 1, text: "nested"),
            .listItem(marker: "2.", indent: 0, text: "second"),
            .code(language: "swift", text: "let x = 1"),
            .quote("quoted\nmore"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .rule,
        ])
    }

    func testMarkdownEdgeCases() {
        XCTAssertEqual(Markdown.parse("#hashtag not heading"), [.paragraph("#hashtag not heading")])
        XCTAssertEqual(Markdown.parse("```\nunterminated"), [.code(language: nil, text: "unterminated")])
        XCTAssertEqual(Markdown.parse(""), [])
    }

    // MARK: - Formatting

    func testDurationAndToolName() {
        XCTAssertEqual(Fmt.duration(45), "45s")
        XCTAssertEqual(Fmt.duration(3 * 3600 + 20 * 60), "3h 20m")
        XCTAssertEqual(Fmt.duration(5 * 86_400), "5d")
        XCTAssertEqual(Fmt.toolName("mcp__08f7__getJiraIssue"), "getJiraIssue")
        XCTAssertEqual(Fmt.toolName("Bash"), "Bash")
    }
}
