import XCTest
@testable import ClaudeSessionManager

final class GroupingTests: XCTestCase {

    // MARK: - PromptText

    func testStripsSystemReminder() {
        let raw = "<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>\n在前端加个版本号"
        XCTAssertEqual(PromptText.clean(raw), "在前端加个版本号")
        XCTAssertNil(PromptText.clean("<system-reminder>only this</system-reminder>"))
    }

    func testRendersSlashCommand() {
        let raw = "<command-message>support-tools:triage2</command-message>\n<command-name>/support-tools:triage2</command-name>\n<command-args>CS0014167</command-args>"
        XCTAssertEqual(PromptText.clean(raw), "/support-tools:triage2 CS0014167")
        XCTAssertEqual(PromptText.clean("<command-name>/clear</command-name>\n<command-args></command-args>"), "/clear")
    }

    func testDropsLocalCommandNoise() {
        XCTAssertNil(PromptText.clean("<local-command-caveat>Caveat: generated</local-command-caveat>"))
        XCTAssertNil(PromptText.clean("<local-command-stdout>ok</local-command-stdout>"))
    }

    func testTaskNotificationsShellAndPastes() {
        XCTAssertNil(PromptText.clean("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"))
        XCTAssertEqual(PromptText.clean("<bash-input>git status</bash-input>"), "! git status")
        XCTAssertNil(PromptText.clean("<bash-stdout>On branch main</bash-stdout><bash-stderr></bash-stderr>"))
        XCTAssertEqual(PromptText.clean(#"<pasted_content id="x1">log line</pasted_content> what is this?"#),
                       "log line what is this?")
    }

    func testPlainTextUntouched() {
        XCTAssertEqual(PromptText.clean("  a < b and c > d  "), "a < b and c > d")
        XCTAssertNil(PromptText.clean("   "))
    }

    func testSummaryUsesCleanedPromptAndSkipsMeta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-g-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = [
            #"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>r</system-reminder>"},{"type":"text","text":"real question"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionParser.summary(for: url))
        XCTAssertEqual(s.firstPrompt, "real question")
        XCTAssertEqual(s.title, "real question")
    }

    // MARK: - Desktop metadata

    func testParseDesktopSessionFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local_x-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"sessionId":"local_abc","cliSessionId":"cli-1","title":"项目优化","originCwd":"/repo","worktreeName":"wt-1","isArchived":true,"extra":{"ignored":1}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let parsed = try XCTUnwrap(DesktopMetadata.parseSessionFile(url))
        XCTAssertEqual(parsed.cliID, "cli-1")
        XCTAssertEqual(parsed.info, DesktopSessionInfo(desktopID: "local_abc", title: "项目优化", originCwd: "/repo",
                                                       worktreeName: "wt-1", isArchived: true))
    }

