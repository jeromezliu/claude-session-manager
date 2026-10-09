import Foundation
import Network
import Combine

/// What the server needs from the app: the session list and summaries.
@MainActor
protocol RemoteDataSource: AnyObject {
    func remoteSessions() -> [RemoteSessionInfo]
    func summary(for sessionID: String) -> SessionSummary?
    /// Fires when the list may have changed (debounced by the server).
    var sessionsChanged: AnyPublisher<Void, Never> { get }
    /// Rescan so `sessionID`, just started remotely, is listed (even in a
    /// temp folder).
    func refresh(adding sessionID: String) async
}

extension RemoteDataSource {
    func refresh(adding sessionID: String) async {}
}

/// WebSocket server for remote clients. Listens on loopback only unless
/// `exposeOnNetwork` is set (which P1.4 gates behind TLS + pairing).
@MainActor
final class RemoteServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    /// Names of devices connected right now.
    @Published private(set) var connectedDevices: [String] = []
    @Published private(set) var lastError: String?

    let host: SessionHost
    let devices: DeviceStore
    /// Held strongly: the data source only reads app state, it doesn't point back here.
    var data: RemoteDataSource?
    var exposeOnNetwork = false
    /// TLS identity; required when exposed on the network.
    var tls: TLSIdentity?
    /// Seconds a new connection has to authenticate.
    var authTimeout: TimeInterval = 10
    /// Interfaces remote connections may arrive on (BSD names, e.g. "en0",
    /// "utun3"); nil = any. Loopback is always allowed.
    var allowedInterfaces: Set<String>?
    /// Ask on the Mac before a redeemed code turns into a device token.
    var requiresPairingApproval = true
    /// A device waiting for approval on the Mac (name, security code).
    @Published private(set) var pendingPairing: PendingPairing?
    /// Remote activity, for the audit log.
    var onAudit: ((_ device: String?, _ action: String, _ detail: String) -> Void)?

    struct PendingPairing: Identifiable, Equatable {
        let id = UUID()
        let deviceName: String
        /// From the host certificate — the phone shows the same digits.
        let securityCode: String
    }
    private var pairingDecision: ((Bool) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]

    init(host: SessionHost, devices: DeviceStore, data: RemoteDataSource?) {
        self.host = host
        self.devices = devices
        self.data = data
    }

    /// Start listening; `port` 0 picks a free one (tests).
    func start(port: UInt16 = 8473) throws {
        guard listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 * 1024 * 1024
        guard tls != nil || !exposeOnNetwork else {
            throw NSError(domain: "ClaudeSessionManager", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Network access needs TLS."])
        }
        let params: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(tls.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters.tcp
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        if !exposeOnNetwork {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        let listener = exposeOnNetwork
            ? try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            : try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] nw in
            Task { @MainActor in self?.accept(nw) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerState(state) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections = [:]
        isRunning = false
        port = nil
        connectedDevices = []
    }

    /// The Mac user's answer to `pendingPairing`.
    func decidePairing(_ approve: Bool) {
        let decide = pairingDecision
        pairingDecision = nil
        pendingPairing = nil
        decide?(approve)
    }

    /// Hold a redeemed pairing until the Mac user approves (2 min timeout).
    func requestPairingApproval(deviceName: String, _ completion: @escaping (Bool) -> Void) {
        guard requiresPairingApproval else { return completion(true) }
        decidePairing(false)   // one at a time
        let pending = PendingPairing(deviceName: deviceName, securityCode: tls?.securityCode ?? "—")
        pendingPairing = pending
        pairingDecision = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if self?.pendingPairing?.id == pending.id { self?.decidePairing(false) }
        }
    }

    func audit(_ device: String?, _ action: String, _ detail: String = "") {
        onAudit?(device, action, detail)
    }

    /// Drop every connection of a revoked device.
    func disconnect(deviceID: String) {
        connections.values.filter { $0.device?.id == deviceID }.forEach { $0.close() }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            port = listener?.port?.rawValue
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = RemoteConnection(nw: nw, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    func connectionChanged() {
        connectedDevices = connections.values.compactMap { $0.device?.name }.sorted()
    }

    func remove(_ connection: RemoteConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connectionChanged()
    }
}

/// One client connection: auth, request handling and subscriptions.
@MainActor
final class RemoteConnection {
    private let nw: NWConnection
    private weak var server: RemoteServer?
    private(set) var device: PairedDevice?
    private var subscriptions: [String: Subscription] = [:]
    private var listSubscription: AnyCancellable?
    private var closed = false

    init(nw: NWConnection, server: RemoteServer) {
        self.nw = nw
        self.server = server
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.checkInterface()
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        nw.start(queue: .main)
        receive()
        let timeout = server?.authTimeout ?? 10
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let self, self.device == nil { self.close() }
        }
    }

    /// Only accept connections from private addresses (a LAN or VPN —
    /// never the internet, e.g. via a global IPv6 address on Wi-Fi), arriving
    /// on an allowed interface.
    private func checkInterface() {
        guard let server else { return }
        if case .hostPort(let host, _) = nw.endpoint, !Self.isPrivate(host) {
            server.audit(nil, "rejected", "connection from public address \(host)")
            return close()
        }
        guard let allowed = server.allowedInterfaces else { return }
        let name = nw.currentPath?.availableInterfaces.first?.name ?? ""
        if name.hasPrefix("lo") || allowed.contains(name) { return }
        server.audit(nil, "rejected", "connection on interface \(name.isEmpty ? "?" : name)")
        close()
    }

    /// Loopback, RFC 1918, CGNAT (100.64/10, used by Tailscale), link-local,
    /// and IPv6 unique-local (fc00::/7) addresses.
    nonisolated static func isPrivate(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
                || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            if a.isLoopback || a.isLinkLocal { return true }
            if let v4 = a.asIPv4 { return isPrivate(.ipv4(v4)) }
            let b = [UInt8](a.rawValue)
            return b.first.map { $0 & 0xFE == 0xFC } ?? false
        default:
            return false   // names shouldn't appear for an accepted connection
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        subscriptions.values.forEach { $0.cancel() }
        subscriptions = [:]
        listSubscription = nil
        nw.cancel()
        server?.remove(self)
    }

    // MARK: I/O

    private func receive() {
        nw.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.handle(data) }
                if error == nil { self.receive() } else { self.close() }
            }
        }
    }

    func send(_ message: ServerMessage, then after: (() -> Void)? = nil) {
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        nw.send(content: message.encoded, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in
                    if let after { Task { @MainActor in after() } }
                })
    }

    /// Tell the client why, then hang up once that's on the wire.
    private func reject(_ reason: String) {
        send(.error(reason)) { [weak self] in self?.close() }
    }

    // MARK: Requests

    private func handle(_ data: Data) {
        guard let message = try? JSONDecoder.remote.decode(ClientMessage.self, from: data) else {
            send(.error("Unreadable message"))
            return
        }
        guard let server else { return }

        // Before auth, only hello / pair.
        if device == nil {
            switch message {
            case .hello(let version, let token):
                guard version == RemoteProtocol.version else {
                    return reject("Protocol \(version) not supported (host speaks \(RemoteProtocol.version))")
                }
                guard let d = server.devices.authenticate(token: token) else {
                    server.audit(nil, "rejected", "unknown or revoked token")
                    return reject("Unknown or revoked device")
                }
                device = d
                server.connectionChanged()
                server.audit(d.name, "connected")
                send(.welcome(protocolVersion: RemoteProtocol.version, hostName: Host.current().localizedName ?? "Mac",
                              claudeVersion: nil))
            case .pair(let code, let name):
                guard server.devices.redeem(code: code) else {
                    server.audit(name, "pairing rejected", "wrong or expired code")
                    return reject("Wrong or expired pairing code")
                }
                server.requestPairingApproval(deviceName: name) { [weak self] approved in
                    guard let self, let server = self.server, !self.closed else { return }
                    guard approved else {
                        server.audit(name, "pairing denied on the Mac")
                        return self.reject("Pairing was declined on the Mac")
                    }
                    let result = server.devices.addDevice(named: name)
                    self.device = result.device
                    server.connectionChanged()
                    server.audit(result.device.name, "paired")
                    self.send(.paired(deviceID: result.device.id, token: result.token))
                }
            default:
                reject("Authenticate first")
            }
            return
        }

        switch message {
        case .hello, .pair:
            send(.error("Already authenticated"))
        case .ping:
            send(.pong)
        case .listSessions:
            sendSessions()
            if listSubscription == nil, let changes = server.data?.sessionsChanged {
                listSubscription = changes.debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
                    .sink { [weak self] in self?.sendSessions() }
            }
        case .subscribe(let id, let afterSeq, let knownItems):
            guard let summary = server.data?.summary(for: id) else {
                return send(.error("No session \(id)"))
            }
            subscriptions[id]?.cancel()
            let sub = Subscription(summary: summary, connection: self)
            subscriptions[id] = sub
            sub.startTranscript(knownItems: knownItems ?? 0)
            if let live = server.host.hosted(id) { sub.attach(live, afterSeq: afterSeq) }
        case .unsubscribe(let id):
            subscriptions.removeValue(forKey: id)?.cancel()
        case .send(let mid, let id, let text):
            server.audit(device?.name, "message", "\(id) · \(text.count) chars")
            mutate(mid, id) { live in live.send(text) }
        case .answer(let mid, let id, let requestID, let decision):
            guard let live = server.host.hosted(id), live.pending.contains(where: { $0.id == requestID }) else {
                return send(.ack(id: mid, ok: false, error: "That request is no longer open", sessionID: id))
            }
            let tool = live.pending.first { $0.id == requestID }?.ask.toolName ?? "?"
            live.answer(requestID, decision.decision)
            server.audit(device?.name, "answered", "\(id) · \(tool) · \(decision.auditLabel)")
            send(.ack(id: mid, ok: true, error: nil, sessionID: id))
        case .interrupt(let mid, let id):
            guard let live = server.host.hosted(id) else {
                return send(.ack(id: mid, ok: false, error: "Not running", sessionID: id))
            }
            live.interrupt()
            server.audit(device?.name, "interrupted", id)
            send(.ack(id: mid, ok: true, error: nil, sessionID: id))
        case .setPermissionMode(let mid, let id, let mode):
            guard PermissionModes.allowedRemotely.contains(mode) else {
                return send(.ack(id: mid, ok: false, error: "Mode \(mode) isn't allowed remotely", sessionID: id))
            }
            server.audit(device?.name, "permission mode", "\(id) · \(mode)")
            mutate(mid, id) { live in live.setPermissionMode(mode) }
        case .startSession(let mid, let cwd, let prompt, let mode):
            server.audit(device?.name, "new session", "\(cwd) · \(mode)")
            startSession(mid, cwd: cwd, prompt: prompt, mode: mode)
        }
    }

    /// Run `body` on the hosted session, resuming it first if needed.
    private func mutate(_ mid: String, _ id: String, _ body: (HostedSession) -> Void) {
        guard let server, let summary = server.data?.summary(for: id) else {
            return send(.ack(id: mid, ok: false, error: "No session \(id)", sessionID: id))
        }
        do {
            let wasHosted = server.host.hosted(id) != nil
            let live = try server.host.resume(summary)
            if !wasHosted { subscriptions[id]?.attach(live, afterSeq: nil) }
            body(live)
            send(.ack(id: mid, ok: true, error: nil, sessionID: id))
        } catch {
            send(.ack(id: mid, ok: false, error: error.localizedDescription, sessionID: id))
        }
    }

    private func startSession(_ mid: String, cwd: String, prompt: String, mode: String) {
        guard let server else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return send(.ack(id: mid, ok: false, error: "No such folder: \(cwd)", sessionID: nil))
        }
        guard PermissionModes.allowedRemotely.contains(mode) else {
            return send(.ack(id: mid, ok: false, error: "Mode \(mode) isn't allowed remotely", sessionID: nil))
        }
        do {
            let live = try server.host.startNew(in: cwd, prompt: prompt, permissionMode: mode)
            // Ack once Claude announces the session id the client will use.
            var sink: AnyCancellable?
            sink = live.$sessionID.compactMap { $0 }.first().sink { [weak self] id in
                _ = sink
                // The client subscribes right after the ack, so the session
                // must be listed by then (its JSONL appears with the first turn).
                Task { @MainActor [weak self] in
                    for _ in 0..<10 {
                        guard let data = self?.server?.data, data.summary(for: id) == nil else { break }
                        await data.refresh(adding: id)
                        if data.summary(for: id) == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    }
                    self?.send(.ack(id: mid, ok: true, error: nil, sessionID: id))
                }
            }
        } catch {
            send(.ack(id: mid, ok: false, error: error.localizedDescription, sessionID: nil))
        }
    }

    private func sendSessions() {
        send(.sessions(server?.data?.remoteSessions() ?? []))
    }
}

