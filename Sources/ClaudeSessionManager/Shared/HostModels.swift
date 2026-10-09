import Foundation
import CryptoKit

// Types shared by the Mac host and remote clients (the iOS app compiles this
// folder too) — Foundation only.

/// What a hosted session is doing.
enum SessionPhase: String, Codable, Sendable, Equatable {
    case starting, idle, running, waiting, exited
}

/// What `can_use_tool` carries.
struct PermissionAsk: Equatable, Codable, Sendable {
    var toolName: String
    var displayName: String?
    var input: JSONValue
    var description: String?
    var toolUseID: String?
    /// Rules the CLI proposes for "always allow" (sent back as-is).
    var suggestions: JSONValue?
    var blockedPath: String?
    /// Set for AskUserQuestion / ExitPlanMode.
    var requiresUserInteraction: Bool
}

struct TurnResult: Equatable, Codable, Sendable {
    var subtype: String
    var isError: Bool
    var text: String?
    var costUSD: Double?
    var sessionID: String?
    var deniedTools: Int
}

/// Something waiting for the user: a tool approval, an AskUserQuestion, or
/// an ExitPlanMode plan review.
struct PendingRequest: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case permission, question, plan }

    /// The CLI's `request_id` — what the answer must echo.
    let id: String
    let kind: Kind
    let ask: PermissionAsk
    let createdAt: Date

    init(id: String, ask: PermissionAsk, createdAt: Date = Date()) {
        self.id = id
        self.ask = ask
        self.createdAt = createdAt
        switch ask.toolName {
        case "AskUserQuestion": kind = .question
        case "ExitPlanMode": kind = .plan
        default: kind = .permission
        }
    }
}

/// How the user answered a pending request.
enum RequestDecision: Equatable {
    /// Run it. `always` also sends the CLI's own suggested "always allow" rules.
    case allow(always: Bool)
    /// Don't; Claude sees `message`.
    case deny(message: String)
    /// AskUserQuestion: question text → chosen option label(s).
    case answer([String: String])
    /// ExitPlanMode: go ahead with the plan.
    case approvePlan
}

/// One event in a hosted session's log. Clients replay from the last `seq`
/// they saw, so a phone that drops off the network catches up exactly.
struct HostEvent: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case phase(SessionPhase)
        case textDelta(String)
        /// The streamed reply was committed (now in the transcript file).
        case replyCommitted
        case requestAdded(PendingRequest)
        case requestResolved(id: String, outcome: String)
        case queueChanged([String])
        case permissionMode(String)
        case turnFinished(TurnResult)
        case rateLimit(status: String?, resetsAt: Date?)
    }
    let seq: Int
    let at: Date
    let kind: Kind
}

/// A bounded, sequenced event log.
struct EventLog: Sendable {
    private(set) var events: [HostEvent] = []
    private(set) var lastSeq = 0
    let capacity: Int

    init(capacity: Int = 5000) { self.capacity = capacity }

    mutating func append(_ kind: HostEvent.Kind, at date: Date = Date()) {
        lastSeq += 1
        events.append(HostEvent(seq: lastSeq, at: date, kind: kind))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    /// Events after `seq`, or nil when they've been trimmed (the client must
    /// take a full snapshot instead).
    func events(after seq: Int) -> [HostEvent]? {
        guard seq < lastSeq else { return [] }
        guard let first = events.first, first.seq <= seq + 1 else { return nil }
        return events.filter { $0.seq > seq }
    }
}

/// The six digits both screens show during pairing, derived from the host
/// certificate's fingerprint — a client that saw a different certificate (a
/// man in the middle) shows a different code.
enum PairingSecurity {
    static func code(forFingerprint fp: String) -> String {
        let digest = SHA256.hash(data: Data(("csm-pairing:" + fp.lowercased()).utf8))
        let n = digest.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } % 1_000_000
        let s = String(format: "%06u", n)
        return s.prefix(3) + " " + s.suffix(3)
    }
}
