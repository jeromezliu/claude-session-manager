import XCTest
@testable import ClaudeSessionManager

/// Opt-in end-to-end check of the real transport against the installed
/// `claude` (costs a few cents): CSM_LIVE=1 swift test --filter HostedSessionLiveTests
@MainActor
final class HostedSessionLiveTests: XCTestCase {

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func testRealProcessApprovalAndSecondTurn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CSM_LIVE"] == "1", "set CSM_LIVE=1")
        XCTAssertNotNil(ClaudeEnvironment.claudePath, "claude found via the login shell")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let launch = ClaudeLaunch(cwd: dir.path, resume: nil, model: "claude-haiku-4-5-20251001")
        let session = HostedSession(cwd: dir.path, resume: nil, transport: ProcessClaudeTransport(launch: launch))
        try session.start()

        session.send("Use the Bash tool to run exactly: echo live > live.txt  — then reply with exactly: DONE")
        let asked = await waitFor(120) { !session.pending.isEmpty || session.phase == .exited }
        XCTAssertTrue(asked, "an approval request arrived")
        XCTAssertNil(session.exitReason)
        let request = try XCTUnwrap(session.pending.first)
        XCTAssertEqual(request.ask.toolName, "Bash")
        session.answer(request.id, .allow(always: false))

        let finished = await waitFor(120) { session.lastResult != nil && session.phase == .idle }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.lastResult?.text?.contains("DONE"), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("live.txt").path))
        XCTAssertNotNil(session.sessionID)

        session.send("Reply with exactly: AGAIN")
        let second = await waitFor(120) { session.lastResult?.text?.contains("AGAIN") == true }
        XCTAssertTrue(second, "the same process serves another turn")
        session.stop()
        _ = await waitFor(10) { session.phase == .exited }
        XCTAssertEqual(session.phase, .exited)
    }
}
