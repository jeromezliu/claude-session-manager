import Foundation
import Combine

/// Live state of one session as the phone sees it: the transcript (items
/// from the host's JSONL) plus, while the Mac drives it, the streamed reply,
/// pending requests and so on — kept in step by sequenced events.
@MainActor
final class SessionModel: ObservableObject, Identifiable {
    let id: String
    @Published var items: [ConversationItem] = []
    @Published var transcriptLoaded = false
    @Published var phase: SessionPhase?
    @Published var liveText = ""
    @Published var pending: [PendingRequest] = []
    @Published var queued: [String] = []
    @Published var permissionMode: String?
    @Published var lastResult: TurnResult?
    /// Last event applied — sent back on resubscribe so only missed ones come.
    var lastSeq: Int?

    init(id: String) { self.id = id }

    func apply(_ snapshot: LiveSnapshot) {
        phase = snapshot.phase
        liveText = snapshot.liveText
        pending = snapshot.pending
        queued = snapshot.queued
        permissionMode = snapshot.permissionMode
        lastSeq = snapshot.lastSeq
    }

    func apply(_ events: [HostEvent]) {
        for e in events {
            if let last = lastSeq, e.seq <= last { continue }   // already applied
            switch e.kind {
            case .phase(let p): phase = p
            case .textDelta(let t): liveText += t
            case .replyCommitted: liveText = ""
            case .requestAdded(let r): if !pending.contains(where: { $0.id == r.id }) { pending.append(r) }
            case .requestResolved(let id, _): pending.removeAll { $0.id == id }
            case .queueChanged(let q): queued = q
            case .permissionMode(let m): permissionMode = m
            case .turnFinished(let r): lastResult = r; liveText = ""
            case .rateLimit: break
            }
            lastSeq = e.seq
        }
    }

    func applyTranscript(from: Int, items new: [ConversationItem]) {
        items = Array(items.prefix(min(from, items.count))) + new
        transcriptLoaded = true
    }
}

/// One way to reach a Mac: straight to an address, or through its relay.
enum Route: Equatable {
    case direct(String, port: Int)
    case relay(RelayEndpoint)

    static func all(addresses: [String], port: Int, relay: RelayEndpoint?) -> [Route] {
        addresses.map { .direct($0, port: port) } + (relay.map { [.relay($0)] } ?? [])
    }

    var label: String {
        switch self {
        case .direct(let a, _): return a
        case .relay(let e): return "Relay (\(e.url.host ?? "?"))"
        }
    }

    /// The WebSocket URL; for the relay, the local bridge in front of it.
    func url() async throws -> URL {
        let (host, port): (String, Int)
        switch self {
        case .direct(let a, let p): (host, port) = (a, p)
        case .relay(let e): (host, port) = ("127.0.0.1", Int(try await RelayBridge.shared(for: e).port()))
        }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "wss://\(bracketed):\(port)/") else { throw URLError(.badURL) }
        return url
    }
}