    func testParseDesktopGroups() throws {
        let json = #"""
        {"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"acct/org":{
          "groups":[{"id":"cg-1","name":"Baidu"},{"id":"cg-2","name":"Huawei"},{"id":"bad"}],
          "assignments":{"code:local_a":"cg-1","code:local_b":"cg-2","code:local_c":"cg-gone","other:x":"cg-1"},
          "order":{}}}}}}
        """#
        let parsed = try XCTUnwrap(DesktopMetadata.parseGroups(Data(json.utf8)))
        XCTAssertEqual(parsed.groups, ["Baidu", "Huawei"])
        XCTAssertEqual(parsed.assignments, ["local_a": "Baidu", "local_b": "Huawei"])
        XCTAssertNil(DesktopMetadata.parseGroups(Data(#"{"preferences":{}}"#.utf8)))
    }

    func testSnapshotJoinsGroupsToCLIIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csm-desk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let org = root.appendingPathComponent("claude-code-sessions/acct/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try #"{"sessionId":"local_a","cliSessionId":"cli-a","title":"A"}"#
            .write(to: org.appendingPathComponent("local_a.json"), atomically: true, encoding: .utf8)
        try #"{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"s":{"groups":[{"id":"g","name":"Dev"}],"assignments":{"code:local_a":"g"}}}}}}"#
            .write(to: root.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
        let snap = DesktopMetadata(root: root).snapshot()
        XCTAssertEqual(snap.sessions["cli-a"]?.title, "A")
        XCTAssertEqual(snap.groupNames, ["Dev"])
        XCTAssertEqual(snap.groupOfSession, ["cli-a": "Dev"])
        // Missing desktop data is just empty, never an error.
        XCTAssertTrue(DesktopMetadata(root: root.appendingPathComponent("nope")).snapshot().sessions.isEmpty)
    }

    // MARK: - Enrichment

    private func session(_ id: String, cwd: String, date: TimeInterval = 0, host: String? = nil) -> SessionSummary {
        var s = SessionSummary(id: id, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), projectFolder: "-x", cwd: cwd,
                               gitBranch: nil, claudeVersion: nil, title: "t-\(id)", firstPrompt: nil, lastPrompt: nil,
                               messageCount: 1, models: [], totalOutputTokens: 0, createdAt: nil,
                               lastActivityAt: Date(timeIntervalSince1970: date), modifiedAt: Date(), fileSize: 0,
                               latestContextTokens: 0, maxContextTokens: 0)
        if let host { s = s.withRemote(hostID: host, displayName: host) }
        return s
    }

    func testWorktreeFoldsIntoRepo() {
        let s = session("a", cwd: "/Users/me/Workspace/Triage/.claude/worktrees/osm-tags-5f01ee").enriched(with: nil)
        XCTAssertEqual(s.groupingRoot, "/Users/me/Workspace/Triage")
        XCTAssertEqual(s.worktreeName, "osm-tags-5f01ee")
        XCTAssertEqual(s.projectName, "Triage")
        XCTAssertNil(SessionSummary.worktreeParent(of: "/Users/me/plain"))
    }

    func testDesktopInfoWins() {
        let info = DesktopSessionInfo(desktopID: "local_a", title: "Desktop Title", originCwd: "/repo",
                                      worktreeName: "wt", isArchived: true)
        let s = session("a", cwd: "/somewhere/else").enriched(with: info)
        XCTAssertEqual(s.title, "Desktop Title")
        XCTAssertEqual(s.groupingRoot, "/repo")
        XCTAssertTrue(s.isArchived)
    }

    func testScratchSessions() {
        let s = session("a", cwd: "/Users/me/Library/Application Support/Claude/scratch-workspaces/u/o/scratch-2026-09-29-abd43b")
        XCTAssertTrue(s.isScratch)
        XCTAssertEqual(s.projectName, "Scratch")
    }

    // MARK: - Sections

    func testGroupsThenProjects() {
        let sessions = [
            session("a", cwd: "/repo/.claude/worktrees/w1", date: 5).enriched(with: nil),
            session("b", cwd: "/repo", date: 4),
            session("c", cwd: "/other", date: 3),
            session("d", cwd: "/x/Claude/scratch-workspaces/s1", date: 2),
            session("e", cwd: "/x/Claude/scratch-workspaces/s2", date: 1),
        ]
        var desktop = DesktopSnapshot()
        desktop.groupNames = ["Baidu", "Empty"]
        desktop.groupOfSession = ["c": "Baidu"]
        var local = LocalSessionMeta()
        local.groups = ["Mine"]
        local.assignments = ["a": "Mine"]

        let byGroup = SessionGrouping.sections(for: sessions, organization: .groups, local: local, desktop: desktop)
        XCTAssertEqual(byGroup.map(\.name), ["Baidu", "Mine", "repo", "Scratch"])   // empty groups hidden
        XCTAssertEqual(byGroup.map { $0.sessions.map(\.id) }, [["c"], ["a"], ["b"], ["d", "e"]])
        XCTAssertEqual(byGroup[0].kind, .group(desktop: true, local: false))
        XCTAssertEqual(byGroup[1].kind, .group(desktop: false, local: true))

        let byProject = SessionGrouping.sections(for: sessions, organization: .projects, local: local, desktop: desktop)
        XCTAssertEqual(byProject.map(\.name), ["repo", "other", "Scratch"])
        XCTAssertEqual(byProject[0].sessions.map(\.id), ["a", "b"])   // worktree + repo together
    }

    func testLocalAssignmentOverridesDesktop() {
        var desktop = DesktopSnapshot()
        desktop.groupNames = ["Baidu"]
        desktop.groupOfSession = ["a": "Baidu", "b": "Baidu"]
        var local = LocalSessionMeta()
        local.assignments = ["a": "", "b": "Huawei"]
        XCTAssertNil(SessionGrouping.group(of: "a", local: local, desktop: desktop))
        XCTAssertEqual(SessionGrouping.group(of: "b", local: local, desktop: desktop), "Huawei")
        // A group only reachable via an assignment still gets listed.
        XCTAssertEqual(SessionGrouping.allGroups(local: local, desktop: desktop), ["Baidu", "Huawei"])
    }

    func testRemoteProjectsStaySeparate() {
        let sessions = [session("a", cwd: "/repo", date: 2), session("b", cwd: "/repo", date: 1, host: "h1")]
        let sections = SessionGrouping.sections(for: sessions, organization: .projects,
                                                local: LocalSessionMeta(), desktop: .empty)
        XCTAssertEqual(sections.count, 2)
    }

    func testLocalMetaRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csm-meta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var meta = LocalSessionMeta()
        meta.groups = ["Mine"]; meta.assignments = ["a": "Mine", "b": ""]; meta.titles = ["a": "T"]
        try meta.save(to: url)
        XCTAssertEqual(LocalSessionMeta.load(from: url), meta)
        XCTAssertEqual(LocalSessionMeta.load(from: url.appendingPathExtension("missing")), LocalSessionMeta())
    }

    // MARK: - Formatting

    func testRelativeTimeNeverInFuture() {
        let now = Date()
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(0.5), now: now), "now")
        XCTAssertFalse(Fmt.relative(now.addingTimeInterval(3600), now: now).hasPrefix("in "))
    }
}
