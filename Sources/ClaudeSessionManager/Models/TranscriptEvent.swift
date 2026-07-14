import Foundation

/// A single renderable event parsed from one JSONL line of a session file.
struct TranscriptEvent: Identifiable, Hashable, Sendable {
    let id: Int          // line index — stable within a parse
    let kind: Kind
    let timestamp: Date?
    let model: String?
    let blocks: [Block]

    enum Kind: String, Sendable {
        case user
        case assistant
        case system
        case attachment
        case meta        // mode / permission-mode / ai-title / last-prompt / snapshots

        var label: String {
            switch self {
            case .user: return "User"
            case .assistant: return "Assistant"
            case .system: return "System"
            case .attachment: return "Attachment"
            case .meta: return "Meta"
            }
        }
    }

    /// A content block inside an event.
    enum Block: Hashable, Sendable {
        case text(String)
        case thinking(String)
        case toolUse(name: String, input: String)
        case toolResult(text: String, isError: Bool)
        case image(String)              // description / media type
        case note(String)               // for meta lines
    }
}
