import Foundation

/// A slash command offered in the conversation input. Covers three sources:
/// the built-in commands that actually work in headless `claude -p`, the user's
/// and project's custom commands, and any installed plugin commands.
struct SlashCommand: Identifiable, Hashable {
    let name: String            // without the leading slash
    let description: String?
    let scope: Scope

    enum Scope: String { case builtin = "Built-in", personal = "Personal", project = "Project", plugin = "Plugin" }

    var id: String { scope.rawValue + "/" + name }
    var invocation: String { "/" + name }

    /// SF Symbol hinting the command's source.
    var icon: String {
        switch scope {
        case .builtin: return "sparkle"
        case .personal: return "person"
        case .project: return "folder"
        case .plugin: return "puzzlepiece.extension"
        }
    }
}

/// Lists the slash commands available to a session. Headless `claude -p "/name"`
/// resolves custom and plugin commands exactly like the interactive CLI, so the
/// app just surfaces them; the built-ins are the subset verified to work in
/// `-p` (interactive-only ones like /help, /clear, /memory are omitted so the
/// menu never offers something that answers "isn't available in this
/// environment").
enum SlashCommandCatalog {
    /// Built-ins that return useful output in headless mode (verified), plus the
    /// standard prompt-driven action commands that run in a real project.
    static let builtins: [SlashCommand] = [
        .init(name: "context", description: "Show context-window usage", scope: .builtin),
        .init(name: "cost", description: "Show token usage and cost this session", scope: .builtin),
        .init(name: "usage", description: "Show your subscription usage and limits", scope: .builtin),
        .init(name: "model", description: "Show the current model", scope: .builtin),
        .init(name: "mcp", description: "List configured MCP servers", scope: .builtin),
        .init(name: "agents", description: "Show agents information", scope: .builtin),
        .init(name: "review", description: "Review the current changes", scope: .builtin),
        .init(name: "init", description: "Create a CLAUDE.md for this project", scope: .builtin),
    ]

    static func commands(projectDir: String?) -> [SlashCommand] {
        var custom: [SlashCommand] = []
        if let projectDir, !projectDir.isEmpty {
            custom += scan(URL(fileURLWithPath: projectDir).appendingPathComponent(".claude/commands"),
                           scope: .project)
        }
        custom += scan(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/commands"),
                       scope: .personal)
        custom += pluginCommands()

        // De-dupe custom by name (project shadows personal shadows plugin), sort.
        var seen = Set<String>()
        let customUnique = custom.filter { seen.insert($0.name).inserted }
            .sorted { $0.name < $1.name }

        // Built-ins last, minus any a custom command already defines.
        let customNames = Set(customUnique.map(\.name))
        let builtinsUnique = builtins.filter { !customNames.contains($0.name) }
        return customUnique + builtinsUnique
    }

    /// Top-level `*.md` files in a `.claude/commands` directory.
    private static func scan(_ dir: URL, scope: SlashCommand.Scope) -> [SlashCommand] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { $0.pathExtension == "md" }.map {
            SlashCommand(name: $0.deletingPathExtension().lastPathComponent,
                         description: description(of: $0), scope: scope)
        }
    }

    /// Commands contributed by installed plugins (`<installPath>/commands/*.md`).
    private static func pluginCommands() -> [SlashCommand] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }

        var out: [SlashCommand] = []
        for value in plugins.values {
            guard let installs = value as? [[String: Any]] else { continue }
            for install in installs {
                guard let path = install["installPath"] as? String else { continue }
                let dir = URL(fileURLWithPath: path).appendingPathComponent("commands")
                out += scan(dir, scope: .plugin)
            }
        }
        return out
    }

    /// A short description from `description:` frontmatter, else the first
    /// non-empty line of the command file.
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
