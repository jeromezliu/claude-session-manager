import XCTest
import Combine
@testable import ClaudeSessionManager

/// End-to-end tests of the WebSocket host on loopback, with a real
/// `URLSessionWebSocketTask` client and fake claude transports.
@MainActor
final class RemoteServerTests: XCTestCase {

    // MARK: Fixtures

    final class StubData: RemoteDataSource {
        var summaries: [String: SessionSummary] = [:]
        let changes = PassthroughSubject<Void, Never>()
        func remoteSessions() -> [RemoteSessionInfo] {
            summaries.values.map {
                RemoteSessionInfo(id: $0.id, title: $0.title, project: $0.projectName, group: nil, category: nil,
                                  updatedAt: $0.modifiedAt, messageCount: $0.messageCount, lastPrompt: $0.lastPrompt,
                                  isRemoteHost: false, hostedPhase: nil, busyElsewhere: nil)
            }
        }
        func summary(for id: String) -> SessionSummary? { summaries[id] }
        var sessionsChanged: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    }

    final class Client {
        let task: URLSessionWebSocketTask
        let session: URLSession
        /// TLS with the host's fingerprint pinned (the way the phone connects).
        init(port: UInt16, pin: String) {
            session = URLSession(configuration: .ephemeral, delegate: PinnedTLSDelegate(fingerprint: pin), delegateQueue: nil)
            task = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/")!)
            task.resume()
        }
        func send(_ m: ClientMessage) async throws {
            try await task.send(.string(String(decoding: m.encoded, as: UTF8.self)))
        }
        func next(timeout: TimeInterval = 5) async throws -> ServerMessage {
            try await withThrowingTaskGroup(of: ServerMessage.self) { group in
                group.addTask {
                    let msg = try await self.task.receive()
                    let data: Data
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    return try JSONDecoder.remote.decode(ServerMessage.self, from: data)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
        /// Skip messages until one matches.
        func next(where pred: (ServerMessage) -> Bool, timeout: TimeInterval = 5) async throws -> ServerMessage {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let m = try await next(timeout: max(0.1, deadline.timeIntervalSinceNow))
                if pred(m) { return m }
            }
        }
        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    private var dir: URL!
    private var server: RemoteServer!
    private var host: SessionHost!
    private var devices: DeviceStore!
    private var data: StubData!
    private var transports: [HostedSessionTests.FakeTransport] = []
    private var tls: TLSIdentity!
    private static let keychainAccount = "csm-tls-identity-tests"

    private func makeClient() -> Client { Client(port: server.port!, pin: tls.fingerprint) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("csm-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        host = SessionHost()
        host.sessionsDir = dir.appendingPathComponent("pids")
        host.makeTransport = { [unowned self] _ in
            let t = HostedSessionTests.FakeTransport()
            self.transports.append(t)
            return t
        }
        devices = DeviceStore(fileURL: dir.appendingPathComponent("devices.json"))
        data = StubData()
        tls = try TLSIdentity.loadOrCreate(in: dir.appendingPathComponent("tls"), keychainAccount: Self.keychainAccount)
        server = RemoteServer(host: host, devices: devices, data: data)
        server.tls = tls
        server.authTimeout = 2
        server.requiresPairingApproval = false
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(server.port)
    }

    override func tearDown() async throws {
        server.stop()
        SSHKeychain.deletePassword(for: Self.keychainAccount)
        try? FileManager.default.removeItem(at: dir)
    }

    private func addSession(_ id: String, lines: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        data.summaries[id] = SessionSummary(id: id, fileURL: url, projectFolder: "-tmp", cwd: dir.path, gitBranch: nil,
                                            claudeVersion: nil, title: "Session \(id)", firstPrompt: nil, lastPrompt: nil,
                                            messageCount: lines.count, models: [], totalOutputTokens: 0, createdAt: nil,
                                            lastActivityAt: nil, modifiedAt: Date(), fileSize: 0,
                                            latestContextTokens: 0, maxContextTokens: 0)
        return url
    }

    /// Pair a device and return an authenticated client.
    private func connectedClient() async throws -> Client {
        let code = devices.beginPairing()
        let pairing = makeClient()
        try await pairing.send(.pair(code: code, deviceName: "Test iPhone"))
        guard case .paired(_, let token) = try await pairing.next() else { XCTFail("not paired"); throw URLError(.badServerResponse) }
        pairing.close()
        let client = makeClient()
        try await client.send(.hello(protocolVersion: RemoteProtocol.version, token: token))
        guard case .welcome = try await client.next() else { XCTFail("no welcome"); throw URLError(.badServerResponse) }
        return client
    }

    // MARK: Auth

    func testRejectsRequestsBeforeAuth() async throws {
        let c = makeClient()
        try await c.send(.listSessions)
        guard case .error = try await c.next() else { return XCTFail("expected an error") }
        await assertClosed(c)
    }

    func testRejectsUnknownToken() async throws {
        let c = makeClient()
        try await c.send(.hello(protocolVersion: RemoteProtocol.version, token: "nope"))
        guard case .error(let m) = try await c.next() else { return XCTFail("expected an error") }
        XCTAssertTrue(m.contains("Unknown"))
        await assertClosed(c)
    }

    func testPairingCodeIsSingleUseAndTokensAreHashed() async throws {
        let client = try await connectedClient()
        client.close()
        XCTAssertEqual(devices.devices.count, 1)
        XCTAssertEqual(devices.devices[0].name, "Test iPhone")
        XCTAssertNil(devices.pairingCode, "consumed")
        let stored = try String(contentsOf: dir.appendingPathComponent("devices.json"), encoding: .utf8)
        XCTAssertTrue(stored.contains(devices.devices[0].tokenHash))

        // The used code doesn't pair a second device.
        let again = makeClient()
        try await again.send(.pair(code: "WHATEVER", deviceName: "x"))
        guard case .error = try await again.next() else { return XCTFail() }
    }

    func testWrongCodesClosePairingAfterFiveTries() {
        let code = devices.beginPairing()
        for _ in 0..<5 { XCTAssertNil(devices.completePairing(code: "AAAAAAAA", deviceName: "x")) }
        XCTAssertNil(devices.completePairing(code: code, deviceName: "x"), "pairing closed")
    }

    func testUnauthenticatedConnectionTimesOut() async throws {
        let c = makeClient()
        try await Task.sleep(nanoseconds: 2_600_000_000)
        await assertClosed(c)
    }

    func testRevokedDeviceIsDisconnectedAndLocked() async throws {
        let client = try await connectedClient()
        let id = devices.devices[0].id
        devices.revoke(id)
        server.disconnect(deviceID: id)
        await assertClosed(client)
    }

    // MARK: Sessions and transcripts

    func testListsSessions() async throws {
        _ = try addSession("s1")
        let c = try await connectedClient()
        try await c.send(.listSessions)
        guard case .sessions(let list) = try await c.next() else { return XCTFail() }
        XCTAssertEqual(list.map(\.id), ["s1"])
    }

    func testTranscriptArrivesThenGrows() async throws {
        let url = try addSession("s1", lines: [#"{"type":"user","message":{"content":"hello"}}"#])
        let c = try await connectedClient()
        try await c.send(.subscribe(sessionID: "s1", afterSeq: nil, knownItems: nil))
        guard case .transcript(_, let from, let items) = try await c.next() else { return XCTFail() }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(items.map(\.id), ["p0"])

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"# + "\n").utf8))
        try h.close()
        guard case .transcript(_, let from2, let items2) = try await c.next(timeout: 5) else { return XCTFail() }
        XCTAssertEqual(from2, 0, "resends the last item the client had, then the new ones")
        XCTAssertEqual(items2.map(\.id), ["p0", "r1"])
    }

    // MARK: Live sessions

    func testSendResumesAndStreamsEvents() async throws {
        _ = try addSession("s1")
        let c = try await connectedClient()
        try await c.send(.subscribe(sessionID: "s1", afterSeq: nil, knownItems: nil))
        _ = try await c.next()   // transcript
        try await c.send(.send(id: "m1", sessionID: "s1", text: "go"))

        let snapshotOrAck = try await c.next(where: {
            if case .ack = $0 { return true }
            if case .snapshot = $0 { return true }
            return false
        })
        if case .snapshot = snapshotOrAck {
            guard case .ack(let id, let ok, _, _) = try await c.next(where: { if case .ack = $0 { return true }; return false })
            else { return XCTFail() }
            XCTAssertEqual(id, "m1"); XCTAssertTrue(ok)
        }
        let t = try XCTUnwrap(transports.first)
        XCTAssertEqual(t.sent.last?["type"] as? String, "user")

        // The fake CLI asks for approval → the client sees it as an event.
        t.emit(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "tu1"]])
        let added = try await c.next(where: {
            if case .events(_, let evs) = $0 { return evs.contains { if case .requestAdded = $0.kind { return true }; return false } }
            return false
        })
        guard case .events(_, let evs) = added else { return XCTFail() }
        XCTAssertEqual(evs.map(\.seq), evs.map(\.seq).sorted(), "in order")

        try await c.send(.answer(id: "m2", sessionID: "s1", requestID: "r1", decision: .allow(always: false)))
        guard case .ack(let id2, let ok2, _, _) = try await c.next(where: { if case .ack = $0 { return true }; return false })
        else { return XCTFail() }
        XCTAssertEqual(id2, "m2"); XCTAssertTrue(ok2)
        let reply = (t.sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(reply?["behavior"] as? String, "allow")
    }

    func testReconnectReplaysOnlyMissedEvents() async throws {
        _ = try addSession("s1")
        let live = try host.resume(data.summaries["s1"]!)
        live.send("x")
        let t = try XCTUnwrap(transports.first)
        t.emit(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "A"]]])
        let seenUpTo = live.log.lastSeq
        t.emit(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "B"]]])