/// The phone's connection to one Mac: TLS-pinned WebSocket, auth, the
/// session list, subscriptions and mutations (each acked by the host).
/// Reconnects with backoff and resumes subscriptions from the last event.
@MainActor
final class RemoteClient: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sessions: [RemoteSessionInfo] = []
    @Published private(set) var hostName: String?
    /// How the current connection reaches the Mac (an address, or the relay).
    @Published private(set) var routeLabel: String?

    struct AckError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private var host: PairedHost?
    private var token: String?
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var models: [String: SessionModel] = [:]
    private var subscribed: Set<String> = []
    private var acks: [String: CheckedContinuation<(ok: Bool, error: String?, sessionID: String?), Never>] = [:]
    private var reconnectDelay: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var generation = 0
    /// Route that last worked; tried first next time.
    private var preferredRoute = 0
    private var attemptRoute: Route?

    func model(_ id: String) -> SessionModel {
        if let m = models[id] { return m }
        let m = SessionModel(id: id)
        models[id] = m
        return m
    }

    // MARK: Connection

    func connect(to host: PairedHost, token: String) {
        self.host = host
        self.token = token
        reconnectDelay = 1
        open()
    }

    func disconnect() {
        reconnectTask?.cancel()
        heartbeat?.cancel()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    /// Back in the foreground: don't wait for the backoff timer.
    func reconnectNow() {
        // Already connected, or an attempt is in flight (not just waiting out a backoff).
        guard host != nil, state != .connected, state != .connecting || reconnectTask != nil else { return }
        reconnectDelay = 1
        open()
    }

    private var routes: [Route] {
        guard let host else { return [] }
        return Route.all(addresses: host.addresses, port: host.port, relay: host.relay)
    }

    /// Try route `attempt` (counting from the preferred one); on failure
    /// `connectionLost` moves on to the next before backing off.
    private func open(attempt: Int = 0) {
        guard let host, let token else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeat?.cancel()
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .connecting
        let list = routes
        guard !list.isEmpty else { return }
        let route = list[(preferredRoute + attempt) % list.count]
        attemptRoute = route

        Task { @MainActor in
            let url: URL
            do { url = try await route.url() } catch {
                guard gen == self.generation else { return }
                return self.connectionLost(error, attempt: attempt)
            }
            guard gen == self.generation else { return }
            let session = URLSession(configuration: .ephemeral, delegate: PinnedTLSDelegate(fingerprint: host.fingerprint),
                                     delegateQueue: nil)
            self.urlSession = session
            var request = URLRequest(url: url)
            // A LAN address that isn't there should fail fast when a relay can take over.
            if case .direct = route, list.count > 1 { request.timeoutInterval = 4 } else { request.timeoutInterval = 10 }
            let t = session.webSocketTask(with: request)
            t.maximumMessageSize = Self.maxMessageSize
            self.task = t
            t.resume()
            self.receive(t, gen: gen, attempt: attempt)
            Task { try? await t.send(.string(Self.encode(.hello(protocolVersion: RemoteProtocol.version, token: token)))) }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int, attempt: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if case .string(let s) = message,
                       let m = try? JSONDecoder.remote.decode(ServerMessage.self, from: Data(s.utf8)) {
                        self.handle(m, attempt: attempt)
                    }
                    self.receive(t, gen: gen, attempt: attempt)
                case .failure(let error):
                    self.connectionLost(error, attempt: attempt)
                }
            }
        }
    }

    private func connectionLost(_ error: Error, attempt: Int) {
        heartbeat?.cancel()
        for (_, c) in acks { c.resume(returning: (false, "Connection lost", nil)) }
        acks = [:]
        if case .failed = state { return }   // the host refused us: don't hammer it
        guard host != nil else { return }
        routeLabel = nil
        // Try the next route right away before backing off.
        if state == .connecting, attempt + 1 < routes.count {
            return open(attempt: attempt + 1)
        }
        state = .connecting
        let delay = reconnectDelay
        reconnectDelay = min(15, reconnectDelay * 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    private func handle(_ message: ServerMessage, attempt: Int) {
        switch message {
        case .welcome(_, let name, _):
            hostName = name
            let count = max(routes.count, 1)
            preferredRoute = (preferredRoute + attempt) % count
            routeLabel = attemptRoute?.label
            state = .connected
            reconnectDelay = 1
            send(.listSessions)
            for id in subscribed { resubscribe(id) }
            startHeartbeat()
        case .paired:
            break   // only on pairing connections (see Pairing)
        case .sessions(let list):
            sessions = list.sorted { $0.updatedAt > $1.updatedAt }
        case .snapshot(let id, let snap):
            model(id).apply(snap)
        case .events(let id, let events):
            model(id).apply(events)
        case .transcript(let id, let from, let items):
            model(id).applyTranscript(from: from, items: items)
        case .ack(let id, let ok, let error, let sid):
            acks.removeValue(forKey: id)?.resume(returning: (ok, error, sid))
        case .error(let text):
            if state != .connected { state = .failed(text) }
        case .pong:
            break
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.send(.ping)
            }
        }
    }

    // MARK: Requests

    func refreshSessions() { send(.listSessions) }

    func subscribe(_ id: String) {
        subscribed.insert(id)
        resubscribe(id)
    }

    func unsubscribe(_ id: String) {
        subscribed.remove(id)
        send(.unsubscribe(sessionID: id))
    }

    private func resubscribe(_ id: String) {
        let m = model(id)
        send(.subscribe(sessionID: id, afterSeq: m.lastSeq, knownItems: m.items.count))
    }

    func sendMessage(_ text: String, to id: String) async throws {
        try await mutate { .send(id: $0, sessionID: id, text: text) }
    }

    func answer(_ request: PendingRequest, in id: String, with decision: RemoteDecision) async throws {
        try await mutate { .answer(id: $0, sessionID: id, requestID: request.id, decision: decision) }
    }

    func interrupt(_ id: String) async throws {
        try await mutate { .interrupt(id: $0, sessionID: id) }
    }

    func setPermissionMode(_ mode: String, for id: String) async throws {
        try await mutate { .setPermissionMode(id: $0, sessionID: id, mode: mode) }
    }

    /// Start a new session; returns its id once Claude announced it.
    func startSession(in cwd: String, prompt: String, mode: String) async throws -> String? {
        try await mutate { .startSession(id: $0, cwd: cwd, prompt: prompt, permissionMode: mode) }
    }

    @discardableResult
    private func mutate(_ make: (String) -> ClientMessage) async throws -> String? {
        guard state == .connected else { throw AckError(message: "Not connected to the Mac") }
        let mid = UUID().uuidString
        let message = make(mid)
        let result = await withCheckedContinuation { c in
            acks[mid] = c
            send(message)
        }
        guard result.ok else { throw AckError(message: result.error ?? "The Mac refused the request") }
        return result.sessionID
    }

    private func send(_ m: ClientMessage) {
        guard let task else { return }
        let text = Self.encode(m)
        Task { try? await task.send(.string(text)) }
    }

    /// Transcripts of long sessions run to several MB (the default is 1 MB).
    nonisolated static let maxMessageSize = 64 << 20

    nonisolated static func encode(_ m: ClientMessage) -> String {
        String(decoding: (try? JSONEncoder.remote.encode(m)) ?? Data(), as: UTF8.self)
    }
}

