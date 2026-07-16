import Foundation

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateTime.string(from: date)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Compact whole-unit label for a context window, e.g. 200000 -> "200K", 1000000 -> "1M".
    static func window(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    /// Trim a model id like "claude-fable-5" to a short label.
    static func model(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
    }
}
