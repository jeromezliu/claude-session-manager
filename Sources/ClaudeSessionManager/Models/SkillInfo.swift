import Foundation

/// Where a skill comes from: the user's own folder, or an installed plugin.
enum SkillSource: Hashable, Sendable {
    case personal
    case plugin(String)   // plugin display name
}

/// A Claude skill discovered under `~/.claude/skills` (personal) or an installed
/// plugin's `skills/` folder — a directory (or symlink) with a `SKILL.md`.
struct SkillInfo: Identifiable, Hashable, Sendable {
    var id: String { entryURL.path }

    /// Display name (from frontmatter, else the folder name).
    let name: String
    let description: String
    let source: SkillSource
    /// The entry directly under the skills directory (may be a symlink).
    let entryURL: URL
    /// The resolved `SKILL.md` file.
    let skillFileURL: URL
    let isSymlink: Bool
    let symlinkTarget: String?

    var folderName: String { entryURL.lastPathComponent }

    /// Plugin skills are read-only (managed by the plugin, not this app).
    var isManaged: Bool { if case .plugin = source { return true }; return false }

    var pluginName: String? { if case .plugin(let p) = source { return p }; return nil }

    /// Parse a skill from an entry under a skills directory. Returns nil if it
    /// isn't a skill (no SKILL.md).
    static func load(entry: URL, source: SkillSource = .personal) -> SkillInfo? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: entry.path)
        let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        let target = isLink ? (try? fm.destinationOfSymbolicLink(atPath: entry.path)) : nil

        let resolved = entry.resolvingSymlinksInPath()
        let skillFile = resolved.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillFile.path) else { return nil }

        let (name, desc) = parseFrontmatter(skillFile) ?? (nil, nil)
        return SkillInfo(
            name: name?.isEmpty == false ? name! : entry.lastPathComponent,
            description: desc ?? "",
            source: source,
            entryURL: entry,
            skillFileURL: skillFile,
            isSymlink: isLink,
            symlinkTarget: target
        )
    }

    /// Extract `name` and `description` from the leading `--- ... ---` block.
    private static func parseFrontmatter(_ url: URL) -> (String?, String?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }

        var name: String?
        var desc: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if name == nil, let v = value(of: "name", in: line) { name = v }
            if desc == nil, let v = value(of: "description", in: line) { desc = v }
        }
        return (name, desc)
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var v = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        // Strip matching surrounding quotes; unescape YAML doubled single-quotes.
        if v.count >= 2, let f = v.first, (f == "'" || f == "\""), v.last == f {
            v = String(v.dropFirst().dropLast())
            if f == "'" { v = v.replacingOccurrences(of: "''", with: "'") }
        }
        return v
    }
}
