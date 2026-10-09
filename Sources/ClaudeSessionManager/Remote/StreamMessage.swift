import Foundation

/// One line of `claude -p --output-format stream-json` output, reduced to
/// what the remote host acts on. Shapes are documented in
/// docs/remote/P0-stream-json-protocol.md and pinned by the contract tests;
/// anything else decodes as `.other` and is ignored, so new message types in
/// a Claude Code update don't break the host.
enum StreamMessage: Equatable {
    case initialized(sessionID: String, version: String?, model: String?, permissionMode: String?)
    /// `system/status` — e.g. "requesting" while waiting on the API.
    case status(String)
    /// A piece of the reply being written (`stream_event` / `text_delta`).
    case textDelta(String)
    /// A content block or message finished streaming.
    case blockStopped
    /// A complete assistant message (authoritative over the deltas).
    case assistant
    /// Claude wants permission, an answer, or plan approval.
    case canUseTool(requestID: String, PermissionAsk)
    /// The CLI withdrew an open request (e.g. after an interrupt).
    case cancelRequest(requestID: String)
    /// Ack of a request the host sent.
    case controlResponse(requestID: String, response: JSONValue?)
    case rateLimit(status: String?, type: String?, resetsAt: Date?)
    /// The turn ended.
    case result(TurnResult)
    case other

    typealias PermissionAsk = ClaudeSessionManager.PermissionAsk
    typealias TurnResult = ClaudeSessionManager.TurnResult

    static func decode(_ obj: [String: Any]) -> StreamMessage {
        let type = obj["type"] as? String
        switch type {
        case "system":
            switch obj["subtype"] as? String {
            case "init":
                guard let id = obj["session_id"] as? String else { return .other }
                return .initialized(sessionID: id, version: obj["claude_code_version"] as? String,
                                    model: obj["model"] as? String, permissionMode: obj["permissionMode"] as? String)
            case "status":
                return .status(obj["status"] as? String ?? "")
            default:
                return .other
            }
        case "stream_event":
            let event = obj["event"] as? [String: Any]
            switch event?["type"] as? String {
            case "content_block_delta":
                let delta = event?["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String { return .textDelta(t) }
                return .other
            case "content_block_stop", "message_stop":
                return .blockStopped
            default:
                return .other
            }
        case "assistant":
            return .assistant
        case "control_request":
            guard let id = obj["request_id"] as? String,
                  let req = obj["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool",
                  let tool = req["tool_name"] as? String else { return .other }
            let suggestions = req["permission_suggestions"].map { JSONValue(any: $0) }
            return .canUseTool(requestID: id, PermissionAsk(
                toolName: tool,
                displayName: req["display_name"] as? String,
                input: JSONValue(any: req["input"]),
                description: req["description"] as? String,
                toolUseID: req["tool_use_id"] as? String,
                suggestions: suggestions == .null ? nil : suggestions,
                blockedPath: req["blocked_path"] as? String,
                requiresUserInteraction: (req["requires_user_interaction"] as? Bool) ?? false))
        case "control_cancel_request":
            guard let id = obj["request_id"] as? String else { return .other }
            return .cancelRequest(requestID: id)
        case "control_response":
            let r = obj["response"] as? [String: Any]
            guard let id = r?["request_id"] as? String else { return .other }
            return .controlResponse(requestID: id, response: r?["response"].map { JSONValue(any: $0) })
        case "rate_limit_event":
            let info = obj["rate_limit_info"] as? [String: Any]
            return .rateLimit(status: info?["status"] as? String, type: info?["rateLimitType"] as? String,
                              resetsAt: (info?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
        case "result":
            return .result(TurnResult(
                subtype: obj["subtype"] as? String ?? "",
                isError: (obj["is_error"] as? Bool) ?? false,
                text: obj["result"] as? String,
                costUSD: obj["total_cost_usd"] as? Double,
                sessionID: obj["session_id"] as? String,
                deniedTools: (obj["permission_denials"] as? [Any])?.count ?? 0))
        default:
            return .other
        }
    }
}

/// Messages the host writes to the CLI's stdin.
enum HostCommand {
    static func userTurn(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
    }

    static func allow(requestID: String, input: JSONValue, permissions: JSONValue? = nil) -> [String: Any] {
        var response: [String: Any] = ["behavior": "allow", "updatedInput": input.anyValue]
        if let permissions { response["updatedPermissions"] = permissions.anyValue }
        return controlResponse(requestID, response)
    }

    static func deny(requestID: String, message: String) -> [String: Any] {
        controlResponse(requestID, ["behavior": "deny", "message": message])
    }

    static func interrupt(requestID: String) -> [String: Any] {
        ["type": "control_request", "request_id": requestID, "request": ["subtype": "interrupt"]]
    }

    static func setPermissionMode(_ mode: String, requestID: String) -> [String: Any] {
        ["type": "control_request", "request_id": requestID, "request": ["subtype": "set_permission_mode", "mode": mode]]
    }

    private static func controlResponse(_ id: String, _ response: [String: Any]) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]]
    }
}
