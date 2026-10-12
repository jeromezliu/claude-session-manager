import Foundation
import Network

/// Phone side of the relay: a loopback-only port that, for each connection,
/// dials the Mac's room on the relay and splices the two once the Mac has
/// answered. The app then talks to `wss://127.0.0.1:<port>` exactly as if
/// the Mac were on the LAN — same TLS pinning, same token.
final class RelayBridge: @unchecked Sendable {
    let endpoint: RelayEndpoint

    private let queue = DispatchQueue(label: "csm.relay.bridge")
    private let session: URLSession
    private let lock = NSLock()
    private var listener: NWListener?
    private var splices: [UUID: RelaySplice] = [:]

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [RelayEndpoint: RelayBridge] = [:]

    /// One bridge per Mac, shared by pairing and the live connection.
    static func shared(for endpoint: RelayEndpoint) -> RelayBridge {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let b = registry[endpoint] { return b }
        let b = RelayBridge(endpoint: endpoint)
        registry[endpoint] = b
        return b
    }

    private init(endpoint: RelayEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The local port, (re)starting the listener if needed — iOS may have
    /// torn it down while the app was suspended.
    func port() async throws -> UInt16 {
        let existing: NWListener? = lock.withLock {
            if let l = listener, case .ready = l.state { return l }
            listener?.cancel()
            listener = nil
            return nil
        }
        if let p = existing?.port?.rawValue { return p }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // never reachable from the LAN
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        lock.withLock { listener = l }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    c.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    c.resume(throwing: e)
                case .cancelled:
                    resumed = true
                    c.resume(throwing: Failure(message: "Relay bridge stopped"))
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let ws = session.webSocketTask(with: endpoint.clientURL)
        ws.maximumMessageSize = 16 << 20
        ws.resume()
        // Nothing may be sent until the Mac has dialed in ("ready"); a Mac
        // that never answers shouldn't leave the app hanging.
        let state = PendingState()
        queue.asyncAfter(deadline: .now() + 10) {
            if state.claim() { ws.cancel(with: .goingAway, reason: nil); conn.cancel() }
        }
        ws.receive { [weak self] result in
            guard state.claim() else { return }
            guard let self, case .success(.string("ready")) = result else {
                ws.cancel(with: .goingAway, reason: nil)
                conn.cancel()
                return
            }
            let id = UUID()
            let splice = RelaySplice(ws: ws, tcp: conn) { [weak self] in
                self?.lock.withLock { _ = self?.splices.removeValue(forKey: id) }
            }
            self.lock.withLock { self.splices[id] = splice }
            splice.start()
        }
    }

    /// First of "ready" or the timeout wins.
    private final class PendingState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}
