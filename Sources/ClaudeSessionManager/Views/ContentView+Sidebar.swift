import SwiftUI
import AppKit

extension ContentView {
    // MARK: - Sidebar

    var sidebar: some View {
        Group {
            switch store.viewMode {
            case .sessions: sessionsList
            case .skills: skillsList
            case .trash: trashList
            }
        }
        .safeAreaInset(edge: .top) { modeTabs }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var modeTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("View", selection: $store.viewMode) {
                    Text("Sessions").tag(ViewMode.sessions)
                    Text("Skills\(skills.skills.isEmpty ? "" : " (\(skills.skills.count))")").tag(ViewMode.skills)
                    Text("Trash\(store.trashEntries.isEmpty ? "" : " (\(store.trashEntries.count))")").tag(ViewMode.trash)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if store.viewMode == .sessions { organizationPicker }
                RefreshButton { refreshCurrentTab() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
    }

    private func refreshCurrentTab() {
        switch store.viewMode {
        case .sessions: Task { await store.reload() }
        case .skills: skills.load()
        case .trash: Task { await store.loadTrash() }
        }
    }

    // MARK: - Sessions list (groups / projects → sessions, sectioned)

    private var sessionsList: some View {
        List(selection: $selectedSessions) {
            ForEach(store.sidebarItems) { item in
                switch item {
                case .section(let section):
                    Section {
                        sessionRows(section)
                    } header: {
                        sectionHeader(section)
                    }
                case .category(let category):
                    Section {
                        if !collapsedSections.contains(category.id) {
                            ForEach(category.sections) { section in
                                // A nested section's header is a plain (untagged,
                                // so unselectable) row; its sessions sit indented below.
                                sectionHeader(section, nested: true)
                                sessionRows(section)
                                    .padding(.leading, 14)
                            }
                        }
                    } header: {
                        categoryHeader(category)
                    }
                }
            }
        }
        // Selection-aware menu: right-clicking inside a multi-selection keeps the
        // whole selection (right-clicking an unselected row selects just it), so
        // "Move N to Trash" acts on every selected session, not only the clicked one.
        .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
            rowMenu(for: ids)
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

    @ViewBuilder
    private func sessionRows(_ section: SessionSection) -> some View {
        if !collapsedSections.contains(section.id) {
            ForEach(section.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
            }
        }
    }

    private func toggleCollapsed(_ id: String) {
        withAnimation(.easeInOut(duration: 0.12)) {
            if collapsedSections.contains(id) { collapsedSections.remove(id) }
            else { collapsedSections.insert(id) }
        }
    }

    private func categoryHeader(_ category: SessionCategory) -> some View {
        let collapsed = collapsedSections.contains(category.id)
        return Button { toggleCollapsed(category.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text(category.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(category.sessionCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Category · \(category.sections.count) groups/projects")
        .contextMenu {
            Button("Rename Category…") { groupSheet = .renameCategory(category.name) }
            // Also reachable here (not only from each nested header) so a
            // section can always be taken back out.
            Menu("Remove from Category") {
                ForEach(category.sections) { section in
                    Button(section.name) { store.moveSection(section.id, toCategory: nil) }
                }
            }
            Divider()
            Button("Delete Category", role: .destructive) { store.deleteCategory(category.name) }
        }
    }

    private func sectionHeader(_ section: SessionSection, nested: Bool = false) -> some View {
        let collapsed = collapsedSections.contains(section.id)
        return Button { toggleCollapsed(section.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: sectionIcon(section.kind))
                    .foregroundStyle(.secondary)
                Text(section.name)
                    .font(nested ? .callout.weight(.medium) : nil)
                    .foregroundStyle(nested ? .secondary : .primary)
                    .lineLimit(1)
                if case .project = section.kind, let host = section.sessions.first?.remoteDisplayName {
                    Label(host, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Text("\(section.sessions.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sectionHelp(section))
        .contextMenu { sectionMenu(section) }
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

    /// "Move to Category" submenu for a group / project section.
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

    // MARK: - Skills list

    private var filteredSkills: [SkillInfo] {
        let q = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skills.skills }
        return skills.skills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var skillsList: some View {
        List(selection: $selectedSkill) {
            ForEach(filteredSkills) { skill in
                SkillRow(skill: skill)
                    .tag(skill.id)
                    .contextMenu {
                        if skill.isReadOnly {
                            Button("Reveal in Finder") { skills.revealInFinder(skill) }
                        } else {
                            Button("Edit SKILL.md") { skills.openInEditor(skill) }
                            Button("Reveal in Finder") { skills.revealInFinder(skill) }
                            Divider()
                            Button(skill.isSymlink ? "Remove Link" : "Move to Trash", role: .destructive) {
                                removeSkillTarget = skill
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if skills.skills.isEmpty {
                ContentUnavailableView_Compat(
                    title: "No skills",
                    systemImage: "wand.and.stars",
                    message: "Add a skill with ＋, or drop one into ~/.claude/skills."
                )
            }
        }
    }

    // MARK: - Trash list

    private var trashList: some View {
        List(selection: $selectedTrash) {
            ForEach(store.filteredTrash) { entry in
                TrashRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Recover") { store.recover(entry) }
                        Divider()
                        Button("Reveal in Finder") {
                            SessionActions.revealInFinder(entry.summary)
                        }
                        Button("Delete Permanently", role: .destructive) { purgeTarget = entry }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.trashEntries.isEmpty {
                ContentUnavailableView_Compat(
                    title: "Trash is empty",
                    systemImage: "trash",
                    message: "Deleted sessions show up here and can be recovered."
                )
            }
        }
    }

    // MARK: - Footer

    /// One consistent single-row footer used by every tab so they stay aligned:
    /// a summary label on the left, an optional action on the right. Paths
    /// (sessions root, skills folder) live in the ⋯ Options menu instead.
    @ViewBuilder
    private func footerBar<Trailing: View>(
        summary: String, help: String = "",
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(help)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var footer: some View {
        switch store.viewMode {
        case .sessions:
            footerBar(summary: sessionsCountLabel,
                      help: store.hiddenCount > 0
                            ? "Temporary and archived sessions are hidden. Show them from the ⋯ menu." : "")
        case .skills:
            footerBar(summary: skillsCountLabel)
        case .trash:
            footerBar(summary: "\(store.trashEntries.count) in Trash") {
                Button(role: .destructive) { confirmEmpty = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(store.trashEntries.isEmpty)
                    .help("Empty Trash")
            }
        }
    }

    private var sessionsCountLabel: String {
        let sections = store.sections
        let listed = sections.reduce(0) { $0 + $1.sessions.count }
        let groupCount = sections.filter { $0.groupName != nil }.count
        var s = store.organization == .groups
            ? "\(groupCount) groups · \(listed) sessions"
            : "\(sections.count) projects · \(listed) sessions"
        let remote = sections.flatMap(\.sessions).filter(\.isRemote).count
        if remote > 0 {
            s += " · \(remote) remote"
        }
        if store.hiddenCount > 0 {
            s += " · \(store.hiddenCount) hidden"
        }
        return s
    }

    private var skillsCountLabel: String {
        var s = "\(skills.skills.count) skills"
        let remote = skills.skills.filter(\.isRemote).count
        if remote > 0 {
            s += " · \(remote) remote"
        }
        return s
    }
}
