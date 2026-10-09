import Foundation

/// How the sessions sidebar is organized.
enum SessionOrganization: String, CaseIterable {
    /// Groups first (desktop + local), then ungrouped sessions by project.
    case groups
    /// Every session under its project (worktrees folded into their repo).
    case projects

    var label: String {
        switch self {
        case .groups: return "By Group"
        case .projects: return "By Project"
        }
    }
}

/// Groups and titles the user set in this app. Desktop groups are read-only
/// here, so this layer sits on top of them: a local assignment overrides the
/// desktop one, and a group with the same name as a desktop group is the
/// same group.
struct LocalSessionMeta: Codable, Equatable {
    /// Groups created in this app, in creation order.
    var groups: [String] = []
    /// Session id → group name. `""` means "explicitly ungrouped", which
    /// hides a desktop assignment.
    var assignments: [String: String] = [:]
    /// Session id → title set by Rename (wins over the desktop title).
    var titles: [String: String] = [:]
    /// Top-level categories, in creation order. A category holds groups and
    /// projects (by `SessionSection.id`), not individual sessions.
    var categories: [String] = []
    /// `SessionSection.id` → category name.
    var categoryOfSection: [String: String] = [:]

    init() {}

    /// Tolerates files written before a field existed (missing keys → empty),
    /// so upgrading never discards the user's groups.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        assignments = try c.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        titles = try c.decodeIfPresent([String: String].self, forKey: .titles) ?? [:]
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        categoryOfSection = try c.decodeIfPresent([String: String].self, forKey: .categoryOfSection) ?? [:]
    }

    static var fileURL: URL { AppPaths.support.appendingPathComponent("session-meta.json") }

    static func load(from url: URL = fileURL) -> LocalSessionMeta {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(LocalSessionMeta.self, from: data) else { return LocalSessionMeta() }
        return meta
    }

    func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// One sidebar section: a group, a project, or the desktop's scratch sessions.
struct SessionSection: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `desktop`: the group exists in Claude Desktop (read-only here);
        /// `local`: it was created in this app (can be renamed/deleted).
        case group(desktop: Bool, local: Bool)
        case project
        case scratch
    }

    let id: String
    let name: String
    /// Folder shown as the header's tooltip (projects only).
    let path: String?
    let kind: Kind
    var sessions: [SessionSummary]

    var groupName: String? {
        if case .group = kind { return name }
        return nil
    }
}

/// A top-level category and the groups/projects filed under it.
struct SessionCategory: Identifiable, Hashable {
    var id: String { "category:\(name)" }
    let name: String
    var sections: [SessionSection]

    var sessionCount: Int { sections.reduce(0) { $0 + $1.sessions.count } }
}

/// One top-level sidebar entry.
enum SidebarItem: Identifiable, Hashable {
    case category(SessionCategory)
    case section(SessionSection)

    var id: String {
        switch self {
        case .category(let c): return c.id
        case .section(let s): return s.id
        }
    }
}

/// Pure sidebar layout: everything here is derived from its inputs, so the
/// store can recompute it whenever sessions, groups or the mode change.
enum SessionGrouping {

    /// The group a session is in: a local assignment wins over the desktop's.
    static func group(of id: String, local: LocalSessionMeta, desktop: DesktopSnapshot) -> String? {
        if let name = local.assignments[id] { return name.isEmpty ? nil : name }
        return desktop.groupOfSession[id]
    }

    /// All group names in display order: desktop sidebar order, then groups
    /// created here, then any name only reachable through an assignment
    /// (e.g. a desktop group that has since been deleted there).
    static func allGroups(local: LocalSessionMeta, desktop: DesktopSnapshot) -> [String] {
        var names = desktop.groupNames
        for n in local.groups + local.assignments.values.sorted() where !n.isEmpty && !names.contains(n) {
            names.append(n)
        }
        return names
    }

    /// `sessions` must already be filtered and sorted newest first; section
    /// order follows each section's newest session, except groups, which
    /// keep their sidebar order.
    static func sections(for sessions: [SessionSummary], organization: SessionOrganization,
                         local: LocalSessionMeta, desktop: DesktopSnapshot) -> [SessionSection] {
        var grouped: [String: [SessionSummary]] = [:]
        var rest: [SessionSummary] = []
        if organization == .groups {
            for s in sessions {
                if let g = group(of: s.id, local: local, desktop: desktop) { grouped[g, default: []].append(s) }
                else { rest.append(s) }
            }
        } else {
            rest = sessions
        }

        let desktopNames = Set(desktop.groupNames)
        let localNames = Set(local.groups)
        let groupSections = allGroups(local: local, desktop: desktop).compactMap { name -> SessionSection? in
            guard let members = grouped[name], !members.isEmpty else { return nil }
            return SessionSection(id: "group:\(name)", name: name, path: nil,
                                  kind: .group(desktop: desktopNames.contains(name),
                                               local: localNames.contains(name) || !desktopNames.contains(name)),
                                  sessions: members)
        }

        // Projects: keyed by host + folder, so a remote host's projects stay separate.
        var byProject: [String: [SessionSummary]] = [:]
        var order: [String] = []
        for s in rest {
            let key = (s.remoteHostID.map { "\($0):" } ?? "") + (s.isScratch ? "scratch" : s.groupingRoot)
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(s)
        }
        let projectSections = order.map { key -> SessionSection in
            let members = byProject[key]!
            let sample = members[0]
            return SessionSection(id: "project:\(key)", name: sample.projectName,
                                  path: sample.isScratch ? nil : sample.groupingRoot,
                                  kind: sample.isScratch ? .scratch : .project, sessions: members)
        }
        return groupSections + projectSections
    }

    /// Nest `sections` under their categories. Categories come first, in
    /// creation order (empty ones are left out); sections keep their order,
    /// and uncategorized ones follow at the top level.
    static func layout(_ sections: [SessionSection], local: LocalSessionMeta) -> [SidebarItem] {
        var inCategory: [String: [SessionSection]] = [:]
        var topLevel: [SessionSection] = []
        for section in sections {
            if let c = local.categoryOfSection[section.id], local.categories.contains(c) {
                inCategory[c, default: []].append(section)
            } else {
                topLevel.append(section)
            }
        }
        let categories = local.categories.compactMap { name -> SidebarItem? in
            guard let members = inCategory[name], !members.isEmpty else { return nil }
            return .category(SessionCategory(name: name, sections: members))
        }
        return categories + topLevel.map { .section($0) }
    }
}

/// What the sidebar has selected; the middle column lists its sessions.
enum SidebarSelection: Hashable {
    case allSessions
    case skills
    case trash
    case category(String)
    /// A group or project, by `SessionSection.id`.
    case section(String)
}
