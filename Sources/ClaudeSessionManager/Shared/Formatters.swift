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

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        // A file being written right now can carry an mtime at or a hair
        // ahead of `now`, which the formatter renders as "in 0 sec." (and a
        // skewed clock as "in 5 min."). Anything that recent is just "now".
        if date.timeIntervalSince(now) > -60 { return "now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMddHHmm")
        return f
    }()

    /// Compact date + time for lists, e.g. "10/03, 14:54" (locale order).
    static func short(_ date: Date) -> String { shortDate.string(from: date) }

    /// A span as its largest units: "45s", "12m", "3h 20m", "5d 2h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
        default: return s % 86_400 / 3600 == 0 ? "\(s / 86_400)d" : "\(s / 86_400)d \(s % 86_400 / 3600)h"
        }
    }

    /// MCP tools are named `mcp__<server>__<tool>`; show just the tool.
    static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"), let r = name.range(of: "__", options: .backwards) else { return name }
        return String(name[r.upperBound...])
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
