import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject private var terminals = TerminalManager.shared

    @State private var selectedSessions: Set<SessionSummary.ID> = []
    @State private var selectedTrash: TrashEntry.ID?
    @State private var collapsedProjects: Set<String> = []
    @State private var renameTarget: SessionSummary?
    @State private var deleteTarget: SessionSummary?
    @State private var purgeTarget: TrashEntry?
    @State private var confirmEmpty = false
    @State private var confirmDeleteSelection = false
    /// Synthetic id of a just-created session shown embedded in the detail pane.
    @State private var activeNewTerminal: String?
    /// Whether the embedded terminal fills the whole detail (hides transcript).
    @State private var terminalMaximized = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 300)
        } detail: {
            detail
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search sessions")
        .toolbar { toolbarContent }
        .onChange(of: store.groups.count) { _ in autoSelectForSnapshot() }
        .onChange(of: selectedSessions) { _ in terminalMaximized = false }
        .onAppear { maybeTerminalSnapshot(); maybeNewSessionSnapshot() }
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
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            switch store.viewMode {
            case .sessions: sessionsList
            case .trash: trashList
            }
        }
        .safeAreaInset(edge: .top) { modeTabs }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var modeTabs: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $store.viewMode) {
                Text("Sessions").tag(ViewMode.sessions)
                Text("Trash\(store.trashEntries.isEmpty ? "" : " (\(store.trashEntries.count))")").tag(ViewMode.trash)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
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
                                .contextMenu { rowMenu(session) }
                        }
                    }
                } header: {
                    projectHeader(group)
                }
            }
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
                Spacer()
                Text("\(group.sessions.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.path)
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

    @ViewBuilder
    private var footer: some View {
        switch store.viewMode {
        case .sessions:
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(sessionsCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .help(store.hiddenCount > 0 && !store.showTemporarySessions
                          ? "\(store.hiddenCount) temporary/analysis sessions are hidden. Toggle in the ⋯ menu."
                          : "")
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(store.rootPath)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(store.rootPath)
                    Spacer()
                    Button { chooseRoot() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Change scan folder")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background(.bar)
        case .trash:
            VStack(spacing: 6) {
                Divider()
                HStack {
                    Text("\(store.trashEntries.count) in Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmEmpty = true } label: {
                        Label("Empty Trash", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(store.trashEntries.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    // MARK: - Detail

    private func session(for id: SessionSummary.ID) -> SessionSummary? {
        for g in store.filteredGroups {
            if let s = g.sessions.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    private var selectedSummary: SessionSummary? {
        guard selectedSessions.count == 1, let id = selectedSessions.first else { return nil }
        return session(for: id)
    }

    private var selectedTrashEntry: TrashEntry? {
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
                terminalSplit(summary: terminal.session, terminal: terminal)
            } else {
                ContentUnavailableView_Compat(
                    title: "No session selected",
                    systemImage: "text.bubble",
                    message: "Pick a session to read its transcript, or ⌘-click to select several."
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

    // MARK: - Menus & toolbar

    @ViewBuilder
    private func rowMenu(_ session: SessionSummary) -> some View {
        if selectedSessions.count > 1 && selectedSessions.contains(session.id) {
            Button("Move \(selectedSessions.count) to Trash", role: .destructive) {
                confirmDeleteSelection = true
            }
            Divider()
        }
        Button("Continue in Terminal") { store.continueSession(session) }
        Button("Open in Terminal.app") { store.openInExternalTerminal(session) }
        Button("Rename…") { renameTarget = session }
        Divider()
        Button("Reveal in Finder") { SessionActions.revealInFinder(session) }
        Button("Copy Session ID") { SessionActions.copySessionID(session) }
        Divider()
        Button("Move to Trash", role: .destructive) { deleteTarget = session }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            switch store.viewMode {
            case .sessions:
                Menu {
                    Button(store.newSessionDir) {}.disabled(true)
                    Divider()
                    Button("Choose Folder…") { chooseFolderAndStartNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus")
                } primaryAction: {
                    createNewSession(in: URL(fileURLWithPath: store.newSessionDir))
                }
                .help("New session in \(store.newSessionDir) — click ⌄ to choose another folder")

                if selectedSessions.count > 1 {
                    Button(role: .destructive) { confirmDeleteSelection = true } label: {
                        Label("Delete \(selectedSessions.count)", systemImage: "trash")
                    }
                    .help("Move the selected sessions to Trash")
                } else if let session = selectedSummary {
                    Button { store.continueSession(session) } label: {
                        Label("Continue", systemImage: "play.fill")
                    }
                    .help("Resume this session in an internal terminal")
                    Button { renameTarget = session } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { deleteTarget = session } label: {
                        Label("Delete", systemImage: "trash")
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
                Toggle("Show temporary sessions", isOn: $store.showTemporarySessions)
                Picker("Context window", selection: $store.contextWindowMode) {
                    Text("Auto").tag("auto")
                    Text("200K").tag("200k")
                    Text("1M").tag("1m")
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .help("Options")

            Button { Task { await store.reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Helpers

    private var sessionsCountLabel: String {
        var s = "\(store.filteredGroups.count) projects · \(store.totalSessions) sessions"
        if store.hiddenCount > 0 && !store.showTemporarySessions {
            s += " · \(store.hiddenCount) hidden"
        }
        return s
    }

    private func presenceBinding<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } })
    }

    /// Dev-only: create a new session and snapshot the embedded detail pane.
    private func maybeNewSessionSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_NEWSESSION_SNAP"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            createNewSession(in: URL(fileURLWithPath: NSHomeDirectory()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
            }
        }
    }

    /// Start a new session in a folder and show it embedded in the detail pane.
    private func createNewSession(in dir: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let target = (fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            ? dir : URL(fileURLWithPath: NSHomeDirectory())
        selectedSessions = []
        activeNewTerminal = store.newSession(inDirectory: target)
    }

    /// Pick a folder (remembered as the new default), then start a session there.
    private func chooseFolderAndStartNewSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        panel.message = "Choose the working directory for the new Claude session"
        panel.directoryURL = URL(fileURLWithPath: store.newSessionDir)
        if panel.runModal() == .OK, let url = panel.url {
            store.newSessionDir = url.path   // remember as the new default
            createNewSession(in: url)
        }
    }

    /// When launched in snapshot mode, pick the first session so the detail pane
    /// shows a real transcript in the captured image.
    private func autoSelectForSnapshot() {
        guard ProcessInfo.processInfo.environment["CSM_SNAPSHOT"] != nil else { return }
        guard selectedSessions.isEmpty, let session = store.groups.first?.sessions.first else { return }
        selectedSessions = [session.id]
    }

    /// Dev-only: open a terminal for the first session and snapshot that window.
    private func maybeTerminalSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_SNAPSHOT_TERM"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let session = store.groups.first?.sessions.first {
                selectedSessions = [session.id]
                store.continueSession(session)
            }
            if ProcessInfo.processInfo.environment["CSM_TERM_MAX"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { terminalMaximized = true }
            }
            if ProcessInfo.processInfo.environment["CSM_TERM_POPOUT"] == "1",
               let s = store.groups.first?.sessions.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    terminals.session(for: s.id)?.popOut()
                    if ProcessInfo.processInfo.environment["CSM_TERM_POPIN"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            terminals.session(for: s.id)?.popIn()
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.rootURL
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            store.rootPath = url.path
        }
    }
}
