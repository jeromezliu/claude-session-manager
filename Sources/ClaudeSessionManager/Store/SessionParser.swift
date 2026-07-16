import Foundation

/// Parses Claude Code `.jsonl` session files into summaries and transcripts.
/// Uses `JSONSerialization` because the per-line schema varies a lot.
enum SessionParser {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: - Summary (cheap, for the list)

    static func summary(for url: URL) -> SessionSummary? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var cwd = ""
        var gitBranch: String?
        var version: String?
        var title: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var messageCount = 0
        var models: [String] = []
        var totalOutput = 0
        var createdAt: Date?
        var lastActivityAt: Date?
        var latestContextTokens = 0
        var maxContextTokens = 0
        var lastModel: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""

            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            if version == nil, let v = obj["version"] as? String { version = v }
            if createdAt == nil, let t = parseDate(obj["timestamp"]) { createdAt = t }

            switch type {
            case "user":
                messageCount += 1
                if let t = parseDate(obj["timestamp"]) { lastActivityAt = t }
                if let msg = obj["message"] as? [String: Any] {
                    let t = firstText(from: msg["content"])
                    if let t, !t.isEmpty {
                        if firstPrompt == nil { firstPrompt = t }
                        lastPrompt = t
                    }
                }
            case "assistant":
                messageCount += 1
                if let t = parseDate(obj["timestamp"]) { lastActivityAt = t }
                if let msg = obj["message"] as? [String: Any] {
                    if let m = msg["model"] as? String {
                        lastModel = m
                        if !models.contains(m) { models.append(m) }
                    }
                    if let usage = msg["usage"] as? [String: Any] {
                        if let out = usage["output_tokens"] as? Int { totalOutput += out }
                        // Context size at this turn ≈ input + cache read + cache creation.
                        let input = (usage["input_tokens"] as? Int) ?? 0
                        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                        let ctx = input + cacheRead + cacheCreate
                        if ctx > 0 { latestContextTokens = ctx }
                        if ctx > maxContextTokens { maxContextTokens = ctx }
                    }
                }
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.isEmpty { title = t }
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String, !p.isEmpty { lastPrompt = p }
            default:
                break
            }
        }

        let finalTitle = title
            ?? firstPrompt.map { String($0.prefix(80)) }
            ?? "(untitled session)"

        return SessionSummary(
            id: url.deletingPathExtension().lastPathComponent,
            fileURL: url,
            projectFolder: url.deletingLastPathComponent().lastPathComponent,
            cwd: cwd,
            gitBranch: gitBranch,
            claudeVersion: version,
            title: finalTitle,
            firstPrompt: firstPrompt,
            lastPrompt: lastPrompt,
            messageCount: messageCount,
            models: models,
            totalOutputTokens: totalOutput,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            modifiedAt: mtime,
            fileSize: size,
            latestContextTokens: latestContextTokens,
            maxContextTokens: maxContextTokens
        )
    }

    // MARK: - Full transcript (for the detail pane)

    static func transcript(for url: URL) -> [TranscriptEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [TranscriptEvent] = []
        var index = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { index += 1 }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            let ts = parseDate(obj["timestamp"])

            switch type {
            case "user":
                let msg = obj["message"] as? [String: Any]
                let blocks = contentBlocks(from: msg?["content"], toolResult: obj["toolUseResult"])
                if !blocks.isEmpty {
                    events.append(.init(id: index, kind: .user, timestamp: ts, model: nil, blocks: blocks))
                }
            case "assistant":
                let msg = obj["message"] as? [String: Any]
                let model = msg?["model"] as? String
                let blocks = contentBlocks(from: msg?["content"], toolResult: nil)
                if !blocks.isEmpty {
                    events.append(.init(id: index, kind: .assistant, timestamp: ts, model: model, blocks: blocks))
                }
            case "attachment":
                let att = obj["attachment"] as? [String: Any]
                let desc = (att?["type"] as? String) ?? "attachment"
                events.append(.init(id: index, kind: .attachment, timestamp: ts, model: nil,
                                    blocks: [.note("Attachment: \(desc)")]))
            case "system":
                let subtype = obj["subtype"] as? String ?? "system"
                events.append(.init(id: index, kind: .system, timestamp: ts, model: nil,
                                    blocks: [.note(subtype)]))
            default:
                break   // mode / permission-mode / ai-title / last-prompt / snapshots: skipped in transcript
            }
        }
        return events
    }

    // MARK: - Content helpers

    /// First plain-text string from a message content (String or block array).
    private static func firstText(from content: Any?) -> String? {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = content as? [[String: Any]] {
            for b in arr where (b["type"] as? String) == "text" {
                if let t = b["text"] as? String { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return nil
    }

    /// Convert a message `content` (+ optional toolUseResult) into display blocks.
    private static func contentBlocks(from content: Any?, toolResult: Any?) -> [TranscriptEvent.Block] {
        var blocks: [TranscriptEvent.Block] = []

        if let s = content as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        } else if let arr = content as? [[String: Any]] {
            for b in arr {
                switch b["type"] as? String {
                case "text":
                    if let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        blocks.append(.text(t))
                    }
                case "thinking":
                    if let t = (b["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        blocks.append(.thinking(t))
                    }
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    let input = prettyJSON(b["input"]) ?? ""
                    blocks.append(.toolUse(name: name, input: input))
                case "tool_result":
                    let isErr = (b["is_error"] as? Bool) ?? false
                    let t = stringifyToolResult(b["content"])
                    blocks.append(.toolResult(text: t, isError: isErr))
                case "image":
                    let media = ((b["source"] as? [String: Any])?["media_type"] as? String) ?? "image"
                    blocks.append(.image(media))
                default:
                    break
                }
            }
        }

        // Surface a tool result attached at the line level (user turns carrying results).
        if let tr = toolResult {
            let t = stringifyToolResult(tr)
            if !t.isEmpty { blocks.append(.toolResult(text: t, isError: false)) }
        }
        return blocks
    }

    private static func stringifyToolResult(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let arr = any as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let dict = any as? [String: Any], let s = dict["stdout"] as? String { return s }
        return prettyJSON(any) ?? ""
    }

    private static func prettyJSON(_ any: Any?) -> String? {
        guard let any, JSONSerialization.isValidJSONObject(any) else {
            if let any { return String(describing: any) }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
