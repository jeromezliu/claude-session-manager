import Foundation
import Network
import CryptoKit

/// Where a Mac can be reached through the relay (see `relay/src/index.ts`).
/// Both ends dial out to it, so it works where the phone can't reach the Mac
/// directly. The app's TLS runs inside, so the relay only sees ciphertext.
struct RelayEndpoint: Codable, Equatable, Hashable, Sendable {
    /// `wss://…` (or `ws://` for a local development relay).
    let url: URL
    /// base64url(SHA-256(host secret)); only the Mac knows the secret.
    let room: String

    static func room(forSecret secret: String) -> String {
        Data(SHA256.hash(data: Data(secret.utf8))).base64URLEncodedString()
    }

    var controlURL: URL { url.appendingPathComponent("v1/rooms/\(room)/host") }
    var clientURL: URL { url.appendingPathComponent("v1/rooms/\(room)/client") }
    func dataURL(_ conn: String) -> URL { url.appendingPathComponent("v1/rooms/\(room)/host/\(conn)") }

    /// A usable relay address: ws(s) with a host.
    static func parse(_ string: String) -> URL? {
        guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["wss", "ws"].contains(u.scheme?.lowercased() ?? ""), u.host?.isEmpty == false else { return nil }
        return u
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Moves bytes between a relay WebSocket (binary frames) and a local TCP
/// connection until either side ends, then closes both. Each direction waits
/// for its write to finish before reading more, so a slow side throttles the
/// other instead of buffering without bound.
final class RelaySplice: @unchecked Sendable {
    private let ws: URLSessionWebSocketTask
    private let tcp: NWConnection
    private let queue = DispatchQueue(label: "csm.relay.splice")
    private let lock = NSLock()
    private var finished = false
    private let onEnd: @Sendable () -> Void

    init(ws: URLSessionWebSocketTask, tcp: NWConnection, onEnd: @escaping @Sendable () -> Void = {}) {
        self.ws = ws
        self.tcp = tcp
        self.onEnd = onEnd
    }

    func start() {
        tcp.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        if tcp.state == .setup { tcp.start(queue: queue) }
        pumpWebSocket()
        pumpTCP()
    }

    private func pumpWebSocket() {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                self.tcp.send(content: d, completion: .contentProcessed { error in
                    if error != nil { self.finish() } else { self.pumpWebSocket() }
                })
            case .success:
                self.pumpWebSocket()          // text frames are relay chatter
            case .failure:
                self.finish()
            }
        }
    }

    private func pumpTCP() {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ws.send(.data(data)) { sendError in
                    if sendError != nil || isComplete { self.finish() } else { self.pumpTCP() }
                }
            } else if isComplete || error != nil {
                self.finish()
            } else {
                self.pumpTCP()
            }
        }
    }

    func finish() {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        ws.cancel(with: .normalClosure, reason: nil)
        tcp.cancel()
        onEnd()
    }
}
