import Foundation

/// Parses Claude Code `.jsonl` session files into summaries and transcripts.
/// Uses `JSONSerialization` because the per-line schema varies a lot.
enum SessionParser {

    /// ISO8601DateFormatter isn't documented as thread-safe and scans parse
    /// files concurrently, so each thread gets its own pair of formatters.
    private static func formatters() -> (fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) {
        let key = "SessionParser.iso"
        if let cached = Thread.current.threadDictionary[key] as? [ISO8601DateFormatter] {
            return (cached[0], cached[1])
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        Thread.current.threadDictionary[key] = [fractional, plain]
        return (fractional, plain)
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = formatters()
        return f.fractional.date(from: s) ?? f.plain.date(from: s)
    }

    // MARK: - Line reading

    /// Calls `body` for every non-empty line of `url` starting at byte
    /// `offset`, with the line's JSON object (nil if it isn't one). Returns
    /// the offset just past the last line consumed, or nil if the file can't
    /// be read. A trailing line with no newline is consumed only if it parses
    /// — otherwise it's likely still being written, so it's left for the next
    /// call (which is what makes incremental re-reads safe).
    static func readLines(of url: URL, from offset: UInt64 = 0,
                          _ body: ([String: Any]?) -> Void) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return offset }

        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            let count = raw.count
            var lineStart = 0
            while lineStart < count {
                let nl = memchr(base + lineStart, 0x0A, count - lineStart)
                    .map { $0 - UnsafeMutableRawPointer(mutating: base) }
                let lineEnd = nl ?? count
                if lineEnd > lineStart {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + lineStart),
                                    count: lineEnd - lineStart, deallocator: .none)
                    let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    if nl == nil && obj == nil { break }   // partial final line
                    body(obj)
                }
                lineStart = lineEnd + 1
                consumed = min(lineStart, count)
            }
        }
        return offset + UInt64(consumed)
    }

    // MARK: - Summary (cheap, for the list)

    /// Running state of a summary parse. Codable so `SummaryCache` can persist
    /// it and resume parsing from where it stopped when the file grows.
    struct SummaryState: Codable, Sendable {
        var cwd = ""
        var gitBranch: String?
        var version: String?
        /// Latest `ai-title` (Claude's generated title).
        var title: String?
        /// Latest `custom-title` (set by `/rename`, or Rename in this app) —
        /// wins over the generated one.
        var customTitle: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var messageCount = 0
        var models: [String] = []
        var totalOutput = 0
        var createdAt: Date?
        var lastActivityAt: Date?
        var latestContextTokens = 0
        var maxContextTokens = 0

        mutating func consume(_ obj: [String: Any]) {
            let type = obj["type"] as? String ?? ""

            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            if version == nil, let v = obj["version"] as? String { version = v }
            if createdAt == nil, let t = parseDate(obj["timestamp"]) { createdAt = t }

            switch type {
            case "user":
                messageCount += 1
                if let t = parseDate(obj["timestamp"]) { lastActivityAt = t }
                // isMeta turns are harness-generated (caveats, reminders), not typed.
                if (obj["isMeta"] as? Bool) != true, let msg = obj["message"] as? [String: Any],
                   let t = firstText(from: msg["content"]) {
                    if firstPrompt == nil { firstPrompt = t }
                    lastPrompt = t
                }
            case "assistant":
                messageCount += 1
                if let t = parseDate(obj["timestamp"]) { lastActivityAt = t }
                if let msg = obj["message"] as? [String: Any] {
                    if let m = msg["model"] as? String, !models.contains(m) { models.append(m) }
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
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
            case "last-prompt":
                if let p = (obj["lastPrompt"] as? String).flatMap(PromptText.clean) { lastPrompt = p }
            default:
                break
            }
        }

        func summary(for url: URL, mtime: Date, size: Int) -> SessionSummary {
            SessionSummary(
                id: url.deletingPathExtension().lastPathComponent,
                fileURL: url,
                projectFolder: url.deletingLastPathComponent().lastPathComponent,
                cwd: cwd,
                gitBranch: gitBranch,
                claudeVersion: version,
                title: customTitle ?? title ?? firstPrompt.map { String($0.prefix(80)) } ?? "(untitled session)",
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
    }

    /// Continue a summary parse from `offset` (0 = from scratch). Returns the
    /// updated state and the new offset, or nil if the file can't be read.
    static func summaryState(for url: URL, resuming state: SummaryState = SummaryState(),
                             from offset: UInt64 = 0) -> (state: SummaryState, offset: UInt64)? {
        var state = state
        guard let end = readLines(of: url, from: offset, { obj in
            if let obj { state.consume(obj) }
        }) else { return nil }
        return (state, end)
    }

    static func summary(for url: URL) -> SessionSummary? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return summaryState(for: url)?.state.summary(for: url, mtime: mtime, size: size)
    }

    // MARK: - Full transcript (for the detail pane)

    /// Where a transcript parse stopped: byte offset plus the index of the
    /// next line (event ids are line indices, so they stay stable across
    /// incremental reads).
    struct TranscriptCursor: Sendable, Equatable {
        var offset: UInt64 = 0
        var lineIndex = 0
    }

    static func transcript(for url: URL) -> [TranscriptEvent] {
        transcriptEvents(for: url)?.events ?? []
    }

    /// Parse transcript events from `cursor` onward, folding what the lines
    /// say about outputs into `insights`. Returns the new events, the updated
    /// insights and the cursor to resume from, or nil if the file can't be read.
    static func transcriptEvents(for url: URL, from cursor: TranscriptCursor = TranscriptCursor(),
                                 insights: SessionInsights = SessionInsights())
        -> (events: [TranscriptEvent], insights: SessionInsights, cursor: TranscriptCursor)? {
        var events: [TranscriptEvent] = []
        var insights = insights
        var index = cursor.lineIndex
        guard let end = readLines(of: url, from: cursor.offset, { obj in
            defer { index += 1 }
            guard let obj else { return }
            insights.consume(obj)
            if let event = event(from: obj, index: index) { events.append(event) }
        }) else { return nil }
        return (events, insights, TranscriptCursor(offset: end, lineIndex: index))
    }

    /// What a session produced, gathered while reading its transcript.
    struct SessionInsights: Sendable, Equatable {
        struct PullRequest: Hashable, Sendable {
            let number: Int
            let url: String
            let repository: String
        }
        struct DeliveredFile: Hashable, Sendable {
            let path: String
            let caption: String?
        }

        /// Latest desktop recap (`away_summary`): goal, state, next step.
        var recap: String?
        var recapDate: Date?
        var pullRequests: [PullRequest] = []
        /// Files handed to the user (`SendUserFile`), oldest first, deduped.
        var deliveredFiles: [DeliveredFile] = []
        /// Path → number of Edit/Write/NotebookEdit calls on it.
        var editedFiles: [String: Int] = [:]
        /// Times the conversation was compacted.
        var compactions = 0

        mutating func consume(_ obj: [String: Any]) {
            switch obj["type"] as? String {
            case "pr-link":
                guard let url = obj["prUrl"] as? String, !pullRequests.contains(where: { $0.url == url }) else { return }
                pullRequests.append(PullRequest(number: (obj["prNumber"] as? Int) ?? 0, url: url,
                                                repository: (obj["prRepository"] as? String) ?? ""))
            case "system":
                switch obj["subtype"] as? String {
                case "away_summary":
                    if let text = (obj["content"] as? String).map(Self.stripRecapHint), !text.isEmpty {
                        recap = text
                        recapDate = parseDate(obj["timestamp"])
                    }
                case "compact_boundary":
                    compactions += 1
                default:
                    break
                }
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where (block["type"] as? String) == "tool_use" {
                    let input = block["input"] as? [String: Any] ?? [:]
                    switch block["name"] as? String {
                    case "Edit", "Write", "MultiEdit", "NotebookEdit":
                        if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                            editedFiles[path, default: 0] += 1
                        }
                    case "SendUserFile":
                        let caption = (input["caption"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        for case let path as String in (input["files"] as? [Any]) ?? []
                        where !deliveredFiles.contains(where: { $0.path == path }) {
                            deliveredFiles.append(DeliveredFile(path: path, caption: caption))
                        }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        /// Recaps end with a settings hint like "(disable recaps in /config)".
        private static func stripRecapHint(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix(")"), let open = t.range(of: "(disable recaps", options: .backwards) {
                t = String(t[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return t
        }
    }

    private static func event(from obj: [String: Any], index: Int) -> TranscriptEvent? {
        let type = obj["type"] as? String ?? ""
        let ts = parseDate(obj["timestamp"])

        switch type {
        case "user":
            let msg = obj["message"] as? [String: Any]
            let blocks = contentBlocks(from: msg?["content"], toolResult: obj["toolUseResult"], cleanText: true)
            // isMeta turns are harness-generated, not something the user typed.
            let kind: TranscriptEvent.Kind = (obj["isMeta"] as? Bool) == true ? .meta : .user
            return blocks.isEmpty ? nil : .init(id: index, kind: kind, timestamp: ts, model: nil, blocks: blocks)
        case "assistant":
            let msg = obj["message"] as? [String: Any]
            let blocks = contentBlocks(from: msg?["content"], toolResult: nil)
            return blocks.isEmpty ? nil
                : .init(id: index, kind: .assistant, timestamp: ts, model: msg?["model"] as? String, blocks: blocks)
        case "attachment":
            let att = obj["attachment"] as? [String: Any]
            let desc = (att?["type"] as? String) ?? "attachment"
            return .init(id: index, kind: .attachment, timestamp: ts, model: nil, blocks: [.note("Attachment: \(desc)")])
        case "system":
            let subtype = obj["subtype"] as? String ?? "system"
            return .init(id: index, kind: .system, timestamp: ts, model: nil, blocks: [.note(subtype)])
        default:
            return nil   // mode / permission-mode / ai-title / last-prompt / snapshots: skipped in transcript
        }
    }

    // MARK: - Content helpers

    /// First text the user actually typed in a message content (String or
    /// block array), with harness-injected tags removed (see `PromptText`).
    private static func firstText(from content: Any?) -> String? {
        if let s = content as? String { return PromptText.clean(s) }
        if let arr = content as? [[String: Any]] {
            for b in arr where (b["type"] as? String) == "text" {
                if let t = (b["text"] as? String).flatMap(PromptText.clean) { return t }
            }
        }
        return nil
    }

    /// Convert a message `content` (+ optional toolUseResult) into display blocks.
    /// `cleanText` strips harness-injected tags from text blocks (user turns).
    private static func contentBlocks(from content: Any?, toolResult: Any?,
                                      cleanText: Bool = false) -> [TranscriptEvent.Block] {
        var blocks: [TranscriptEvent.Block] = []
        func text(_ raw: String?) -> String? {
            guard let raw else { return nil }
            if cleanText { return PromptText.clean(raw) }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        if let s = content as? String {
            if let t = text(s) { blocks.append(.text(t)) }
        } else if let arr = content as? [[String: Any]] {
            for b in arr {
                switch b["type"] as? String {
                case "text":
                    if let t = text(b["text"] as? String) { blocks.append(.text(t)) }
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