/// One-off pairing connection: present the code, wait for the Mac user's
/// approval, receive the device token.
enum Pairing {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func pair(_ link: PairingLink, deviceName: String) async throws -> (PairedHost, token: String) {
        var lastError = "Couldn't reach the Mac"
        let routes = Route.all(addresses: link.addresses, port: link.port, relay: link.relay)
        for route in routes {
            let session = URLSession(configuration: .ephemeral, delegate: PinnedTLSDelegate(fingerprint: link.fingerprint),
                                     delegateQueue: nil)
            guard let url = try? await route.url() else { continue }
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = RemoteClient.maxMessageSize
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }
            do {
                // Give an absent LAN address a few seconds, then move on to the relay.
                let message = RemoteClient.encode(.pair(code: link.code, deviceName: deviceName))
                if case .direct = route, routes.count > 1 {
                    try await withTimeout(5, orThrow: URLError(.timedOut)) { try await task.send(.string(message)) }
                } else {
                    try await task.send(.string(message))
                }
                // The Mac user has up to two minutes to approve.
                let reply = try await withTimeout(130) { try await task.receive() }
                guard case .string(let s) = reply,
                      let m = try? JSONDecoder.remote.decode(ServerMessage.self, from: Data(s.utf8)) else {
                    throw Failure(message: "Unexpected reply from the Mac")
                }
                switch m {
                case .paired(let deviceID, let token):
                    let host = PairedHost(deviceID: deviceID, name: "Mac", addresses: link.addresses,
                                          port: link.port, fingerprint: link.fingerprint, relay: link.relay)
                    return (host, token)
                case .error(let text):
                    throw Failure(message: text)
                default:
                    throw Failure(message: "Unexpected reply from the Mac")
                }
            } catch let f as Failure {
                throw f   // the Mac answered: don't try other addresses
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw Failure(message: lastError)
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        orThrow timeoutError: Error = Failure(message: "No answer from the Mac — was the pairing approved there?"),
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw timeoutError
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
