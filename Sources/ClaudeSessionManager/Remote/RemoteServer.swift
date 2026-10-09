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
    /// Seconds a new connection has to authenticate.
    var authTimeout: TimeInterval = 10

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
        let params = NWParameters.tcp
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
                    return reject("Unknown or revoked device")
                }
                device = d
                server.connectionChanged()
                send(.welcome(protocolVersion: RemoteProtocol.version, hostName: Host.current().localizedName ?? "Mac",
                              claudeVersion: nil))
            case .pair(let code, let name):
                guard let result = server.devices.completePairing(code: code, deviceName: name) else {
                    return reject("Wrong or expired pairing code")
                }
                device = result.device
                server.connectionChanged()
                send(.paired(deviceID: result.device.id, token: result.token))
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
            mutate(mid, id) { live in live.send(text) }
        case .answer(let mid, let id, let requestID, let decision):
            guard let live = server.host.hosted(id), live.pending.contains(where: { $0.id == requestID }) else {
                return send(.ack(id: mid, ok: false, error: "That request is no longer open", sessionID: id))
            }
            live.answer(requestID, decision.decision)
            send(.ack(id: mid, ok: true, error: nil, sessionID: id))
        case .interrupt(let mid, let id):
            guard let live = server.host.hosted(id) else {
                return send(.ack(id: mid, ok: false, error: "Not running", sessionID: id))
            }
            live.interrupt()
            send(.ack(id: mid, ok: true, error: nil, sessionID: id))
        case .setPermissionMode(let mid, let id, let mode):
            guard ["default", "acceptEdits", "plan"].contains(mode) else {
                return send(.ack(id: mid, ok: false, error: "Mode \(mode) isn't allowed remotely", sessionID: id))
            }
            mutate(mid, id) { live in live.setPermissionMode(mode) }
        case .startSession(let mid, let cwd, let prompt, let mode):
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
        guard ["default", "acceptEdits", "plan"].contains(mode) else {
            return send(.ack(id: mid, ok: false, error: "Mode \(mode) isn't allowed remotely", sessionID: nil))
        }
        do {
            let live = try server.host.startNew(in: cwd, prompt: prompt, permissionMode: mode)
            // Ack once Claude announces the session id the client will use.
            var sink: AnyCancellable?
            sink = live.$sessionID.compactMap { $0 }.first().sink { [weak self] id in
                self?.send(.ack(id: mid, ok: true, error: nil, sessionID: id))
                _ = sink
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
