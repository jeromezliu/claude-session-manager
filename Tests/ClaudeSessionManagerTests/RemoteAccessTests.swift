import XCTest
import Network
@testable import ClaudeSessionManager

final class RemoteAccessTests: XCTestCase {
    func testInterfacesSkipLoopbackAndNoise() {
        let list = NetworkInterface.current()
        for i in list {
            XCTAssertFalse(i.name.hasPrefix("lo"))
            XCTAssertFalse(i.name.hasPrefix("awdl"))
            XCTAssertFalse(i.addresses.isEmpty)
            print("IFACE \(i.name) \(i.kind) \(i.addresses)")
        }
    }

    func testQRCodeRenders() {
        let img = QRCode.image("csm://pair?v=1&hosts=10.0.0.2&port=8473&fp=ab&code=ABCD2345")
        XCTAssertNotNil(img)
        XCTAssertGreaterThan(img?.size.width ?? 0, 100)
    }

    func testAuditLogAppendsAndReadsNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csm-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.append(device: "iPhone", action: "connected", detail: "")
        log.append(device: "iPhone", action: "message", detail: "s1 · 5 chars")
        XCTAssertEqual(log.recent(10).map(\.action), ["message", "connected"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testSecurityCodeDependsOnTheCertificate() {
        let a = TLSIdentity.securityCode(forFingerprint: String(repeating: "a", count: 64))
        let b = TLSIdentity.securityCode(forFingerprint: String(repeating: "b", count: 64))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, TLSIdentity.securityCode(forFingerprint: String(repeating: "A", count: 64)), "case-insensitive")
        XCTAssertTrue(a.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression) != nil)
    }

    func testOnlyPrivateAddressesArePrivate() {
        func v4(_ s: String) -> Bool { RemoteConnection.isPrivate(.ipv4(IPv4Address(s)!)) }
        func v6(_ s: String) -> Bool { RemoteConnection.isPrivate(.ipv6(IPv6Address(s)!)) }
        XCTAssertTrue(v4("127.0.0.1")); XCTAssertTrue(v4("10.8.198.27")); XCTAssertTrue(v4("192.168.8.252"))
        XCTAssertTrue(v4("172.20.1.1")); XCTAssertTrue(v4("100.101.1.2")); XCTAssertTrue(v4("169.254.3.4"))
        XCTAssertFalse(v4("8.8.8.8")); XCTAssertFalse(v4("172.32.0.1")); XCTAssertFalse(v4("100.128.0.1"))
        XCTAssertTrue(v6("::1")); XCTAssertTrue(v6("fe80::1")); XCTAssertTrue(v6("fd12:3456::1"))
        XCTAssertTrue(v6("::ffff:192.168.1.5"))
        XCTAssertFalse(v6("2408:823c:2011:3d24:490:5d0a:cc99:4d8b"), "global IPv6 on Wi-Fi must not get in")
    }
}
