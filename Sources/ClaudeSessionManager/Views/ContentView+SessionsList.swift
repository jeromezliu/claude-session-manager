import SwiftUI
import AppKit

/// Three-column layout, following the HIG's "no more than two levels in a
/// sidebar" (sessions live in the middle column, like messages in Mail):
///
///     Sidebar                     │ Sessions of the selection │ Detail
///       All Sessions · Skills · Trash
///     CATEGORIES
///       ▾ ▤ Customers         71  ← category: disclosure row, selectable
///           ● Baidu           20  ← group (colored dot, like Finder tags)
///     GROUPS
///           ● Dev              5
///     PROJECTS / UNGROUPED
///           ▢ Triage          50  ← project folder
///
/// Drag & drop: sessions from the middle column onto a group (file them),
/// the Ungrouped header (unfile them) or Trash; groups/projects onto a
/// category or any row inside one (move in), or onto the Groups/Projects
/// header (move back out).
extension ContentView {

    // MARK: - Sidebar

    var sidebarList: some View {
        let items = store.sidebarItems
        let categories = items.compactMap { item -> SessionCategory? in
            if case .category(let c) = item { return c }
            return nil
        }
        let loose = items.compactMap { item -> SessionSection? in
            if case .section(let s) = item { return s }
            return nil
        }
        let looseGroups = loose.filter { $0.groupName != nil }
        let looseProjects = loose.filter { $0.groupName == nil }
        let byGroup = store.organization == .groups

        return List(selection: $sidebarSelection) {
            Section {
                navRow(.allSessions, "All Sessions", icon: "tray.full", count: store.visibleSessions.count)
                navRow(.skills, "Skills", icon: "wand.and.stars", count: skills.skills.count)
                navRow(.trash, "Trash", icon: "trash", count: store.trashEntries.count)
                    .dropDestination(for: String.self) { items, _ in dropOnTrash(items) }
                        isTargeted: { setDropTarget("nav:trash", $0) }
            }
            if !categories.isEmpty {
                sidebarSection(id: "top:categories", title: "Categories", drop: nil) {
                    ForEach(categories) { categoryRow($0) }
                }
            }
            if !looseGroups.isEmpty {
                sidebarSection(id: "top:groups", title: "Groups", drop: .topLevel) {
                    ForEach(looseGroups) { sectionRow($0) }
                }
            }
            if !looseProjects.isEmpty {
                sidebarSection(id: "top:projects", title: byGroup ? "Ungrouped" : "Projects",
                               drop: byGroup ? .ungrouped : .topLevel) {
                    ForEach(looseProjects) { sectionRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func navRow(_ selection: SidebarSelection, _ title: String, icon: String, count: Int) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(selection)
            .background(dropHighlight(selection == .trash ? "nav:trash" : ""))
    }

    /// What dropping onto a sidebar section header does.
    enum HeaderDrop {
        /// Move dropped groups/projects out of their category.
        case topLevel
        /// As `.topLevel`, and also take dropped sessions out of their group.
        case ungrouped
    }

    /// A collapsible sidebar section whose header can be a drop target.
    @ViewBuilder
    private func sidebarSection<Content: View>(
        id: String, title: String, drop: HeaderDrop?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let header = Text(title)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(dropHighlight(id))
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let drop else { return false }
                return handleHeaderDrop(items, drop)
            } isTargeted: { setDropTarget(id, $0) }
        if #available(macOS 14.0, *) {
            Section(isExpanded: expansion(id)) { content() } header: { header }
        } else {
            Section { content() } header: { header }
        }
    }

    /// A category: a bold, filled-icon disclosure row above its groups and
    /// projects; selecting it lists all of their sessions.
    private func categoryRow(_ category: SessionCategory) -> some View {
        DisclosureGroup(isExpanded: expansion(category.id)) {
            ForEach(category.sections) { sectionRow($0) }
        } label: {
            Label {
                Text(category.name).fontWeight(.semibold)
            } icon: {
                Image(systemName: "rectangle.stack.fill")
            }
            .badge(category.sessionCount)
            .tag(SidebarSelection.category(category.name))
            .background(dropHighlight(category.id))
            .dropDestination(for: String.self) { items, _ in
                dropSections(items, intoCategory: category.name)
            } isTargeted: { setDropTarget(category.id, $0) }
            .contextMenu { categoryHeaderMenu(category) }
            .help("Category · \(category.sections.count) groups/projects")
        }
    }

    /// A group (colored dot) or project (folder) row.
    private func sectionRow(_ section: SessionSection) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(section.name).lineLimit(1)
                if case .project = section.kind, section.sessions.first?.remoteDisplayName != nil {
                    Image(systemName: "network")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            sectionIcon(section)
        }
        .badge(section.sessions.count)
        .tag(SidebarSelection.section(section.id))
        .background(dropHighlight(section.id))
        .draggable(DragPayload.section(section.id).encoded)
        .dropDestination(for: String.self) { items, _ in
            handleRowDrop(items, onto: section)
        } isTargeted: { setDropTarget(section.id, $0) }
        .contextMenu { sectionMenu(section) }
        .help(sectionHelp(section))
    }

    @ViewBuilder
    private func sectionIcon(_ section: SessionSection) -> some View {
        switch section.kind {
        case .group:
            // Finder-tag style: a small dot in a stable per-group color.
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(GroupColor.color(for: section.name))
        case .project:
            Image(systemName: "folder")
        case .scratch:
            Image(systemName: "tray")
        }
    }

    private func sectionHelp(_ section: SessionSection) -> String {
        switch section.kind {
        case .group(let desktop, _):
            return desktop ? "Group from Claude Desktop — rename or delete it there" : "Group created in this app"
        case .project: return section.path ?? section.name
        case .scratch: return "Claude Desktop sessions started without a project folder"
        }
    }

    // MARK: - Middle column: sessions of the selection

    var sessionsContent: some View {
        let selection = sidebarSelection ?? .allSessions
        let listed = store.listedSessions(for: selection)
        return List(selection: $selectedSessions) {
            ForEach(listed) { session in
                SessionRow(session: session, showsProject: !isSingleProject(selection),
                           groupName: showsGroup(selection) ? store.group(of: session.id) : nil)
                    .tag(session.id)
                    .draggable(DragPayload.sessions(dragIDs(for: session)).encoded)
                    .contextMenu { rowMenu(for: menuIDs(for: session)) }
            }
        }
        .listStyle(.inset)
        .navigationTitle(store.title(for: selection))
        .navigationSubtitle("\(listed.count) sessions")
        .overlay {
            if store.isLoading && store.sessions.isEmpty {
                ProgressView("Scanning…")
            } else if store.sessions.isEmpty {
                ContentUnavailableView_Compat(
                    title: "No sessions found", systemImage: "tray",
                    message: "Nothing under \(store.rootPath)")
            } else if listed.isEmpty {
                ContentUnavailableView_Compat(
                    title: store.isSearching ? "No matches" : "No sessions",
                    systemImage: store.isSearching ? "magnifyingglass" : "tray",
                    message: store.isSearching ? "Nothing matches “\(store.searchText)”." : "Drag sessions here from another group.")
            }
        }
    }

    /// Inside a group the dot would repeat the title; elsewhere it tells
    /// where a session is filed.
    private func showsGroup(_ selection: SidebarSelection) -> Bool {
        guard store.organization == .groups else { return false }
        if !store.isSearching, case .section(let id) = selection { return !id.hasPrefix("group:") }
        return true
    }

    /// A project row's sessions all share one project, so rows needn't repeat it.
    private func isSingleProject(_ selection: SidebarSelection) -> Bool {
        guard !store.isSearching, case .section(let id) = selection else { return false }
        return id.hasPrefix("project:")
    }

    // MARK: - Expansion (persisted)

    private var collapsedIDs: Set<String> {
        Set(collapsedSidebarRaw.split(separator: "\n").map(String.init))
    }

    /// Expanded unless the user collapsed it.
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedIDs.contains(id) },
            set: { expanded in
                var ids = collapsedIDs
                if expanded { ids.remove(id) } else { ids.insert(id) }
                collapsedSidebarRaw = ids.sorted().joined(separator: "\n")
            })
    }

    // MARK: - Drag & drop

    /// Plain-text drag payload, so it needs no custom UTType registration.
    enum DragPayload {
        case sessions([String])
        case section(String)

        private static let sessionsPrefix = "csm-sessions:"
        private static let sectionPrefix = "csm-section:"

        var encoded: String {
            switch self {
            case .sessions(let ids): return Self.sessionsPrefix + ids.joined(separator: "\n")
            case .section(let id): return Self.sectionPrefix + id
            }
        }

        init?(_ string: String) {
            if string.hasPrefix(Self.sessionsPrefix) {
                let ids = string.dropFirst(Self.sessionsPrefix.count).split(separator: "\n").map(String.init)
                guard !ids.isEmpty else { return nil }
                self = .sessions(ids)
            } else if string.hasPrefix(Self.sectionPrefix) {
                self = .section(String(string.dropFirst(Self.sectionPrefix.count)))
            } else {
                return nil
            }
        }
    }

    /// Dragging a selected session drags the whole selection.
    private func dragIDs(for session: SessionSummary) -> [String] {
        selectedSessions.contains(session.id) ? selectedSessions.sorted() : [session.id]
    }

    /// Right-clicking a selected session acts on the whole selection.
    private func menuIDs(for session: SessionSummary) -> Set<String> {
        selectedSessions.contains(session.id) ? selectedSessions : [session.id]
    }

    private func handleRowDrop(_ items: [String], onto target: SessionSection) -> Bool {
        var handled = false
        for payload in items.compactMap(DragPayload.init) {
            switch payload {
            case .sessions(let ids):
                // Sessions can be filed under a group; a project is where the
                // file lives, so dropping onto one means nothing.
                guard let group = target.groupName else { continue }
                store.assign(Set(ids), toGroup: group)
                handled = true
            case .section(let id) where id != target.id:
                // Onto a row inside a category = into that category.
                store.moveSection(id, toCategory: store.category(ofSection: target.id))
                handled = true
            default:
                continue
            }
        }
        return handled
    }

    private func dropSections(_ items: [String], intoCategory name: String) -> Bool {
        var handled = false
        for case .section(let id) in items.compactMap(DragPayload.init) {
            store.moveSection(id, toCategory: name)
            handled = true
        }
        return handled
    }

    private func handleHeaderDrop(_ items: [String], _ drop: HeaderDrop) -> Bool {
        var handled = false
        for payload in items.compactMap(DragPayload.init) {
            switch (payload, drop) {
            case (.section(let id), _):
                store.moveSection(id, toCategory: nil); handled = true
            case (.sessions(let ids), .ungrouped):
                store.assign(Set(ids), toGroup: nil); handled = true
            default:
                continue
            }
        }
        return handled
    }

    /// Dropping sessions on Trash asks first, like the Delete button.
    private func dropOnTrash(_ items: [String]) -> Bool {
        let ids = items.compactMap(DragPayload.init).flatMap { payload -> [String] in
            if case .sessions(let ids) = payload { return ids }
            return []
        }
        guard !ids.isEmpty else { return false }
        selectedSessions = Set(ids)
        if ids.count == 1, let session = session(for: ids[0]) {
            deleteTarget = session
        } else {
            confirmDeleteSelection = true
        }
        return true
    }

    private func setDropTarget(_ id: String, _ targeted: Bool) {
        if targeted { dropTargetID = id } else if dropTargetID == id { dropTargetID = nil }
    }

    private func dropHighlight(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(!id.isEmpty && dropTargetID == id ? 0.25 : 0))
    }

    // MARK: - Menus

    @ViewBuilder
    private func sectionMenu(_ section: SessionSection) -> some View {
        categoryMenu(for: section)
        Divider()
        if case .group(let desktop, _) = section.kind {
            if desktop {
                Button("Managed in Claude Desktop") {}.disabled(true)
            } else {
                Button("Rename Group…") { groupSheet = .rename(section.name) }
                Button("Delete Group", role: .destructive) { store.deleteGroup(section.name) }
            }
        } else if let path = section.path {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    /// "Move to Category" submenu for a group / project row.
    private func categoryMenu(for section: SessionSection) -> some View {
        let current = store.category(ofSection: section.id)
        return Menu("Move to Category") {
            ForEach(store.localMeta.categories, id: \.self) { name in
                Button {
                    store.moveSection(section.id, toCategory: name)
                } label: {
                    if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !store.localMeta.categories.isEmpty { Divider() }
            Button("New Category…") { groupSheet = .createCategory(section.id) }
            if current != nil {
                Divider()
                Button("Remove from Category") { store.moveSection(section.id, toCategory: nil) }
            }
        }
    }

    @ViewBuilder
    private func categoryHeaderMenu(_ category: SessionCategory) -> some View {
        Button("Rename Category…") { groupSheet = .renameCategory(category.name) }
        Menu("Remove from Category") {
            ForEach(category.sections) { section in
                Button(section.name) { store.moveSection(section.id, toCategory: nil) }
            }
        }
        Divider()
        Button("Delete Category", role: .destructive) { store.deleteCategory(category.name) }
    }

    /// Group / project switch (sessions toolbar).
    var organizationPicker: some View {
        Menu {
            Picker("Organize Sessions", selection: $store.organization) {
                ForEach(SessionOrganization.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Organize", systemImage: store.organization == .groups ? "circle.grid.2x1" : "folder")
        }
        .help("Organize the sidebar: \(store.organization.label)")
    }
}

/// Stable Finder-tag-like color per group name.
enum GroupColor {
    private static let palette: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .indigo, .brown, .cyan]

    static func color(for name: String) -> Color {
        // djb2: stable across launches (unlike String.hashValue).
        let h = name.unicodeScalars.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return palette[Int(h % UInt64(palette.count))]
    }
}
