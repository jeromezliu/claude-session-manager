import SwiftUI

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

    // MARK: - Sessions list (projects → sessions, sectioned)

    private var sessionsList: some View {
        List(selection: $selectedSessions) {
            ForEach(store.filteredGroups) { group in
                Section {
                    if !collapsedProjects.contains(group.id) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                        }
                    }
                } header: {
                    projectHeader(group)
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
            if store.isLoading && store.groups.isEmpty {
                ProgressView("Scanning…")
            } else if store.groups.isEmpty {
                ContentUnavailableView_Compat(
                    title: "No sessions found",
                    systemImage: "tray",
                    message: "Nothing under \(store.rootPath)"
                )
            }
        }
    }

    private func projectHeader(_ group: ProjectGroup) -> some View {
        let collapsed = collapsedProjects.contains(group.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if collapsed { collapsedProjects.remove(group.id) }
                else { collapsedProjects.insert(group.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .lineLimit(1)
                if let host = group.sessions.first?.remoteDisplayName {
                    Label(host, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Text("\(group.sessions.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.path)
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
                      help: store.hiddenCount > 0 && !store.showTemporarySessions
                            ? "\(store.hiddenCount) temporary/analysis sessions are hidden. Toggle in the ⋯ menu." : "")
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
        var s = "\(store.filteredGroups.count) projects · \(store.totalSessions) sessions"
        let remote = store.filteredGroups.flatMap { $0.sessions }.filter(\.isRemote).count
        if remote > 0 {
            s += " · \(remote) remote"
        }
        if store.hiddenCount > 0 && !store.showTemporarySessions {
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