/// One subscribed session: its transcript (parsed from the JSONL, the
/// source of truth) and, if hosted, its live event stream.
@MainActor
final class Subscription {
    let summary: SessionSummary
    private weak var connection: RemoteConnection?
    private var events: [TranscriptEvent] = []
    private var cursor = SessionParser.TranscriptCursor()
    private var sentItems = 0
    private var sentOnce = false
    private var watcher: FileWatcher?
    private var parsing = false, reparse = false
    private var logSink: AnyCancellable?
    private var lastSentSeq = 0

    init(summary: SessionSummary, connection: RemoteConnection) {
        self.summary = summary
        self.connection = connection
    }

    func cancel() {
        watcher = nil
        logSink = nil
    }

    // MARK: Transcript

    func startTranscript(knownItems: Int) {
        sentItems = knownItems
        parse()
        watcher = FileWatcher(url: summary.fileURL) { [weak self] in self?.parse() }
    }

    private func parse() {
        guard !parsing else { reparse = true; return }
        parsing = true
        let url = summary.fileURL, from = cursor, previous = events
        Task.detached(priority: .userInitiated) {
            let r = SessionParser.transcriptEvents(for: url, from: from)
            let all = previous + (r?.events ?? [])
            let items = ConversationBuilder.items(from: all)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.parsing = false
                if let r { self.events = all; self.cursor = r.cursor }
                self.deliver(items)
                if self.reparse { self.reparse = false; self.parse() }
            }
        }
    }

    /// Resend from the last item the client has (it may have grown); from
    /// scratch if the file shrank. Always answers the first time, even empty.
    private func deliver(_ items: [ConversationItem]) {
        let from = items.count < sentItems ? 0 : max(0, sentItems - 1)
        guard !sentOnce || from < items.count || items.count < sentItems else { return }
        connection?.send(.transcript(sessionID: summary.id, from: from, items: Array(items[from...])))
        sentItems = items.count
        sentOnce = true
    }

    // MARK: Live events

    func attach(_ live: HostedSession, afterSeq: Int?) {
        if let afterSeq, let missed = live.log.events(after: afterSeq) {
            if !missed.isEmpty { connection?.send(.events(sessionID: summary.id, missed)) }
            lastSentSeq = max(afterSeq, missed.last?.seq ?? afterSeq)
        } else {
            sendSnapshot(live)
        }
        logSink = live.$log.sink { [weak self, weak live] _ in
            // `$log` publishes before the property changes; read on the next turn.
            DispatchQueue.main.async { if let live { self?.flush(live) } }
        }
    }

    private func flush(_ live: HostedSession) {
        guard let new = live.log.events(after: lastSentSeq) else {
            return sendSnapshot(live)   // fell behind the log's window
        }
        guard !new.isEmpty else { return }
        connection?.send(.events(sessionID: summary.id, new))
        lastSentSeq = new.last!.seq
    }

    private func sendSnapshot(_ live: HostedSession) {
        connection?.send(.snapshot(sessionID: summary.id, LiveSnapshot(
            phase: live.phase, liveText: live.liveText, pending: live.pending, queued: live.queued,
            permissionMode: live.permissionMode, lastSeq: live.log.lastSeq)))
        lastSentSeq = live.log.lastSeq
    }
}
