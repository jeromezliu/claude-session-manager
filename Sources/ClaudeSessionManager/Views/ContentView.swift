import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject private var terminals = TerminalManager.shared

    @State private var selectedSession: SessionSummary.ID?
    @State private var selectedTrash: TrashEntry.ID?
    @State private var collapsedProjects: Set<String> = []
    @State private var renameTarget: SessionSummary?
    @State private var deleteTarget: SessionSummary?
    @State private var purgeTarget: TrashEntry?
    @State private var confirmEmpty = false

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
        .onAppear { maybeTerminalSnapshot() }
        .sheet(item: $renameTarget) { target in
            RenameSheet(session: target) { newTitle in
                store.rename(target, to: newTitle)
            }
        }
        .alert("Move session to Trash?", isPresented: presenceBinding($deleteTarget), presenting: deleteTarget) { session in
            Button("Move to Trash", role: .destructive) {
                if selectedSession == session.id { selectedSession = nil }
                store.delete(session)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("“\(session.title)” will move to the app Trash. You can recover it from the Trash tab.")
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
        List(selection: $selectedSession) {
            ForEach(store.filteredGroups) { group in
                Section {
                    if !collapsedProjects.contains(group.id) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session,
                                       activity: terminals.session(for: session.id)?.activity)
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

    private var selectedSummary: SessionSummary? {
        guard let id = selectedSession else { return nil }
        for g in store.filteredGroups {
            if let s = g.sessions.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    private var selectedTrashEntry: TrashEntry? {
        guard let id = selectedTrash else { return nil }
        return store.filteredTrash.first { $0.id == id }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.viewMode {
        case .sessions:
            if let session = selectedSummary {
                let terminal = terminals.session(for: session.id)
                if let terminal, !terminal.isPoppedOut {
                    VSplitView {
                        TranscriptView(session: session, mode: .active,
                                       onContinue: { store.continueSession(session) })
                            .frame(minHeight: 180)
                        TerminalPaneView(session: terminal)
                            .frame(minHeight: 140)
                    }
                } else {
                    TranscriptView(session: session, mode: .active,
                                   onContinue: { store.continueSession(session) })
                }
            } else {
                ContentUnavailableView_Compat(
                    title: "No session selected",
                    systemImage: "text.bubble",
                    message: "Pick a session to read its transcript."
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

    // MARK: - Menus & toolbar

    @ViewBuilder
    private func rowMenu(_ session: SessionSummary) -> some View {
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
                if let session = selectedSummary {
                    Button { store.continueSession(session) } label: {
                        Label("Continue", systemImage: "play.fill")
                    }
                    .help("Resume this session in Claude Code")
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

    /// When launched in snapshot mode, pick the first session so the detail pane
    /// shows a real transcript in the captured image.
    private func autoSelectForSnapshot() {
        guard ProcessInfo.processInfo.environment["CSM_SNAPSHOT"] != nil else { return }
        guard selectedSession == nil, let session = store.groups.first?.sessions.first else { return }
        selectedSession = session.id
    }

    /// Dev-only: open a terminal for the first session and snapshot that window.
    private func maybeTerminalSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_SNAPSHOT_TERM"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let session = store.groups.first?.sessions.first {
                selectedSession = session.id
                store.continueSession(session)
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
