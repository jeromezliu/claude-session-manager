import Foundation

/// The WebSocket protocol between the Mac host and remote clients (the
/// phone app). JSON text frames, one message each. Foundation-only so the
/// iOS app can share it verbatim.
///
/// Auth is the first frame: `hello` with a device token, or `pair` with the
/// one-time code shown on the Mac. Nothing else is accepted before it, and a
/// connection that doesn't authenticate within a few seconds is closed. The
/// token never goes into a URL.
enum RemoteProtocol {
    static let version = 1
}

/// A session as listed on the phone.
struct RemoteSessionInfo: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var project: String
    var group: String?
    var category: String?
    var updatedAt: Date
    var messageCount: Int
    var lastPrompt: String?
    var isRemoteHost: Bool
    /// The app is driving it; `phase` says what it's doing.
    var hostedPhase: HostedSession.Phase?
    /// Open in a terminal / Claude Desktop — read-only for remote clients.
    var busyElsewhere: String?
}

/// Live state of a hosted session, sent when a client can't be caught up
/// from the event log (first subscribe, or its `afterSeq` was trimmed).
struct LiveSnapshot: Codable, Equatable, Sendable {
    var phase: HostedSession.Phase
    var liveText: String
    var pending: [PendingRequest]
    var queued: [String]
    var permissionMode: String
    var lastSeq: Int
}

/// How a remote client answers a pending request (wire form of `RequestDecision`).
enum RemoteDecision: Codable, Equatable, Sendable {
    case allow(always: Bool)
    case deny(message: String)
    case answer([String: String])
    case approvePlan

    var auditLabel: String {
        switch self {
        case .allow(let always): return always ? "always allow" : "allow"
        case .deny: return "deny"
        case .answer: return "answer"
        case .approvePlan: return "approve plan"
        }
    }

    var decision: RequestDecision {
        switch self {
        case .allow(let always): return .allow(always: always)
        case .deny(let m): return .deny(message: m)
        case .answer(let a): return .answer(a)
        case .approvePlan: return .approvePlan
        }
    }
}

/// Client → host.
enum ClientMessage: Codable, Equatable, Sendable {
    /// First message on a connection from a paired device.
    case hello(protocolVersion: Int, token: String)
    /// First message from a new device: the code shown on the Mac.
    case pair(code: String, deviceName: String)
    case listSessions
    /// Follow a session: transcript items, plus live events if it's hosted.
    /// `afterSeq` resumes the event stream; `afterItem` the transcript.
    case subscribe(sessionID: String, afterSeq: Int?, knownItems: Int?)
    case unsubscribe(sessionID: String)
    /// Every mutation carries a client-chosen id; the host acks it exactly once.
    case send(id: String, sessionID: String, text: String)
    case answer(id: String, sessionID: String, requestID: String, decision: RemoteDecision)
    case interrupt(id: String, sessionID: String)
    case setPermissionMode(id: String, sessionID: String, mode: String)
    case startSession(id: String, cwd: String, prompt: String, permissionMode: String)
    case ping
}

/// Host → client.
enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(protocolVersion: Int, hostName: String, claudeVersion: String?)
    /// Reply to `pair`: the device's long-lived token (shown once).
    case paired(deviceID: String, token: String)
    case sessions([RemoteSessionInfo])
    /// Live state when events can't be replayed; events follow from `lastSeq`.
    case snapshot(sessionID: String, LiveSnapshot)
    case events(sessionID: String, [HostEvent])
    /// Replace the client's items from index `from` on (the last item can
    /// grow — e.g. a stretch of tool calls — so it's resent with new ones).
    case transcript(sessionID: String, from: Int, items: [ConversationItem])
    /// The outcome of a mutation, by the client's id.
    case ack(id: String, ok: Bool, error: String?, sessionID: String?)
    case error(String)
    case pong
}

extension ClientMessage {
    var encoded: Data { (try? JSONEncoder.remote.encode(self)) ?? Data() }
}

extension ServerMessage {
    var encoded: Data { (try? JSONEncoder.remote.encode(self)) ?? Data() }
}

extension JSONEncoder {
    /// Dates as ISO-8601 so non-Swift clients can read them too.
    static var remote: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var remote: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
