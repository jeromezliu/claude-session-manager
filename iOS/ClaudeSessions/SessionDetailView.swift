import SwiftUI

/// One session: the conversation (oldest first, opening at the newest turn),
/// the live reply, approval cards and the composer.
struct SessionDetailView: View {
    let info: RemoteSessionInfo
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        SessionConversation(info: info, model: client.model(info.id))
            .onAppear { client.subscribe(info.id) }
            .onDisappear { client.unsubscribe(info.id) }
    }
}

private struct SessionConversation: View {
    let info: RemoteSessionInfo
    @ObservedObject var model: SessionModel
    @EnvironmentObject private var client: RemoteClient
    @State private var draft = ""
    @State private var error: String?
    @State private var showNotes = false
    @FocusState private var composing: Bool

    private var shown: [ConversationItem] {
        showNotes ? model.items : model.items.filter { if case .note = $0 { return false } else { return true } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shown) { ItemView(item: $0).id($0.id) }
                        if !model.liveText.isEmpty { LiveReply(text: model.liveText).id("live") }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if !model.transcriptLoaded { ProgressView() }
                    else if model.items.isEmpty && model.liveText.isEmpty {
                        ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .onChange(of: model.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.liveText) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.transcriptLoaded) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            bottomBar
        }
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show attachments & system events", isOn: $showNotes)
                    if model.phase != nil {
                        Picker("Permission mode", selection: Binding(
                            get: { model.permissionMode ?? "default" },
                            set: { mode in run { try await client.setPermissionMode(mode, for: info.id) } })) {
                            Text("Ask before edits").tag("default")
                            Text("Accept edits").tag("acceptEdits")
                            Text("Auto").tag("auto")
                            Text("Plan only").tag("plan")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 8) {
            ForEach(model.pending) { request in
                RequestCardView(request: request) { decision in
                    run { try await client.answer(request, in: info.id, with: decision) }
                }
            }
            if let phase = model.phase, phase == .running || phase == .waiting || !model.queued.isEmpty {
                HStack {
                    if phase == .running { ProgressView().controlSize(.small); Text("Claude is working…") }
                    else if phase == .waiting { Label("Waiting for you", systemImage: "hand.raised.fill").foregroundStyle(.orange) }
                    if !model.queued.isEmpty { Text("· \(model.queued.count) queued") }
                    Spacer()
                    Button(role: .destructive) { run { try await client.interrupt(info.id) } } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let elsewhere = info.busyElsewhere {
                Label("Open in \(elsewhere) — read-only here.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Claude…", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composing)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    Button {
                        let text = draft
                        draft = ""
                        run { try await client.sendMessage(text, to: info.id) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.state != .connected)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func run(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body(); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Items

private struct ItemView: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .prompt(_, let date, let text):
            VStack(alignment: .leading, spacing: 4) {
                caption("You", date)
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 8)
        case .reply(_, let date, _, let text):
            VStack(alignment: .leading, spacing: 4) {
                caption("Claude", date)
                MarkdownText(text)
            }
        case .activity(let a):
            ActivityLine(activity: a)
        case .note(_, _, let text):
            Text(text).font(.caption).italic().foregroundStyle(.tertiary)
        }
    }

    private func caption(_ who: String, _ date: Date?) -> some View {
        HStack {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let date { Text(Fmt.short(date)).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

private struct ActivityLine: View {
    let activity: ConversationItem.Activity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: activity.hasError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    Text(summary).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(activity.blocks.enumerated()), id: \.offset) { _, block in
                    BlockLine(block: block)
                }
                .padding(.leading, 12)
            }
        }
    }

    private var summary: String {
        let calls = activity.callCount
        guard calls > 0 else { return "Thinking" }
        let names = activity.toolCounts.prefix(3).map { $0.count > 1 ? "\(Fmt.toolName($0.name)) ×\($0.count)" : Fmt.toolName($0.name) }
        return "\(calls) tool \(calls == 1 ? "call" : "calls") · " + names.joined(separator: ", ")
    }
}

private struct BlockLine: View {
    let block: TranscriptEvent.Block
    @State private var open = false

    var body: some View {
        switch block {
        case .toolUse(let name, let input):
            disclosure("\(Fmt.toolName(name))", "terminal", input)
        case .toolResult(let text, let isError):
            disclosure(isError ? "Result (error)" : "Result", isError ? "exclamationmark.triangle" : "arrow.turn.down.right", text)
        case .thinking(let t):
            disclosure("Thinking", "brain", t)
        case .text(let t):
            MarkdownText(t)
        case .image(let m):
            Label("Image (\(m))", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        case .note(let n):
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func disclosure(_ title: String, _ icon: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                Label(title, systemImage: icon).font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if open { CodeBlock(text: String(body.prefix(8000))) }
        }
    }
}

private struct LiveReply: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Claude").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            MarkdownText(text)
        }
    }
}

// MARK: - Requests

/// Approve a tool, answer a question, or review a plan.
struct RequestCardView: View {
    let request: PendingRequest
    let onDecision: (RemoteDecision) -> Void
    @State private var reason = ""
    @State private var askReason = false
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.kind {
            case .permission: permission
            case .question: question
            case .plan: plan
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35)))
        .alert("Tell Claude why", isPresented: $askReason) {
            TextField("Reason (optional)", text: $reason)
            Button("Deny", role: .destructive) { onDecision(.deny(message: reason)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow \(Fmt.toolName(request.ask.displayName ?? request.ask.toolName))?", systemImage: "hand.raised")
                .font(.headline)
            if let d = request.ask.description { Text(d).font(.subheadline).foregroundStyle(.secondary) }
            if let preview { CodeBlock(text: preview).frame(maxHeight: 160) }
            HStack {
                Button("Allow") { onDecision(.allow(always: false)) }.buttonStyle(.borderedProminent)
                if request.ask.suggestions != nil {
                    Button("Always") { onDecision(.allow(always: true)) }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Deny", role: .destructive) { askReason = true }.buttonStyle(.bordered)
            }
        }
    }

    /// Command, path, or the start of the new content.
    private var preview: String? {
        let input = request.ask.input
        if let c = input["command"]?.stringValue { return c }
        if let p = input["file_path"]?.stringValue {
            if let new = input["new_string"]?.stringValue ?? input["content"]?.stringValue {
                return p + "\n\n" + String(new.prefix(600))
            }
            return p
        }
        return nil
    }

    private var questions: [JSONValue] { request.ask.input["questions"]?.arrayValue ?? [] }

    private var question: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude has a question", systemImage: "questionmark.bubble").font(.headline)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let text = q["question"]?.stringValue ?? ""
                let multi = q["multiSelect"] == .bool(true)
                Text(text).font(.subheadline.weight(.medium))
                ForEach(Array((q["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, o in
                    let label = o["label"]?.stringValue ?? ""
                    let on = picked[text, default: []].contains(label)
                    Button {
                        var set = multi ? picked[text, default: []] : []
                        if on { set.remove(label) } else { set.insert(label) }
                        picked[text] = set
                    } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(label)
                                if let d = o["description"]?.stringValue { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Answer") {
                    var answers: [String: String] = [:]
                    for (q, set) in picked where !set.isEmpty { answers[q] = set.sorted().joined(separator: ", ") }
                    onDecision(.answer(answers))
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked.values.filter { !$0.isEmpty }.count < questions.count)
                Spacer()
                Button("Skip", role: .destructive) { onDecision(.deny(message: "The user skipped the question.")) }
            }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Review the plan", systemImage: "list.bullet.clipboard").font(.headline)
            ScrollView { MarkdownText(request.ask.input["plan"]?.stringValue ?? "") }.frame(maxHeight: 240)
            HStack {
                Button("Approve") { onDecision(.approvePlan) }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Keep Planning") { askReason = true }.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - New session

struct NewSessionView: View {
    let onStarted: (String) -> Void
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var prompt = ""
    @State private var mode = "default"
    @State private var working = false
    @State private var error: String?

    /// Folders of recent sessions, newest first.
    private var recentFolders: [String] {
        var seen = Set<String>()
        return client.sessions.compactMap(\.folder).filter { seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Folder on the Mac") {
                    HStack {
                        // The URL keyboard keeps "--" from turning into "—".
                        TextField("/Users/…/project", text: $folder)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !folder.isEmpty {
                            Button { folder = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                    if !recentFolders.isEmpty {
                        Picker("Recent", selection: $folder) {
                            ForEach(recentFolders, id: \.self) { f in
                                Text((f as NSString).lastPathComponent).tag(f)
                            }
                        }
                    }
                }
                SwiftUI.Section("First message") {
                    TextField("What should Claude do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                }
                SwiftUI.Section {
                    Picker("Permissions", selection: $mode) {
                        Text("Ask before edits").tag("default")
                        Text("Accept edits").tag("acceptEdits")
                        Text("Auto").tag("auto")
                        Text("Plan only").tag("plan")
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Start") { start() }
                            .disabled(folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { if folder.isEmpty { folder = recentFolders.first ?? "" } }
        }
    }

    private func start() {
        working = true
        Task {
            do {
                if let id = try await client.startSession(in: folder.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt, mode: mode) {
                    client.refreshSessions()
                    onStarted(id)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