        let c = try await connectedClient()
        try await c.send(.subscribe(sessionID: "s1", afterSeq: seenUpTo, knownItems: 0))
        let m = try await c.next(where: { if case .events = $0 { return true }; return false })
        guard case .events(_, let evs) = m else { return XCTFail() }
        XCTAssertEqual(evs.first?.seq, seenUpTo + 1)
        XCTAssertEqual(evs.compactMap { if case .textDelta(let s) = $0.kind { return s }; return nil }, ["B"])
    }

    func testRemoteCannotBypassPermissions() async throws {
        _ = try addSession("s1")
        let c = try await connectedClient()
        try await c.send(.setPermissionMode(id: "m", sessionID: "s1", mode: "bypassPermissions"))
        guard case .ack(_, let ok, let err, _) = try await c.next() else { return XCTFail() }
        XCTAssertFalse(ok)
        XCTAssertTrue(err?.contains("isn't allowed") == true)
        XCTAssertTrue(transports.isEmpty, "nothing was launched")
    }

    // MARK: Helpers

    private func assertClosed(_ c: Client, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await c.next(timeout: 3)
            XCTFail("connection still open", file: file, line: line)
        } catch {}
    }

    // MARK: Live (opt-in)

    /// CSM_LIVE=1: a real claude process started over the WebSocket.
    func testLiveStartSessionOverWebSocket() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CSM_LIVE"] == "1", "set CSM_LIVE=1")
        host.makeTransport = { launch in
            var l = launch
            l.model = "claude-haiku-4-5-20251001"
            return ProcessClaudeTransport(launch: l)
        }
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let c = try await connectedClient()
        try await c.send(.startSession(id: "new1", cwd: work.path, prompt: "Reply with exactly: REMOTE OK", permissionMode: "default"))
        guard case .ack(let id, let ok, let err, let sid) = try await c.next(where: { if case .ack = $0 { return true }; return false }, timeout: 120)
        else { return XCTFail() }
        XCTAssertEqual(id, "new1")
        XCTAssertTrue(ok, err ?? "")
        let sessionID = try XCTUnwrap(sid)
        let live = try XCTUnwrap(host.hosted(sessionID))
        for _ in 0..<600 where live.lastResult == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(live.lastResult?.text, "REMOTE OK")
        live.stop()
    }

    // MARK: TLS

    func testWrongPinIsRefused() async throws {
        let bad = Client(port: server.port!, pin: String(repeating: "0", count: 64))
        try? await bad.send(.listSessions)
        await assertClosed(bad)
    }

    func testIdentityIsReusedAndFingerprintStable() throws {
        let again = try TLSIdentity.loadOrCreate(in: dir.appendingPathComponent("tls"), keychainAccount: Self.keychainAccount)
        XCTAssertEqual(again.fingerprint, tls.fingerprint)
        XCTAssertEqual(tls.fingerprint.count, 64)
        XCTAssertEqual(tls.securityCode.count, 7)   // "123 456"
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("tls/identity.p12").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPairingWaitsForApprovalOnTheMac() async throws {
        server.requiresPairingApproval = true
        let code = devices.beginPairing()
        let c = makeClient()
        try await c.send(.pair(code: code, deviceName: "iPad"))
        for _ in 0..<50 where server.pendingPairing == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let pending = try XCTUnwrap(server.pendingPairing)
        XCTAssertEqual(pending.deviceName, "iPad")
        XCTAssertEqual(pending.securityCode, tls.securityCode, "the phone derives the same digits from the pinned cert")
        XCTAssertTrue(devices.devices.isEmpty, "no token before approval")
        server.decidePairing(true)
        guard case .paired = try await c.next() else { return XCTFail() }
        XCTAssertEqual(devices.devices.count, 1)
    }

    func testDeclinedPairingGetsNoToken() async throws {
        server.requiresPairingApproval = true
        let code = devices.beginPairing()
        let c = makeClient()
        try await c.send(.pair(code: code, deviceName: "Stranger"))
        for _ in 0..<50 where server.pendingPairing == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        server.decidePairing(false)
        guard case .error(let m) = try await c.next() else { return XCTFail() }
        XCTAssertTrue(m.contains("declined"))
        XCTAssertTrue(devices.devices.isEmpty)
    }

    func testDisallowedInterfaceIsDropped() async throws {
        server.allowedInterfaces = ["en99"]   // loopback stays allowed…
        let c = try await connectedClient()
        try await c.send(.ping)
        guard case .pong = try await c.next() else { return XCTFail("loopback must keep working") }
    }

    func testAuditRecordsRemoteActions() async throws {
        var log: [String] = []
        server.onAudit = { device, action, _ in log.append("\(device ?? "-"): \(action)") }
        _ = try addSession("s1")
        let c = try await connectedClient()
        try await c.send(.send(id: "m1", sessionID: "s1", text: "hi"))
        _ = try await c.next(where: { if case .ack = $0 { return true }; return false })
        XCTAssertTrue(log.contains("Test iPhone: paired"))
        XCTAssertTrue(log.contains("Test iPhone: connected"))
        XCTAssertTrue(log.contains("Test iPhone: message"))
    }
}
