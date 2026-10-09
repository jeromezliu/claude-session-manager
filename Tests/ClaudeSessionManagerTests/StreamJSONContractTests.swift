import XCTest

/// Contract tests over recorded `claude -p --input-format/--output-format
/// stream-json --permission-prompt-tool stdio` sessions (see
/// docs/remote/P0-stream-json-protocol.md). They pin the message shapes the
/// remote host relies on; after a Claude Code upgrade, re-record with
/// Tools/stream-json-spike and rerun to see what changed.
final class StreamJSONContractTests: XCTestCase {

    private struct Row { let dir: String; let msg: [String: Any] }

    private func fixture(_ name: String) throws -> [Row] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture_\(name)", withExtension: "jsonl",
                                                  subdirectory: "Fixtures/StreamJSON"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return Row(dir: o["dir"] as! String, msg: o["msg"] as! [String: Any])
        }
    }

    private func outbound(_ rows: [Row], type: String) -> [[String: Any]] {
        rows.filter { $0.dir == "out" && $0.msg["type"] as? String == type }.map(\.msg)
    }

    private func canUseTool(_ rows: [Row]) -> [[String: Any]] {
        outbound(rows, type: "control_request").compactMap { m in
            let req = m["request"] as? [String: Any]
            return req?["subtype"] as? String == "can_use_tool" ? req : nil
        }
    }

    func testInitAnnouncesVersionAndSession() throws {
        let rows = try fixture("basic")
        let inits = outbound(rows, type: "system").filter { $0["subtype"] as? String == "init" }
        let first = try XCTUnwrap(inits.first)
        XCTAssertNotNil(first["claude_code_version"] as? String)
        XCTAssertNotNil(first["session_id"] as? String)
        XCTAssertNotNil(first["permissionMode"] as? String)
        // Two turns in one long-lived process share one session.
        let results = outbound(rows, type: "result")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.compactMap { $0["session_id"] as? String }).count, 1)
    }

    func testTokenStreamingUsesStreamEvents() throws {
        let rows = try fixture("basic")
        let deltas = outbound(rows, type: "stream_event").compactMap {
            (($0["event"] as? [String: Any])?["delta"] as? [String: Any])?["type"] as? String
        }
        XCTAssertTrue(deltas.contains("text_delta"))
    }

    func testCanUseToolCarriesWhatTheApprovalSheetNeeds() throws {
        let reqs = canUseTool(try fixture("perm"))
        XCTAssertEqual(reqs.count, 2)
        for r in reqs {
            XCTAssertEqual(r["tool_name"] as? String, "Bash")
            XCTAssertNotNil(r["input"] as? [String: Any])
            XCTAssertNotNil(r["tool_use_id"] as? String)
            XCTAssertNotNil(r["description"] as? String)
            XCTAssertNotNil(r["permission_suggestions"] as? [Any])
        }
        // A deny with a message reaches Claude and is reported in the result.
        let result = try XCTUnwrap(outbound(try fixture("perm"), type: "result").last)
        XCTAssertEqual((result["permission_denials"] as? [Any])?.count, 1)
    }

    func testResponsesUseControlResponseEnvelope() throws {
        let inbound = try fixture("perm").filter { $0.dir == "in" && $0.msg["type"] as? String == "control_response" }
        let response = try XCTUnwrap((inbound.first?.msg["response"] as? [String: Any]))
        XCTAssertEqual(response["subtype"] as? String, "success")
        XCTAssertNotNil(response["request_id"] as? String)
        XCTAssertNotNil((response["response"] as? [String: Any])?["behavior"] as? String)
    }

    func testAskUserQuestionReachesTheClientAndTakesAnswers() throws {
        let rows = try fixture("ask")
        let req = try XCTUnwrap(canUseTool(rows).first { $0["tool_name"] as? String == "AskUserQuestion" })
        XCTAssertEqual(req["requires_user_interaction"] as? Bool, true)
        let questions = try XCTUnwrap((req["input"] as? [String: Any])?["questions"] as? [[String: Any]])
        XCTAssertFalse(questions.isEmpty)
        XCTAssertNotNil(questions[0]["options"] as? [Any])
        // Answered via allow + updatedInput.answers {question: label}.
        XCTAssertEqual(outbound(rows, type: "result").last?["result"] as? String, "BANANA")
    }

    func testExitPlanModeCarriesThePlan() throws {
        let req = try XCTUnwrap(canUseTool(try fixture("plan")).first { $0["tool_name"] as? String == "ExitPlanMode" })
        XCTAssertNotNil((req["input"] as? [String: Any])?["plan"] as? String)
        XCTAssertEqual(req["requires_user_interaction"] as? Bool, true)
    }

    func testInterruptEndsTheTurnButKeepsTheProcess() throws {
        let rows = try fixture("interrupt")
        let results = outbound(rows, type: "result")
        XCTAssertEqual(results.first?["subtype"] as? String, "error_during_execution")
        XCTAssertEqual(results.last?["result"] as? String, "STILL HERE")
        let ack = outbound(rows, type: "control_response").first?["response"] as? [String: Any]
        XCTAssertNotNil((ack?["response"] as? [String: Any])?["still_queued"])
    }

    func testResumeContinuesTheSameSession() throws {
        let result = try XCTUnwrap(outbound(try fixture("resume"), type: "result").last)
        XCTAssertEqual(result["result"] as? String, "ONE TWO")
    }

    func testInterruptWithPendingApprovalCancelsIt() throws {
        let rows = try fixture("pending")
        let pendingID = try XCTUnwrap(outbound(rows, type: "control_request").first?["request_id"] as? String)
        // The CLI withdraws the open request by id, then ends the turn.
        let cancels = outbound(rows, type: "control_cancel_request")
        XCTAssertEqual(cancels.compactMap { $0["request_id"] as? String }, [pendingID])
        XCTAssertEqual(outbound(rows, type: "result").first?["subtype"] as? String, "error_during_execution")
    }

    func testPermissionModeCanChangeMidSession() throws {
        let rows = try fixture("pending")
        let acks = outbound(rows, type: "control_response").compactMap {
            (($0["response"] as? [String: Any])?["response"] as? [String: Any])?["mode"] as? String
        }
        XCTAssertEqual(acks, ["acceptEdits"])
        // After the switch, the Write ran without another approval request.
        XCTAssertEqual(canUseTool(rows).filter { $0["tool_name"] as? String == "Write" }.count, 0)
        XCTAssertEqual(outbound(rows, type: "result").last?["subtype"] as? String, "success")
    }
}
