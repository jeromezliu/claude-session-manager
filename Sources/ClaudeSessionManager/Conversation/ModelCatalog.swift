import Foundation

/// The models offered in the conversation picker.
///
/// There is no `claude --list-models`, and the Models API needs the
/// subscription OAuth token, so the catalog is built from two credential-free
/// sources:
///
///  1. **Aliases the CLI documents** (`--model fable|opus|sonnet|haiku`) —
///     always resolve to the newest release, so they never go stale.
///  2. **Concrete ids actually seen in the user's own sessions** (parsed from
///     the assistant lines the app already reads) — ordered most-recent first,
///     so a brand-new model shows up as soon as it has been used once.
enum ModelCatalog {
    /// Aliases the CLI accepts for "latest of this family".
    static let aliases: [(id: String, label: String)] = [
        ("default", "Default"),
        ("fable", "Fable (latest)"),
        ("opus", "Opus (latest)"),
        ("sonnet", "Sonnet (latest)"),
        ("haiku", "Haiku (latest)"),
    ]

    /// Friendly label for a concrete model id, e.g.
    /// `claude-opus-4-8` → "Opus 4.8", `claude-haiku-4-5-20251001` → "Haiku 4.5".
    static func label(for id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Drop a trailing yyyymmdd snapshot segment.
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// Concrete model ids used across the given sessions, most-recently-used first.
    static func discovered(from groups: [ProjectGroup]) -> [String] {
        var lastUsed: [String: Date] = [:]
        for group in groups {
            for session in group.sessions {
                for model in session.models where model != "<synthetic>" && !model.isEmpty {
                    let date = session.sortDate
                    if let existing = lastUsed[model] {
                        if date > existing { lastUsed[model] = date }
                    } else {
                        lastUsed[model] = date
                    }
                }
            }
        }
        return lastUsed.sorted { $0.value > $1.value }.map(\.key)
    }
}
