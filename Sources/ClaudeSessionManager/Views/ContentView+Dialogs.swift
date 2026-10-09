import SwiftUI

extension ContentView {
    /// Every sheet and alert the main window can present.
    func withDialogs<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $groupSheet) { request in
            switch request {
            case .create(let ids):
                NameSheet(title: "New Group",
                          message: ids.isEmpty ? nil : "The \(ids.count == 1 ? "session" : "\(ids.count) sessions") will be moved into it.",
                          placeholder: "Group name", actionTitle: "Create") { name in
                    if let created = store.createGroup(named: name), !ids.isEmpty {
                        store.assign(ids, toGroup: created)
                    }
                }
            case .rename(let old):
                NameSheet(title: "Rename Group", placeholder: "Group name", initial: old) { name in
                    store.renameGroup(old, to: name)
                }
            }
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(session: target) { newTitle in
                store.rename(target, to: newTitle)
            }
        }
        .alert("Move session to Trash?", isPresented: presenceBinding($deleteTarget), presenting: deleteTarget) { session in
            Button("Move to Trash", role: .destructive) {
                selectedSessions.remove(session.id)
                store.delete(session)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("“\(session.title)” will move to the app Trash. You can recover it from the Trash tab.")
        }
        .alert("Move \(selectedSessions.count) sessions to Trash?", isPresented: $confirmDeleteSelection) {
            Button("Move to Trash", role: .destructive) {
                let ids = selectedSessions
                selectedSessions = []
                store.deleteMany(ids)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will move to the app Trash. You can recover them from the Trash tab.")
        }
        .alert("Delete permanently?", isPresented: presenceBinding($purgeTarget), presenting: purgeTarget) { entry in
            Button("Delete Permanently", role: .destructive) {
                if selectedTrash == entry.id { selectedTrash = nil }
                store.purge(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.summary.title)” will be permanently deleted. This cannot be undone.")
        }
        .alert("Empty Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) {
                selectedTrash = nil
                store.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently delete all \(store.trashEntries.count) sessions in the Trash. This cannot be undone.")
        }
        .alert("Remove skill?", isPresented: presenceBinding($removeSkillTarget), presenting: removeSkillTarget) { skill in
            Button(skill.isSymlink ? "Remove Link" : "Move to Trash", role: .destructive) {
                if selectedSkill == skill.id { selectedSkill = nil }
                skills.remove(skill)
            }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text(skill.isSymlink
                 ? "Removes the symlink “\(skill.folderName)” (the target is left untouched)."
                 : "“\(skill.name)” will be moved to the Trash.")
        }
        .sheet(isPresented: $showNewSkill) {
            NewSkillSheet { name in
                if let created = skills.createSkill(named: name) {
                    store.viewMode = .skills
                    selectedSkill = created.id
                    skills.openInEditor(created)
                }
            }
        }
        .sheet(isPresented: $showRemoteHosts) {
            RemoteHostsSheet()
        }
        .sheet(item: $remoteNewSessionHost) { host in
            RemoteNewSessionSheet(host: host) { dir in
                selectedSessions = []
                activeNewTerminal = store.newSession(remoteDir: dir, host: host)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert("Skills",
               isPresented: Binding(get: { skills.errorMessage != nil },
                                    set: { if !$0 { skills.errorMessage = nil } })) {
            Button("OK", role: .cancel) { skills.errorMessage = nil }
        } message: {
            Text(skills.errorMessage ?? "")
        }
    }

    private func presenceBinding<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } })
    }
}
