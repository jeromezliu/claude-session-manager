import Foundation
import Network

/// Keeps this Mac reachable through a relay. A control socket waits for
/// phones; for each one the relay announces, a data socket is opened and
/// spliced to the local TLS server, which then handles it like any other
/// client (pairing, tokens and pinning are unchanged). All outbound HTTPS,
/// so it works behind NAT and proxies.
@MainActor
final class RelayLink: ObservableObject {
    enum State: Equatable {
        case connecting, online
        case failed(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var connections = 0

    let endpoint: RelayEndpoint
    private let secret: String
    private let localPort: UInt16
    private let session: URLSession
    private var control: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var delay: TimeInterval = 1
    private var generation = 0
    private var splices: [UUID: RelaySplice] = [:]
    private var stopped = false

    init(endpoint: RelayEndpoint, secret: String, localPort: UInt16) {
        self.endpoint = endpoint
        self.secret = secret
        self.localPort = localPort
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func start() {
        stopped = false
        openControl()
    }

    func stop() {
        stopped = true
        generation += 1
        retry?.cancel()
        keepAlive?.cancel()
        control?.cancel(with: .goingAway, reason: nil)
        control = nil
        splices.values.forEach { $0.finish() }
        splices = [:]
        connections = 0
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func openControl() {
        generation += 1
        let gen = generation
        keepAlive?.cancel()
        control?.cancel(with: .goingAway, reason: nil)
        if state != .online { state = .connecting }
        let t = session.webSocketTask(with: request(endpoint.controlURL))
        control = t
        t.resume()
        receive(t, gen: gen)
        // The relay answers "ping" itself; the first "pong" says we're on.
        // Repeating it keeps idle-timeout proxies from dropping the socket.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await t.send(.string("ping"))
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard self != nil else { return }
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(.string(let s)):
                    self.handle(s)
                    self.receive(t, gen: gen)
                case .success:
                    self.receive(t, gen: gen)
                case .failure(let error):
                    self.controlLost(t, error)
                }
            }
        }
    }

    private func handle(_ message: String) {
        if message == "pong" {
            state = .online
            delay = 1
            return
        }
        struct Open: Decodable { let t: String; let c: String }
        guard let open = try? JSONDecoder().decode(Open.self, from: Data(message.utf8)), open.t == "open",
              open.c.count == 32, open.c.allSatisfy(\.isHexDigit) else { return }
        accept(open.c)
    }

    /// A phone is waiting: dial its data socket and splice it to the local server.
    private func accept(_ conn: String) {
        let ws = session.webSocketTask(with: request(endpoint.dataURL(conn)))
        ws.maximumMessageSize = 16 << 20
        let tcp = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!, using: .tcp)
        let id = UUID()
        let splice = RelaySplice(ws: ws, tcp: tcp) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.splices.removeValue(forKey: id)
                self.connections = self.splices.count
            }
        }
        splices[id] = splice
        connections = splices.count
        ws.resume()
        splice.start()
    }

    private func controlLost(_ t: URLSessionWebSocketTask, _ error: Error) {
        keepAlive?.cancel()
        guard !stopped else { return }
        let status = (t.response as? HTTPURLResponse)?.statusCode
        state = status == 403 ? .failed("The relay refused this Mac's key")
            : .failed(error.localizedDescription)
        let wait = delay
        delay = min(30, delay * 2)
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.openControl()
        }
    }
}
