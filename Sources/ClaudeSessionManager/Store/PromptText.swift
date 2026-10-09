import Foundation

/// Cleans text the harness injects into user turns, so titles, previews and
/// transcripts show what the user actually typed:
///
/// - `<system-reminder>…</system-reminder>` blocks (the desktop app prepends
///   these to the first message) are dropped;
/// - slash commands, stored as `<command-message>/<command-name>/<command-args>`
///   tags, become `/name args`;
/// - `!` shell commands (`<bash-input>`) become `! cmd`; their output is dropped;
/// - background-task notifications, local-command caveats and captured
///   stdout/stderr are dropped;
/// - pasted content keeps its text but loses its wrapper tag.
enum PromptText {

    private static let droppedBlocks: [NSRegularExpression] = [
        "system-reminder", "task-notification", "create-pr-command",
        "local-command-caveat", "local-command-stdout", "local-command-stderr",
        "bash-stdout", "bash-stderr", "command-message",
    ].map { tag in
        // `[^>]*` also matches tags carrying attributes.
        try! NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>\\s*")
    }

    /// Wrapper tags whose content is the user's own text.
    private static let unwrapped = try! NSRegularExpression(pattern: "</?pasted_content(?:\\s[^>]*)?>")
    private static let bashInput = try! NSRegularExpression(pattern: "<bash-input>([\\s\\S]*?)</bash-input>")

    private static let commandName = try! NSRegularExpression(pattern: "<command-name>([\\s\\S]*?)</command-name>\\s*")
    private static let commandArgs = try! NSRegularExpression(pattern: "<command-args>([\\s\\S]*?)</command-args>\\s*")

    /// The user-visible text of `raw`, or nil if nothing is left.
    static func clean(_ raw: String) -> String? {
        guard raw.contains("<") else {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var s = raw
        for re in droppedBlocks { s = replace(re, in: s, with: "") }
        s = replace(unwrapped, in: s, with: "")
        s = replace(bashInput, in: s, with: "! $1")

        // A slash command: render it the way it was typed.
        if let name = firstCapture(commandName, in: s) {
            let args = firstCapture(commandArgs, in: s) ?? ""
            s = replace(commandName, in: s, with: "")
            s = replace(commandArgs, in: s, with: "")
            let rest = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = args.isEmpty ? name : "\(name) \(args)"
            s = rest.isEmpty ? command : "\(command)\n\(rest)"
        }

        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func firstCapture(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let v = s[r].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
