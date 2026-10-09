import Foundation

/// A transcript reshaped for reading: what you asked, what Claude answered,
/// and the tool work in between folded into one line per stretch.
enum ConversationItem: Identifiable, Hashable {
    /// Something the user typed.
    case prompt(id: Int, date: Date?, text: String)
    /// Claude's prose answer (text blocks of one assistant event).
    case reply(id: Int, date: Date?, model: String?, text: String)
    /// Consecutive tool calls / results / thinking between prompts and replies.
    case activity(Activity)
    /// Attachments, system events and harness turns — shown only on request.
    case note(id: Int, date: Date?, text: String)

    struct Activity: Hashable {
        let id: Int
        /// Every non-prose block of the stretch, in order (for expanding).
        var blocks: [TranscriptEvent.Block]
        /// Tool name → calls, most used first.
        var toolCounts: [(name: String, count: Int)] {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for case .toolUse(let name, _) in blocks {
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1
            }
            return order.map { ($0, counts[$0]!) }.sorted { $0.count > $1.count }
        }
        var callCount: Int { blocks.reduce(0) { if case .toolUse = $1 { return $0 + 1 } else { return $0 } } }
        var hasError: Bool { blocks.contains { if case .toolResult(_, true) = $0 { return true } else { return false } } }

        static func == (a: Activity, b: Activity) -> Bool { a.id == b.id && a.blocks == b.blocks }
        func hash(into h: inout Hasher) { h.combine(id); h.combine(blocks.count) }
    }

    /// Stable ids (scroll targets): one item per kind per source event.
    var id: String {
        switch self {
        case .prompt(let id, _, _): return "p\(id)"
        case .reply(let id, _, _, _): return "r\(id)"
        case .activity(let a): return "a\(a.id)"
        case .note(let id, _, _): return "n\(id)"
        }
    }
}

enum ConversationBuilder {

    /// Chronological items for `events` (which must be in file order).
    static func items(from events: [TranscriptEvent]) -> [ConversationItem] {
        var items: [ConversationItem] = []
        var pending: ConversationItem.Activity?
        // Notes that arrive mid-activity follow it, so a stretch of tool work
        // stays one line whether notes are shown or hidden.
        var pendingNotes: [ConversationItem] = []

        func flush() {
            if let a = pending, !a.blocks.isEmpty { items.append(.activity(a)) }
            items += pendingNotes
            pending = nil
            pendingNotes = []
        }
        func addActivity(_ blocks: [TranscriptEvent.Block], id: Int) {
            guard !blocks.isEmpty else { return }
            if pending == nil { pending = .init(id: id, blocks: []) }
            pending!.blocks += blocks
        }

        for event in events {
            let texts = event.blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }
            let other = event.blocks.filter { if case .text = $0 { return false } else { return true } }

            switch event.kind {
            case .user:
                // Tool results ride on user turns; they belong to the work
                // that came before the next prompt.
                addActivity(other, id: event.id)
                if !texts.isEmpty {
                    flush()
                    items.append(.prompt(id: event.id, date: event.timestamp, text: texts.joined(separator: "\n\n")))
                }
            case .assistant:
                if !texts.isEmpty {
                    flush()
                    items.append(.reply(id: event.id, date: event.timestamp, model: event.model,
                                        text: texts.joined(separator: "\n\n")))
                }
                addActivity(other, id: event.id)
            case .system, .attachment, .meta:
                let text = event.blocks.compactMap { block -> String? in
                    switch block {
                    case .note(let n), .text(let n): return n
                    default: return nil
                    }
                }.joined(separator: " ")
                guard !text.isEmpty else { break }
                let note = ConversationItem.note(id: event.id, date: event.timestamp, text: text)
                if pending == nil { items.append(note) } else { pendingNotes.append(note) }
            }
        }
        flush()
        return items
    }
}
