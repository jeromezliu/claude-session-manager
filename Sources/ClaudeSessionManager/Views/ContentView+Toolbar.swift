import SwiftUI
import AppKit

extension ContentView {
    // MARK: - Menus & toolbar

    @ViewBuilder
    func rowMenu(for ids: Set<SessionSummary.ID>) -> some View {
        if ids.count > 1 {
            // The List selection is already updated to `ids` before this builds,
            // so the confirm alert acts on the full selection.
            groupMenu(for: ids)
            Divider()
            Button("Move \(ids.count) to Trash", role: .destructive) {
                confirmDeleteSelection = true
            }
        } else if let id = ids.first, let session = session(for: id) {
            Button("Continue in Terminal") { store.continueSession(session) }
            Button("Open in Terminal.app") { store.openInExternalTerminal(session) }
            Button("Rename…") { renameTarget = session }
            groupMenu(for: ids)
            Divider()
            Button("Reveal in Finder") { SessionActions.revealInFinder(session) }
            Button("Copy Session ID") { SessionActions.copySessionID(session) }
            Divider()
            Button("Move to Trash", role: .destructive) { deleteTarget = session }
        }
    }

    /// "Move to Group" submenu for one or more sessions.
    private func groupMenu(for ids: Set<SessionSummary.ID>) -> some View {
        let current = ids.count == 1 ? ids.first.flatMap { store.group(of: $0) } : nil
        let anyGrouped = ids.contains { store.group(of: $0) != nil }
        return Menu(ids.count > 1 ? "Move \(ids.count) to Group" : "Move to Group") {
            ForEach(store.allGroups, id: \.self) { name in
                Button {
                    store.assign(ids, toGroup: name)
                } label: {
                    if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !store.allGroups.isEmpty { Divider() }
            Button("New Group…") { groupSheet = .create(ids) }
            if anyGrouped {
                Divider()
                Button("Remove from Group") { store.assign(ids, toGroup: nil) }
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            switch store.viewMode {
            case .sessions:
                Menu {
                    Button(store.newSessionDir) {}.disabled(true)
                    Divider()
                    Button("Choose Folder…") { chooseFolderAndStartNewSession() }
                    if !remoteHosts.hosts.filter({ $0.enabled }).isEmpty {
                        Divider()
                        ForEach(remoteHosts.hosts.filter { $0.enabled }) { host in
                            Button("On \(host.displayName)…") { remoteNewSessionHost = host }
                        }
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                } primaryAction: {
                    createNewSession(in: URL(fileURLWithPath: store.newSessionDir))
                }
                .help("New session in \(store.newSessionDir) — click ⌄ to choose another folder, or start one on a remote host")

                if selectedSessions.count > 1 {
                    Button(role: .destructive) { confirmDeleteSelection = true } label: {
                        Label("Delete \(selectedSessions.count)", systemImage: "trash")
                    }
                    .help("Move the selected sessions to Trash")
                } else if let session = selectedSummary {
                    Menu {
                        Button { store.continueSession(session) } label: {
                            Label("Continue in App", systemImage: "play.fill")
                        }
                        Button { store.openInExternalTerminal(session) } label: {
                            Label("Open in Terminal.app", systemImage: "arrow.up.forward.app")
                        }
                    } label: {
                        Label("Continue", systemImage: "play.fill")
                    } primaryAction: {
                        store.continueSession(session)
                    }
                    .help("Resume in an internal terminal — click ⌄ to use the external Terminal.app")
                    Button { renameTarget = session } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { deleteTarget = session } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            case .skills:
                Menu {
                    Button("New Skill…") { showNewSkill = true }
                    Button("Import Folder…") { importSkillFolder() }
                } label: {
                    Label("Add Skill", systemImage: "plus")
                } primaryAction: {
                    showNewSkill = true
                }
                .help("Create a new skill, or import an existing SKILL.md folder")

                if let skill = selectedSkillInfo {
                    if skill.isReadOnly {
                        Button { skills.revealInFinder(skill) } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .help(skill.isRemote ? "Remote skill (synced mirror) — reveal the local copy"
                                             : "Plugin skill (read-only) — reveal in Finder")
                    } else {
                        Button { skills.openInEditor(skill) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .help("Open SKILL.md in your editor")
                        Button(role: .destructive) { removeSkillTarget = skill } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            case .trash:
                if let entry = selectedTrashEntry {
                    Button { store.recover(entry); selectedTrash = nil } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    .help("Restore to its original location")
                    Button(role: .destructive) { purgeTarget = entry } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
            }
            Menu {
                Picker("Organize Sessions", selection: $store.organization) {
                    ForEach(SessionOrganization.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show temporary sessions", isOn: $store.showTemporarySessions)
                Toggle("Show archived sessions", isOn: $store.showArchivedSessions)
                Picker("Context window", selection: $store.contextWindowMode) {
                    ForEach(ContextWindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Section("Sessions Folder") {
                    Button(store.rootPath) {}.disabled(true)
                    Button("Change…") { chooseRoot() }
                }
                Section("Skills Folder") {
                    Button(skills.skillsDir.path) {}.disabled(true)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([skills.skillsDir])
                    }
                }
                Divider()
                Button("Manage Remote Hosts…") { showRemoteHosts = true }
                Divider()
                Button("Version \(AppInfo.version)") {}.disabled(true)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .help("Options")
        }
    }
}
