import Foundation

/// A custom slash command the CLI would accept in a `-p` prompt, discovered
/// from the Markdown files under a commands directory.
struct SlashCommand: Identifiable, Hashable {
    let name: String            // without the leading slash
    let description: String?
    let scope: String           // "Project" or "Personal"
    var id: String { scope + "/" + name }
    var invocation: String { "/" + name }
}

/// Lists the custom slash commands available to a session, so the conversation
/// input can offer them. Headless `claude -p "/name …"` resolves these exactly
/// like the interactive CLI (verified), so the app only has to surface them.
///
/// Sources match the CLI's own resolution order: the project's
/// `<cwd>/.claude/commands` first, then the user's `~/.claude/commands`.
/// Project commands shadow personal ones of the same name.
enum SlashCommandCatalog {
    static func commands(projectDir: String?) -> [SlashCommand] {
        var found: [SlashCommand] = []
        if let projectDir, !projectDir.isEmpty {
            found += scan(URL(fileURLWithPath: projectDir).appendingPathComponent(".claude/commands"),
                          scope: "Project")
        }
        found += scan(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/commands"),
                      scope: "Personal")

        var seen = Set<String>()
        var result: [SlashCommand] = []
        for c in found where !seen.contains(c.name) {   // project wins over personal
            seen.insert(c.name)
            result.append(c)
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Top-level `*.md` files in `dir`. (Namespaced sub-folders are left out so
    /// the app never offers an invocation whose separator it guessed wrong.)
    private static func scan(_ dir: URL, scope: String) -> [SlashCommand] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { $0.pathExtension == "md" }.map {
            SlashCommand(name: $0.deletingPathExtension().lastPathComponent,
                         description: description(of: $0), scope: scope)
        }
    }

    /// A short description from the file's `description:` frontmatter, else its
    /// first non-empty line.
    private static func description(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        if text.hasPrefix("---") {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                if let r = line.range(of: #"^\s*description\s*:\s*"#, options: .regularExpression) {
                    let v = String(line[r.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !v.isEmpty { return v }
                }
            }
        }
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
    }
}
