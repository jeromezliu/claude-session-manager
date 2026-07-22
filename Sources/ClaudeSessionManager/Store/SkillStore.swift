import Foundation
import AppKit

/// Manages Claude skills under `~/.claude/skills`: lists them, and supports
/// creating, importing, and removing skills. Also lists each enabled remote
/// host's skills from its rsync mirror (read-only). Auto-refreshes on disk
/// changes.
@MainActor
final class SkillStore: ObservableObject {
    @Published var skills: [SkillInfo] = []
    @Published var errorMessage: String?

    private var watcher: DirectoryWatcher?
    /// One watcher per enabled host's mirrored skills folder, keyed by host id.
    private var remoteWatchers: [String: DirectoryWatcher] = [:]
    private weak var remoteHosts: RemoteHostStore?

    init(remoteHosts: RemoteHostStore? = nil) {
        self.remoteHosts = remoteHosts
    }

    var skillsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills")
    }

    func start() {
        load()
        watcher = DirectoryWatcher(path: skillsDir.path) { [weak self] in self?.load() }
    }

    func load() {
        let dir = skillsDir
        var all = Self.scan(dir, source: .personal)
        all += Self.scanInstalledPlugins()
        if let remoteHosts {
            for host in remoteHosts.hosts where host.enabled {
                all += Self.scan(remoteHosts.skillsCacheDir(for: host), source: .remote(host.displayName))
            }
        }
        skills = all.sorted { a, b in
            // personal first, then plugin, then remote; by name within each
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        ensureRemoteWatchers()
    }

    /// Watch each enabled host's mirrored skills folder so the list refreshes
    /// when a sync lands new or changed skills.
    private func ensureRemoteWatchers() {
        guard let remoteHosts else { return }
        var wanted: [String: String] = [:]
        for host in remoteHosts.hosts where host.enabled {
            wanted[host.id] = remoteHosts.skillsCacheDir(for: host).path
        }
        for key in remoteWatchers.keys where wanted[key] == nil {
            remoteWatchers[key] = nil
        }
        for (key, path) in wanted where remoteWatchers[key] == nil {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            remoteWatchers[key] = DirectoryWatcher(path: path) { [weak self] in self?.load() }
        }
    }

    nonisolated static func scan(_ dir: URL, source: SkillSource) -> [SkillInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { SkillInfo.load(entry: $0, source: source) }
    }

    /// Skills from installed plugins, per ~/.claude/plugins/installed_plugins.json.
    nonisolated static func scanInstalledPlugins() -> [SkillInfo] {
        let fm = FileManager.default
        let jsonURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }

        var result: [SkillInfo] = []
        for (key, value) in plugins {
            let pluginName = String(key.split(separator: "@").first ?? Substring(key))
            let entries = (value as? [[String: Any]]) ?? []
            for entry in entries {
                guard let installPath = entry["installPath"] as? String else { continue }
                let skillsDir = URL(fileURLWithPath: installPath).appendingPathComponent("skills")
                result += scan(skillsDir, source: .plugin(pluginName))
            }
        }
        return result
    }

    // MARK: - Mutations

    /// Create a new skill scaffold (`<name>/SKILL.md`) and return it.
    @discardableResult
    func createSkill(named rawName: String) -> SkillInfo? {
        let slug = Self.slug(rawName)
        guard !slug.isEmpty else { errorMessage = "Please enter a skill name."; return nil }
        let fm = FileManager.default
        let dir = skillsDir.appendingPathComponent(slug)
        guard !fm.fileExists(atPath: dir.path) else {
            errorMessage = "A skill named “\(slug)” already exists."
            return nil
        }
        let template = """
        ---
        name: \(slug)
        description: One line on what this skill does and when Claude should use it.
        ---

        # \(rawName)

        Describe the workflow here. Claude reads this file when the skill is invoked.
        """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try template.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        load()
        return skills.first { $0.folderName == slug }
    }

    /// Import an existing skill folder (must contain SKILL.md) by copying it in.
    @discardableResult
    func importSkill(from source: URL) -> SkillInfo? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            errorMessage = "That folder has no SKILL.md."
            return nil
        }
        let dest = skillsDir.appendingPathComponent(source.lastPathComponent)
        guard !fm.fileExists(atPath: dest.path) else {
            errorMessage = "A skill named “\(source.lastPathComponent)” already exists."
            return nil
        }
        do {
            try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        load()
        return skills.first { $0.folderName == source.lastPathComponent }
    }

    /// Remove a skill: trash the folder, or (for a symlink) just remove the link.
    func remove(_ skill: SkillInfo) {
        guard !skill.isManaged else {
            errorMessage = "Plugin skills are managed by their plugin and can't be removed here."
            return
        }
        guard !skill.isRemote else {
            errorMessage = "Remote skills are synced from their host — remove them there."
            return
        }
        do {
            try FileManager.default.trashItem(at: skill.entryURL, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        load()
    }

    func revealInFinder(_ skill: SkillInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([skill.skillFileURL])
    }

    func openInEditor(_ skill: SkillInfo) {
        NSWorkspace.shared.open(skill.skillFileURL)
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        // collapse repeated dashes and trim
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
