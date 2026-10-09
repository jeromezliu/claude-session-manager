import Foundation

/// A Claude Code session the app itself runs headless (`claude -p`
/// stream-json), so the Mac UI and remote clients can watch it, talk to it
/// and answer its approvals. One owner per session: everything that reaches
/// the CLI goes through here.
@MainActor
final class HostedSession: ObservableObject, Identifiable {
    typealias Phase = SessionPhase

    /// Host-minted id, stable from the start (the CLI's id arrives later).
    let id = UUID()
    let cwd: String
    @Published private(set) var sessionID: String?
    @Published private(set) var phase: Phase = .starting
    /// The reply being streamed right now (cleared once committed).
    @Published private(set) var liveText = ""
    @Published private(set) var pending: [PendingRequest] = []
    /// Messages held back while a request is pending — sending them would
    /// otherwise race the approval.
    @Published private(set) var queued: [String] = []
    @Published private(set) var permissionMode: String
    @Published private(set) var claudeVersion: String?
    @Published private(set) var lastResult: TurnResult?
    @Published private(set) var exitReason: String?
    @Published private(set) var log = EventLog()

    private let transport: ClaudeTransport
    private var requestCounter = 0
    /// Turns written to stdin but not yet finished.
    private var inFlight = 0

    init(cwd: String, resume: String?, permissionMode: String = "default", transport: ClaudeTransport) {
        self.cwd = cwd
        self.sessionID = resume
        self.permissionMode = permissionMode
        self.transport = transport
        transport.onMessage = { [weak self] in self?.handle($0) }
        transport.onExit = { [weak self] status, stderr in self?.handleExit(status: status, stderr: stderr) }
    }

    func start() throws {
        try transport.start()
        // A resumed session is ready for input right away; the CLI only
        // emits system/init once the first turn begins.
        setPhase(.idle)
    }

    // MARK: - Input

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, phase != .exited else { return }
        if pending.isEmpty {
            write(turn: t)
        } else {
            queued.append(t)
            log.append(.queueChanged(queued))
        }
    }

    func answer(_ requestID: String, _ decision: RequestDecision) {
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        let outcome: String
        switch decision {
        case .allow(let always):
            transport.send(HostCommand.allow(requestID: requestID, input: request.ask.input,
                                             permissions: always ? request.ask.suggestions : nil))
            outcome = always ? "allowedAlways" : "allowed"
        case .deny(let message):
            transport.send(HostCommand.deny(requestID: requestID,
                                            message: message.isEmpty ? "The user denied this." : message))
            outcome = "denied"
        case .answer(let answers):
            var input = request.ask.input.objectValue ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0) })
            transport.send(HostCommand.allow(requestID: requestID, input: .object(input)))
            outcome = "answered"
        case .approvePlan:
            transport.send(HostCommand.allow(requestID: requestID, input: request.ask.input))
            outcome = "approved"
        }
        resolve(requestID, outcome: outcome)
    }

    func interrupt() {
        guard inFlight > 0 || !pending.isEmpty else { return }
        transport.send(HostCommand.interrupt(requestID: nextRequestID()))
    }

    func setPermissionMode(_ mode: String) {
        guard mode != permissionMode, phase != .exited else { return }
        transport.send(HostCommand.setPermissionMode(mode, requestID: nextRequestID()))
        // Applied optimistically; the CLI's ack confirms it.
        permissionMode = mode
        log.append(.permissionMode(mode))
    }

    func stop() { transport.terminate() }

    // MARK: - Output

    func handle(_ obj: [String: Any]) {
        switch StreamMessage.decode(obj) {
        case .initialized(let id, let version, _, let mode):
            sessionID = id
            claudeVersion = version ?? claudeVersion
            if let mode, mode != permissionMode { permissionMode = mode; log.append(.permissionMode(mode)) }
        case .status:
            if pending.isEmpty, inFlight > 0 { setPhase(.running) }
        case .textDelta(let t):
            liveText += t
            log.append(.textDelta(t))
            if pending.isEmpty { setPhase(.running) }
        case .assistant:
            if !liveText.isEmpty {
                liveText = ""
                log.append(.replyCommitted)
            }
        case .blockStopped:
            break
        case .canUseTool(let requestID, let ask):
            guard !pending.contains(where: { $0.id == requestID }) else { return }   // resolve once
            let request = PendingRequest(id: requestID, ask: ask)
            pending.append(request)
            log.append(.requestAdded(request))
            setPhase(.waiting)
        case .cancelRequest(let requestID):
            resolve(requestID, outcome: "canceled")
        case .controlResponse(_, let response):
            if let mode = response?["mode"]?.stringValue, mode != permissionMode {
                permissionMode = mode
                log.append(.permissionMode(mode))
            }
        case .rateLimit(let status, _, let resetsAt):
            log.append(.rateLimit(status: status, resetsAt: resetsAt))
        case .result(let result):
            inFlight = max(0, inFlight - 1)
            if let id = result.sessionID { sessionID = id }
            lastResult = result
            if !liveText.isEmpty { liveText = ""; log.append(.replyCommitted) }
            // Anything still open belonged to the finished turn.
            for request in pending { resolve(request.id, outcome: "canceled") }
            log.append(.turnFinished(result))
            setPhase(inFlight > 0 ? .running : .idle)
        case .other:
            break
        }
    }

    private func handleExit(status: Int32, stderr: String) {
        for request in pending { resolve(request.id, outcome: "canceled") }
        inFlight = 0
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        exitReason = status == 0 ? nil : (detail.isEmpty ? "claude exited with status \(status)" : detail)
        setPhase(.exited)
    }

    // MARK: - Helpers

    private func write(turn text: String) {
        transport.send(HostCommand.userTurn(text))
        inFlight += 1
        setPhase(.running)
    }

    private func resolve(_ requestID: String, outcome: String) {
        guard pending.contains(where: { $0.id == requestID }) else { return }
        pending.removeAll { $0.id == requestID }
        log.append(.requestResolved(id: requestID, outcome: outcome))
        guard pending.isEmpty else { return }
        // The approval is settled: release what the user typed meanwhile.
        if !queued.isEmpty {
            let held = queued
            queued = []
            log.append(.queueChanged([]))
            held.forEach(write(turn:))
        } else if phase == .waiting {
            setPhase(inFlight > 0 ? .running : .idle)
        }
    }

    private func setPhase(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        log.append(.phase(p))
    }

    private func nextRequestID() -> String {
        requestCounter += 1
        return "host_\(id.uuidString.prefix(8))_\(requestCounter)"
    }
}
