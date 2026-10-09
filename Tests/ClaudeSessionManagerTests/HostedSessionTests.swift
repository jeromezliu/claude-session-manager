import XCTest
@testable import ClaudeSessionManager

/// Drives `HostedSession` with the recorded stream-json fixtures through a
/// fake transport — the real CLI's output, replayed deterministically.
@MainActor
final class HostedSessionTests: XCTestCase {

    final class FakeTransport: ClaudeTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32, String) -> Void)?
        var sent: [[String: Any]] = []
        var started = false, terminated = false
        var pid: Int32? { nil }
        func start() throws { started = true }
        func send(_ object: [String: Any]) { sent.append(object) }
        func terminate() { terminated = true; onExit?(0, "") }
        func emit(_ obj: [String: Any]) { onMessage?(obj) }
    }

    private func outbound(_ name: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture_\(name)", withExtension: "jsonl",
                                                  subdirectory: "Fixtures/StreamJSON"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return row?["dir"] as? String == "out" ? row?["msg"] as? [String: Any] : nil
        }
    }

    private func make(_ mode: String = "default") throws -> (HostedSession, FakeTransport) {
        let t = FakeTransport()
        let s = HostedSession(cwd: "/tmp", resume: nil, permissionMode: mode, transport: t)
        try s.start()
        return (s, t)
    }

    private func type(_ m: [String: Any]) -> String? { m["type"] as? String }

    // MARK: - Streaming and turns

    func testStreamsTextAndFinishesTurn() throws {
        let (s, t) = try make()
        s.send("Reply with exactly: ALPHA")
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(type(t.sent[0]), "user")

        var sawLive = false
        for m in try outbound("basic").prefix(while: { type($0) != "result" }) {
            t.emit(m)
            if !s.liveText.isEmpty { sawLive = true }
        }
        XCTAssertTrue(sawLive, "text deltas build liveText while streaming")
        XCTAssertEqual(s.sessionID, "b81df196-5721-4873-a8f4-e49452663d89")
        XCTAssertNotNil(s.claudeVersion)

        t.emit(try XCTUnwrap(try outbound("basic").first { type($0) == "result" }))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.lastResult?.text, "ALPHA")
        XCTAssertEqual(s.liveText, "", "committed once the turn ends")
    }

    // MARK: - Approvals

    func testApprovalRoundTrip() throws {
        let (s, t) = try make()
        s.send("run two commands")
        let msgs = try outbound("perm")
        let requests = msgs.filter { type($0) == "control_request" }
        XCTAssertEqual(requests.count, 2)

        // Up to the first request: the session waits on the user.
        for m in msgs.prefix(through: try XCTUnwrap(msgs.firstIndex { type($0) == "control_request" })) { t.emit(m) }
        XCTAssertEqual(s.phase, .waiting)
        let first = try XCTUnwrap(s.pending.first)
        XCTAssertEqual(first.kind, .permission)
        XCTAssertEqual(first.ask.toolName, "Bash")
        XCTAssertNotNil(first.ask.description)

        s.answer(first.id, .allow(always: false))
        XCTAssertTrue(s.pending.isEmpty)
        let reply = try XCTUnwrap(t.sent.last?["response"] as? [String: Any])
        XCTAssertEqual(reply["request_id"] as? String, first.id)
        let body = try XCTUnwrap(reply["response"] as? [String: Any])
        XCTAssertEqual(body["behavior"] as? String, "allow")
        XCTAssertEqual((body["updatedInput"] as? [String: Any])?["command"] as? String, "echo hi > allowed.txt")
        XCTAssertNil(body["updatedPermissions"], "one-off allow doesn't add rules")

        // Answering twice is a no-op (resolve exactly once).
        let count = t.sent.count
        s.answer(first.id, .deny(message: "late"))
        XCTAssertEqual(t.sent.count, count)
    }

    func testAlwaysAllowSendsTheCLIsSuggestions() throws {
        let (s, t) = try make()
        s.send("x")
        for m in try outbound("perm") where type(m) == "control_request" { t.emit(m); break }
        let req = try XCTUnwrap(s.pending.first)
        s.answer(req.id, .allow(always: true))
        let body = (t.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertNotNil(body?["updatedPermissions"] as? [Any])
    }

    func testDenyCarriesTheMessage() throws {
        let (s, t) = try make()
        s.send("x")
        for m in try outbound("perm") where type(m) == "control_request" { t.emit(m); break }
        s.answer(try XCTUnwrap(s.pending.first).id, .deny(message: "not that file"))
        let body = (t.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(body?["behavior"] as? String, "deny")
        XCTAssertEqual(body?["message"] as? String, "not that file")
    }

    func testQuestionAnswersGoIntoUpdatedInput() throws {
        let (s, t) = try make()
        s.send("ask me")
        for m in try outbound("ask") where type(m) == "control_request" { t.emit(m) }
        let q = try XCTUnwrap(s.pending.first)
        XCTAssertEqual(q.kind, .question)
        XCTAssertTrue(q.ask.requiresUserInteraction)
        s.answer(q.id, .answer(["Which fruit do you prefer?": "Banana"]))
        let input = ((t.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any])?["updatedInput"] as? [String: Any]
        XCTAssertEqual((input?["answers"] as? [String: Any])?["Which fruit do you prefer?"] as? String, "Banana")
        XCTAssertNotNil(input?["questions"], "the original questions are kept")
    }

    func testPlanReviewIsItsOwnKind() throws {
        let (s, t) = try make("plan")
        s.send("plan it")
        for m in try outbound("plan") where type(m) == "control_request" { t.emit(m) }
        XCTAssertEqual(s.pending.first?.kind, .plan)
        XCTAssertNotNil(s.pending.first?.ask.input["plan"]?.stringValue)
    }

    // MARK: - Queueing, cancel, interrupt, mode

    func testInputWhilePendingIsHeldUntilAnswered() throws {
        let (s, t) = try make()
        s.send("first")
        for m in try outbound("perm") where type(m) == "control_request" { t.emit(m); break }
        let before = t.sent.count
        s.send("follow-up")
        XCTAssertEqual(t.sent.count, before, "not written while an approval is open")
        XCTAssertEqual(s.queued, ["follow-up"])

        s.answer(try XCTUnwrap(s.pending.first).id, .allow(always: false))
        XCTAssertEqual(s.queued, [])
        XCTAssertEqual(type(t.sent[t.sent.count - 2]), "control_response", "the answer goes first")
        XCTAssertEqual(type(t.sent.last!), "user", "then the held message")
    }

    func testCLICancellationDropsThePendingRequest() throws {
        let (s, t) = try make()
        s.send("x")
        let msgs = try outbound("pending")
        let cancelAt = try XCTUnwrap(msgs.firstIndex { type($0) == "control_cancel_request" })
        for m in msgs[...cancelAt] { t.emit(m) }
        XCTAssertTrue(s.pending.isEmpty)
        XCTAssertTrue(s.log.events.contains { $0.kind == .requestResolved(id: msgs.first { type($0) == "control_request" }!["request_id"] as! String, outcome: "canceled") })
    }

    func testInterruptAndModeChangeWriteControlRequests() throws {
        let (s, t) = try make()
        s.send("long task")
        s.interrupt()
        XCTAssertEqual((t.sent.last?["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
        s.setPermissionMode("acceptEdits")
        let req = t.sent.last?["request"] as? [String: Any]
        XCTAssertEqual(req?["subtype"] as? String, "set_permission_mode")
        XCTAssertEqual(req?["mode"] as? String, "acceptEdits")
        XCTAssertEqual(s.permissionMode, "acceptEdits")
    }

    func testProcessExitCancelsEverything() throws {
        let (s, t) = try make()
        s.send("x")
        for m in try outbound("perm") where type(m) == "control_request" { t.emit(m); break }
        t.onExit?(1, "boom")
        XCTAssertEqual(s.phase, .exited)
        XCTAssertTrue(s.pending.isEmpty)
        XCTAssertEqual(s.exitReason, "boom")
        s.send("ignored")
        XCTAssertEqual(type(t.sent.last!), "user")   // nothing new written after exit
        XCTAssertEqual(t.sent.filter { type($0) == "user" }.count, 1)
    }

    // MARK: - Event log

    func testEventLogReplaysAfterSeq() throws {
        var log = EventLog(capacity: 3)
        for i in 0..<5 { log.append(.textDelta("\(i)")) }
        XCTAssertEqual(log.lastSeq, 5)
        XCTAssertEqual(log.events(after: 3)?.map(\.seq), [4, 5])
        XCTAssertEqual(log.events(after: 5)?.count, 0)
        XCTAssertNil(log.events(after: 1), "trimmed: client needs a snapshot")
    }

    func testHostEventsAreCodable() throws {
        let (s, t) = try make()
        s.send("x")
        for m in try outbound("perm") { t.emit(m) }
        let data = try JSONEncoder().encode(s.log.events)
        let back = try JSONDecoder().decode([HostEvent].self, from: data)
        XCTAssertEqual(back, s.log.events)
        XCTAssertTrue(back.contains { if case .requestAdded = $0.kind { return true } else { return false } })
    }

    func testJSONValueRoundTrip() throws {
        let any: [String: Any] = ["a": 1, "b": true, "c": "s", "d": [1.5, NSNull()], "e": ["f": false]]
        let v = JSONValue(any: any)
        XCTAssertEqual(v["b"], .bool(true))
        XCTAssertEqual(v["a"], .number(1))
        let back = try XCTUnwrap(v.anyValue as? [String: Any])
        XCTAssertEqual(back["a"] as? Int, 1)
        XCTAssertEqual(back["b"] as? Bool, true)
        XCTAssertEqual(JSONValue(any: back), v)
    }

    // MARK: - SessionHost

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), projectFolder: "-tmp", cwd: "/tmp",
                       gitBranch: nil, claudeVersion: nil, title: "t", firstPrompt: nil, lastPrompt: nil,
                       messageCount: 1, models: [], totalOutputTokens: 0, createdAt: nil, lastActivityAt: nil,
                       modifiedAt: Date(), fileSize: 0, latestContextTokens: 0, maxContextTokens: 0)
    }

    private func hostWithPidFiles(_ files: [String: [String: Any]]) throws -> (SessionHost, [FakeTransport]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-pids-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, obj) in files {
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(name))
        }
        let host = SessionHost()
        host.sessionsDir = dir
        var made: [FakeTransport] = []
        host.makeTransport = { _ in let t = FakeTransport(); made.append(t); return t }
        return (host, made)
    }

    func testResumeRefusesASessionRunningElsewhere() throws {
        let me = ProcessInfo.processInfo.processIdentifier   // a live pid
        let (host, _) = try hostWithPidFiles([
            "1.json": ["pid": me, "sessionId": "busy", "entrypoint": "claude-desktop", "status": "idle"],
            "2.json": ["pid": 999_999, "sessionId": "stale", "entrypoint": "cli"],   // dead process
        ])
        XCTAssertThrowsError(try host.resume(summary("busy"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Claude Desktop"))
        }
        XCTAssertNil(host.blocker(for: "stale"), "a pid file of a dead process doesn't block")
        XCTAssertNoThrow(try host.resume(summary("stale")))
    }

    func testResumeReusesTheLiveHostedSession() throws {
        let (host, _) = try hostWithPidFiles([:])
        let a = try host.resume(summary("s1"))
        let b = try host.resume(summary("s1"))
        XCTAssertTrue(a === b)
        XCTAssertTrue(host.hosted("s1") === a)
    }

    func testNewSessionIsRekeyedOnceClaudeAnnouncesItsID() throws {
        var made: [FakeTransport] = []
        let (host, _) = try hostWithPidFiles([:])
        host.makeTransport = { _ in let t = FakeTransport(); made.append(t); return t }
        let s = try host.startNew(in: "/tmp", prompt: "hello")
        XCTAssertEqual((made[0].sent.first?["type"] as? String), "user", "the first prompt is sent")
        XCTAssertNil(host.recentlyStarted)
        made[0].emit(["type": "system", "subtype": "init", "session_id": "new-id"])
        XCTAssertEqual(host.recentlyStarted, "new-id")
        XCTAssertTrue(host.hosted("new-id") === s)
    }
}
