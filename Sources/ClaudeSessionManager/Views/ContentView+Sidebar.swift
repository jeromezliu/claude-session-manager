import SwiftUI
import AppKit

extension ContentView {
    // MARK: - Columns

    var sidebar: some View { sidebarList }

    /// Middle column: the sessions of the sidebar selection, or the Skills /
    /// Trash lists.
    var contentColumn: some View {
        Group {
            switch store.viewMode {
            case .sessions: sessionsContent
            case .skills: skillsList.navigationTitle("Skills")
            case .trash: trashList.navigationTitle("Trash")
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            ToolbarItemGroup {
                if store.viewMode == .sessions { organizationPicker }
                RefreshButton { refreshCurrentTab() }
            }
        }
    }

    private func refreshCurrentTab() {
        switch store.viewMode {
        case .sessions: Task { await store.reload() }
        case .skills: skills.load()
        case .trash: Task { await store.loadTrash() }
        }
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
        .listStyle(.inset)
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
        .listStyle(.inset)
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
        let listed = store.listedSessions(for: sidebarSelection ?? .allSessions)
        var s = "\(listed.count) sessions"
        let remote = listed.filter(\.isRemote).count
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
