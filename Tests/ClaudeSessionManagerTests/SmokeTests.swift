import XCTest
@testable import ClaudeSessionManager

final class SmokeTests: XCTestCase {
    func testDecodeFolder() {
        XCTAssertEqual(SessionSummary.decodeFolder("-Users-me-x"), "/Users/me/x")
    }
}
