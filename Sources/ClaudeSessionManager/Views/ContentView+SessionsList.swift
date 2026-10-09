import SwiftUI
import AppKit

/// The Sessions tab sidebar, laid out like a Finder/Mail sidebar:
///
///     CUSTOMERS                ← category (sidebar section header, collapsible)
///       ▸ 🏷 Baidu        20   ← group / project (disclosure row)
///           session            ← sessions (selectable rows)
///     GROUPS / PROJECTS        ← everything not filed under a category
///
/// Drag & drop: sessions onto a group row (file them there) or onto the
/// "Ungrouped" header (take them out of their group); group/project rows
/// onto a category header or any row inside a category (move into it), or
/// onto the "Groups"/"Projects" header (back to the top level).
extension ContentView {

    // MARK: - Layout

    var sessionsList: some View {
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

        return List(selection: $selectedSessions) {
            ForEach(categories) { category in
                sidebarSection(id: category.id, title: category.name,
                               drop: .category(category.name)) {
                    ForEach(category.sections) { sectionRow($0) }
                } menu: {
                    categoryHeaderMenu(category)
                }
            }
            if !looseGroups.isEmpty {
                sidebarSection(id: "top:groups", title: categories.isEmpty ? "Groups" : "Other Groups",
                               drop: .topLevel) {
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
        .overlay {
            if store.isLoading && store.sessions.isEmpty {
                ProgressView("Scanning…")
            } else if store.sessions.isEmpty {
                ContentUnavailableView_Compat(
                    title: "No sessions found",
                    systemImage: "tray",
                    message: "Nothing under \(store.rootPath)"
                )
            }
        }
    }

    /// What dropping onto a sidebar section header does.
    enum HeaderDrop {
        /// Move dropped groups/projects into this category.
        case category(String)
        /// Move dropped groups/projects out of their category.
        case topLevel
        /// As `.topLevel`, and also take dropped sessions out of their group.
        case ungrouped
    }

    /// A collapsible sidebar section with a drop-target header.
    @ViewBuilder
    private func sidebarSection<Content: View, Menu: View>(
        id: String, title: String, drop: HeaderDrop,
        @ViewBuilder content: () -> Content,
        @ViewBuilder menu: () -> Menu = { EmptyView() }
    ) -> some View {
        let header = Text(title)
            .lineLimit(1)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(dropHighlight(id))
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                handleHeaderDrop(items, drop)
            } isTargeted: { setDropTarget(id, $0) }
            .contextMenu { menu() }
        if #available(macOS 14.0, *) {
            Section(isExpanded: expansion(id)) { content() } header: { header }
        } else {
            Section { content() } header: { header }
        }
    }

    /// A group or project: a disclosure row whose children are its sessions.
    private func sectionRow(_ section: SessionSection) -> some View {
        DisclosureGroup(isExpanded: expansion(section.id)) {
            ForEach(section.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
                    .draggable(DragPayload.sessions(dragIDs(for: session)).encoded)
                    .contextMenu { rowMenu(for: menuIDs(for: session)) }
            }
        } label: {
            sectionLabel(section)
                .draggable(DragPayload.section(section.id).encoded)
                .dropDestination(for: String.self) { items, _ in
                    handleRowDrop(items, onto: section)
                } isTargeted: { setDropTarget(section.id, $0) }
                .contextMenu { sectionMenu(section) }
                .help(sectionHelp(section))
        }
    }

    private func sectionLabel(_ section: SessionSection) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(section.name).lineLimit(1)
            } icon: {
                Image(systemName: sectionIcon(section.kind))
            }
            if case .project = section.kind, let host = section.sessions.first?.remoteDisplayName {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("On \(host)")
            }
            Spacer(minLength: 4)
            Text("\(section.sessions.count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(dropHighlight(section.id))
        .contentShape(Rectangle())
    }

    private func sectionIcon(_ kind: SessionSection.Kind) -> String {
        switch kind {
        case .group: return "tag"
        case .project: return "folder"
        case .scratch: return "tray"
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

    // MARK: - Expansion (persisted)

    private var collapsedIDs: Set<String> {
        Set(collapsedSidebarRaw.split(separator: "\n").map(String.init))
    }

    /// Expanded unless the user collapsed it; searching shows everything.
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !store.searchText.isEmpty || !collapsedIDs.contains(id) },
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

    private func handleHeaderDrop(_ items: [String], _ drop: HeaderDrop) -> Bool {
        var handled = false
        for payload in items.compactMap(DragPayload.init) {
            switch (payload, drop) {
            case (.section(let id), .category(let name)):
                store.moveSection(id, toCategory: name); handled = true
            case (.section(let id), .topLevel), (.section(let id), .ungrouped):
                store.moveSection(id, toCategory: nil); handled = true
            case (.sessions(let ids), .ungrouped):
                store.assign(Set(ids), toGroup: nil); handled = true
            default:
                continue
            }
        }
        return handled
    }

    private func setDropTarget(_ id: String, _ targeted: Bool) {
        if targeted { dropTargetID = id } else if dropTargetID == id { dropTargetID = nil }
    }

    private func dropHighlight(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(dropTargetID == id ? 0.25 : 0))
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

    /// Group / project switch shown next to the tabs on the Sessions tab.
    var organizationPicker: some View {
        Menu {
            Picker("Organize Sessions", selection: $store.organization) {
                ForEach(SessionOrganization.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: store.organization == .groups ? "tag" : "folder")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Organize sessions: \(store.organization.label)")
    }
}
