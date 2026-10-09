import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var remoteHosts: RemoteHostStore
    @ObservedObject var terminals = TerminalManager.shared

    /// Sidebar selection: what the middle column lists.
    @State var sidebarSelection: SidebarSelection? = .allSessions
    @State var selectedSessions: Set<SessionSummary.ID> = []
    @State var selectedSkill: SkillInfo.ID?
    @State var showNewSkill = false
    @State var removeSkillTarget: SkillInfo?
    @State var selectedTrash: TrashEntry.ID?
    /// Sidebar rows/sections (categories, groups, projects) the user
    /// collapsed, newline-separated ids — remembered across launches.
    @AppStorage("collapsedSidebarSections") var collapsedSidebarRaw = ""
    /// Row currently under a drag, for the drop highlight.
    @State var dropTargetID: String?
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
        NavigationSplitView {
            // Column widths go through the split view itself (a plain
            // .frame(minWidth:) pins the content and makes dividers snap).
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 520)
        } detail: {
            detail
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: searchPrompt)
        .toolbar { toolbarContent }
        .onChange(of: sidebarSelection) { sel in syncViewMode(to: sel) }
        .onChange(of: store.viewMode) { mode in syncSidebar(to: mode) }
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

    private var searchPrompt: String {
        switch store.viewMode {
        case .sessions: return "Search all sessions"
        case .skills: return "Search skills"
        case .trash: return "Search trash"
        }
    }

    /// The sidebar picks the mode (Skills / Trash / sessions) …
    private func syncViewMode(to selection: SidebarSelection?) {
        let mode: ViewMode
        switch selection ?? .allSessions {
        case .skills: mode = .skills
        case .trash: mode = .trash
        default: mode = .sessions
        }
        if store.viewMode != mode { store.viewMode = mode }
        // Keep a selected session only if the new list still shows it.
        if mode == .sessions, !selectedSessions.isEmpty {
            let listed = Set(store.listedSessions(for: selection ?? .allSessions).map(\.id))
            if selectedSessions.isDisjoint(with: listed) { selectedSessions = [] }
        }
    }

    /// … and code that switches mode directly (e.g. after creating a skill)
    /// moves the sidebar along.
    private func syncSidebar(to mode: ViewMode) {
        switch (mode, sidebarSelection) {
        case (.skills, .skills?), (.trash, .trash?): return
        case (.skills, _): sidebarSelection = .skills
        case (.trash, _): sidebarSelection = .trash
        case (.sessions, .skills?), (.sessions, .trash?), (.sessions, nil): sidebarSelection = .allSessions
        case (.sessions, _): return
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
