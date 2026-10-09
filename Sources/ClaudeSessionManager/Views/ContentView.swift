import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var remoteHosts: RemoteHostStore
    @ObservedObject var terminals = TerminalManager.shared

    @State var selectedSessions: Set<SessionSummary.ID> = []
    @State var selectedSkill: SkillInfo.ID?
    @State var showNewSkill = false
    @State var removeSkillTarget: SkillInfo?
    @State var selectedTrash: TrashEntry.ID?
    /// Section ids (groups / projects) the user collapsed.
    @State var collapsedSections: Set<String> = []
    /// Pending "New Group…" / "Rename Group…" sheet.
    @State var groupSheet: GroupSheetRequest?
    @State var renameTarget: SessionSummary?
    @State var deleteTarget: SessionSummary?
    @State var purgeTarget: TrashEntry?
    @State var confirmEmpty = false
    @State var confirmDeleteSelection = false
    /// Synthetic id of a just-created session shown embedded in the detail pane.
    @State var activeNewTerminal: String?
    /// Whether the embedded terminal fills the whole detail (hides transcript).
    @State var terminalMaximized = false
    @State var showRemoteHosts = false
    @State var remoteNewSessionHost: RemoteHost?

    private var mainScene: some View {
        GeometryReader { geo in
        NavigationSplitView {
            sidebar
                // Sized through the split view itself (a plain .frame(minWidth:)
                // would pin the content's width and make the sidebar snap
                // instead of sliding). The max is tied to the window width so
                // the saved divider position always fits next to the detail —
                // otherwise a narrow window expands the sidebar to whatever
                // space is available and then jumps to the saved width.
                .navigationSplitViewColumnWidth(
                    min: 240, ideal: 320,
                    max: max(280, min(520, geo.size.width - 560)))
        } detail: {
            detail
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search sessions")
        .toolbar { toolbarContent }
        .onChange(of: store.sessions.count) { _ in autoSelectForSnapshot() }
        .onChange(of: selectedSessions) { _ in terminalMaximized = false }
        .onChange(of: remoteHosts.hosts) { _ in
            Task { await store.reload() }
            skills.load()
        }
        .onChange(of: terminals.recentlyAdopted) { newID in
            // A new session's terminal was re-keyed to its real id; follow it so
            // the detail keeps showing the (still-running) terminal.
            if let newID, activeNewTerminal != nil { activeNewTerminal = newID }
        }
        .onAppear { maybeTerminalSnapshot(); maybeNewSessionSnapshot(); maybeSkillsSnapshot() }
        }
    }

    var body: some View {
        withDialogs(mainScene)
    }

    // MARK: - Detail

    func session(for id: SessionSummary.ID) -> SessionSummary? {
        store.visibleSession(withID: id)
    }

    var selectedSummary: SessionSummary? {
        guard selectedSessions.count == 1, let id = selectedSessions.first else { return nil }
        return session(for: id)
    }

    var selectedTrashEntry: TrashEntry? {
        guard let id = selectedTrash else { return nil }
        return store.filteredTrash.first { $0.id == id }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.viewMode {
        case .sessions:
            if selectedSessions.count > 1 {
                multiSelectionPanel
            } else if let session = selectedSummary {
                if let terminal = terminals.session(for: session.id), !terminal.isPoppedOut {
                    terminalSplit(summary: session, terminal: terminal)
                } else {
                    TranscriptView(session: session, mode: .active,
                                   onContinue: { store.continueSession(session) })
                }
            } else if let id = activeNewTerminal,
                      let terminal = terminals.session(for: id),
                      !terminal.isPoppedOut {
                terminalSplit(summary: terminal.displaySummary, terminal: terminal)
            } else {
                ContentUnavailableView_Compat(
                    title: "No session selected",
                    systemImage: "text.bubble",
                    message: "Pick a session to read its transcript, or ⌘-click to select several."
                )
            }
        case .skills:
            if let skill = selectedSkillInfo {
                SkillDetailView(skill: skill,
                                onEdit: { skills.openInEditor(skill) },
                                onReveal: { skills.revealInFinder(skill) },
                                onRemove: { removeSkillTarget = skill })
            } else {
                ContentUnavailableView_Compat(
                    title: "No skill selected",
                    systemImage: "wand.and.stars",
                    message: "Pick a skill to view it, or add one with ＋."
                )
            }
        case .trash:
            if let entry = selectedTrashEntry {
                TranscriptView(session: entry.summary, mode: .trashed,
                               deletedNote: "Deleted \(Fmt.relative(entry.deletedAt)) · from \(entry.originalFolder)",
                               onRecover: { store.recover(entry); selectedTrash = nil },
                               onPurge: { purgeTarget = entry })
            } else {
                ContentUnavailableView_Compat(
                    title: "No session selected",
                    systemImage: "trash",
                    message: "Pick a trashed session to preview, recover, or delete it."
                )
            }
        }
    }

    var selectedSkillInfo: SkillInfo? {
        guard let id = selectedSkill else { return nil }
        return skills.skills.first { $0.id == id }
    }

    /// Transcript-area + terminal in one stable split (terminal never reparented).
    /// "Maximize" collapses the transcript to zero height instead of removing it,
    /// so the terminal view stays put (no blanking). New sessions flow through
    /// here too — their transcript area just shows an empty-state notice.
    @ViewBuilder
    private func terminalSplit(summary: SessionSummary, terminal: TerminalSession) -> some View {
        VSplitView {
            TranscriptView(session: summary, mode: .active,
                           onContinue: { store.continueSession(summary) })
                .frame(minHeight: terminalMaximized ? 0 : 180,
                       maxHeight: terminalMaximized ? 0 : .infinity)
                .opacity(terminalMaximized ? 0 : 1)
            TerminalPaneView(session: terminal,
                             isMaximized: terminalMaximized,
                             onToggleMaximize: { terminalMaximized.toggle() })
                .frame(minHeight: 140)
        }
    }

    private var multiSelectionPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("\(selectedSessions.count) sessions selected")
                .font(.title3.weight(.semibold))
            Button(role: .destructive) { confirmDeleteSelection = true } label: {
                Label("Move \(selectedSessions.count) to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            Text("⌘-click or ⇧-click to adjust the selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    /// Start a new session in a folder and show it embedded in the detail pane.
    func createNewSession(in dir: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let target = (fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            ? dir : URL(fileURLWithPath: NSHomeDirectory())
        selectedSessions = []
        activeNewTerminal = store.newSession(inDirectory: target)
    }
}

/// What the group-name sheet is for.
enum GroupSheetRequest: Identifiable {
    /// Create a group and move these sessions into it.
    case create(Set<SessionSummary.ID>)
    case rename(String)
    /// Create a category and file this section (group / project) under it.
    case createCategory(String)
    case renameCategory(String)

    var id: String {
        switch self {
        case .create(let ids): return "create:" + ids.sorted().joined(separator: ",")
        case .rename(let name): return "rename:" + name
        case .createCategory(let section): return "create-category:" + section
        case .renameCategory(let name): return "rename-category:" + name
        }
    }
}
