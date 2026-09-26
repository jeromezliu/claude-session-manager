import XCTest
@testable import ClaudeSessionManager

final class UtilTests: XCTestCase {

    // MARK: - Folder encoding

    func testEncodedFolderMatchesClaude() {
        XCTAssertEqual(TerminalSession.encodedFolder(for: "/Users/me/My Proj.v2"), "-Users-me-My-Proj-v2")
        XCTAssertEqual(TerminalSession.encodedFolder(for: "/home/u/~x_y"), "-home-u--x-y")
        XCTAssertEqual(TerminalSession.encodedFolder(for: "/tmp/中文"), "-tmp---")
    }

    func testDecodeFolder() {
        XCTAssertEqual(SessionSummary.decodeFolder("-Users-me-x"), "/Users/me/x")
        XCTAssertEqual(SessionSummary.decodeFolder("plain"), "plain")
    }

    // MARK: - SessionSummary

    private func summary(cwd: String, maxContext: Int = 0) -> SessionSummary {
        SessionSummary(id: "x", fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"), projectFolder: "-p", cwd: cwd,
                       gitBranch: nil, claudeVersion: nil, title: "t", firstPrompt: nil, lastPrompt: nil,
                       messageCount: 0, models: [], totalOutputTokens: 0, createdAt: nil, lastActivityAt: nil,
                       modifiedAt: Date(), fileSize: 0, latestContextTokens: 0, maxContextTokens: maxContext)
    }

    func testEphemeral() {
        XCTAssertTrue(summary(cwd: "/private/var/folders/ab/T/claude-analysis-123").isEphemeral)
        XCTAssertTrue(summary(cwd: "/tmp/scratch").isEphemeral)
        XCTAssertFalse(summary(cwd: "/Users/me/Workspace").isEphemeral)
    }

    func testContextWindow() {
        XCTAssertEqual(summary(cwd: "/a", maxContext: 150_000).contextWindow(mode: .auto), 200_000)
        XCTAssertEqual(summary(cwd: "/a", maxContext: 250_000).contextWindow(mode: .auto), 1_000_000)
        XCTAssertEqual(summary(cwd: "/a", maxContext: 250_000).contextWindow(mode: .k200), 200_000)
        XCTAssertEqual(ContextWindowMode(rawValue: "1m"), .m1)   // persisted raw values stay stable
    }

    // MARK: - RemoteShell quoting

    func testShellQuote() {
        XCTAssertEqual(RemoteShell.shellQuote("a b"), "'a b'")
        XCTAssertEqual(RemoteShell.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testQuoteRemotePathKeepsTildeExpandable() {
        XCTAssertEqual(RemoteShell.quoteRemotePath("~"), "~")
        XCTAssertEqual(RemoteShell.quoteRemotePath("~/a b"), "~/'a b'")
        XCTAssertEqual(RemoteShell.quoteRemotePath("/abs"), "'/abs'")
        XCTAssertEqual(RemoteShell.homeRelative("~/x/y"), "x/y")
        XCTAssertEqual(RemoteShell.homeRelative("~"), ".")
    }

    func testRsyncRemoteShellQuotesIdentityPath() {
        let host = RemoteHost(displayName: "h", hostname: "example.com", port: 2222, username: "me",
                              authMethod: .privateKey, identityFile: "/keys/my key")
        let rsh = RemoteShell.rsyncRemoteShell(for: host)
        XCTAssertTrue(rsh.contains("-i '/keys/my key'"), rsh)
        XCTAssertTrue(rsh.contains("-p 2222"), rsh)
        XCTAssertTrue(rsh.contains("BatchMode=yes"), rsh)
    }

    // MARK: - RemoteShell.run

    func testRunCapturesOutputLargerThanPipeBuffer() async throws {
        // 1 MB on stdout and a bit on stderr: reading only after exit used to
        // deadlock here until the timeout killed the child.
        let start = Date()
        let out = try await RemoteShell.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero | tr '\\\\0' x; echo err >&2"],
                                            timeout: 10)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(out.stdout.utf8.count, 1_048_576)
        XCTAssertEqual(out.stderr, "err\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunReportsLaunchFailure() async {
        do {
            _ = try await RemoteShell.run("/nonexistent/binary", [])
            XCTFail("expected a launch error")
        } catch {}
    }
}
