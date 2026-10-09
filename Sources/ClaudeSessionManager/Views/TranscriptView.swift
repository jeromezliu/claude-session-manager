import SwiftUI
import AppKit

/// The detail pane for one session: a compact header, then either an
/// Overview (recap, your requests, outputs, stats) or the Conversation
/// (chronological, Markdown-rendered, tool work folded into one line).
struct TranscriptView: View {
    enum Mode { case active, trashed }
    enum Tab: String, CaseIterable { case overview = "Overview", conversation = "Conversation" }

    let session: SessionSummary
    var mode: Mode = .active
    var deletedNote: String? = nil
    var onContinue: () -> Void = {}
    var onRecover: () -> Void = {}
    var onPurge: () -> Void = {}

    @State private var events: [TranscriptEvent] = []
    @State private var items: [ConversationItem] = []
    @State private var insights = SessionParser.SessionInsights()
    @State private var loading = true
    @State private var watcher: FileWatcher?
    /// Where the last parse stopped, so live reloads only read appended bytes.
    @State private var cursor: SessionParser.TranscriptCursor?
    @State private var showInfo = false
    /// Conversation item to scroll to (set from the Overview).
    @State private var jumpTarget: String?
    @AppStorage("detailTab") private var tab = Tab.overview
    @AppStorage("showTranscriptNotes") private var showNotes = false
    @AppStorage("contextWindowMode") private var contextWindowMode = ContextWindowMode.auto

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .overview:
                    SessionOverview(session: session, items: items, insights: insights,
                                    contextWindowMode: contextWindowMode) { target in
                        jumpTarget = target
                        tab = .conversation
                    }
                case .conversation:
                    ConversationView(items: items, showNotes: showNotes, jumpTarget: $jumpTarget)
                }
            }
        }
        .task(id: session.id) {
            await load()
            // Live-reload as the file grows (e.g. while resumed in the terminal).
            watcher = FileWatcher(url: session.fileURL) {
                Task { await reload() }
            }
        }
        .onDisappear { watcher = nil }
    }

    // MARK: - Header

    /// Title row (title + view switch + actions), then one full-width line
    /// of context, so a narrow pane truncates instead of wrapping letters.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                controls
                    .fixedSize()
            }
            HStack(spacing: 12) {
                Label(session.projectName, systemImage: session.isScratch ? "tray" : "folder")
                    .layoutPriority(2)
                if let branch = session.gitBranch, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .truncationMode(.middle)
                }
                if let host = session.remoteDisplayName {
                    Label(host, systemImage: "network").layoutPriority(1)
                }
                Text("Updated \(Fmt.relative(session.modifiedAt))")
                    .layoutPriority(3)
            }
            .lineLimit(1)
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            if let deletedNote {
                Label(deletedNote, systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if mode == .trashed {
                Button(action: onRecover) { Label("Recover", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderedProminent)
                    .help("Restore this session to its original location")
                Button(role: .destructive, action: onPurge) { Label("Delete", systemImage: "trash") }
                    .help("Permanently delete this session")
            }
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == .conversation {
                Toggle(isOn: $showNotes) { Image(systemName: "list.bullet.below.rectangle") }
                    .toggleStyle(.button)
                    .help(showNotes ? "Hide attachments & system events" : "Show attachments & system events")
            }
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("Session details")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                    SessionInfo(session: session, contextWindowMode: contextWindowMode)
                }
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        events = []
        items = []
        insights = SessionParser.SessionInsights()
        cursor = nil
        await reload()
        loading = false
    }

    /// Parse only what was appended since the last read (the file is
    /// append-only while Claude writes it); start over if it shrank.
    private func reload() async {
        let url = session.fileURL
        let start = cursor ?? SessionParser.TranscriptCursor()
        // FileManager rather than URL.resourceValues: the latter can hand back
        // a value cached on this (long-lived) URL instead of the current size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let restart = size < start.offset
        let from = restart ? SessionParser.TranscriptCursor() : start
        let base = restart ? SessionParser.SessionInsights() : insights
        let previous = restart ? [] : events
        guard let result = await Task.detached(priority: .userInitiated, operation: { () -> (events: [TranscriptEvent], insights: SessionParser.SessionInsights, cursor: SessionParser.TranscriptCursor, items: [ConversationItem])? in
            guard let r = SessionParser.transcriptEvents(for: url, from: from, insights: base) else { return nil }
            let all = previous + r.events
            return (all, r.insights, r.cursor, ConversationBuilder.items(from: all))
        }).value else { return }

        // Another session was selected while parsing: discard.
        guard url == session.fileURL else { return }
        // An overlapping reload already advanced the cursor: this result
        // would be stale, so re-read from the new position instead.
        guard (cursor ?? SessionParser.TranscriptCursor()) == start else { return await reload() }
        events = result.events
        insights = result.insights
        items = result.items
        cursor = result.cursor
    }
}

// MARK: - Overview

private struct SessionOverview: View {
    let session: SessionSummary
    let items: [ConversationItem]
    let insights: SessionParser.SessionInsights
    let contextWindowMode: ContextWindowMode
    /// Jump to a conversation item.
    let onJump: (String) -> Void

    @State private var showAllPrompts = false
    @State private var showEdited = false

    private var prompts: [(id: String, date: Date?, text: String)] {
        items.compactMap { item in
            if case .prompt(_, let date, let text) = item { return (item.id, date, text) }
            return nil
        }
    }

    private var lastReply: (id: String, text: String)? {
        for item in items.reversed() {
            if case .reply(_, _, _, let text) = item { return (item.id, text) }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if items.isEmpty {
                    ContentUnavailableView_Compat(
                        title: "No conversation yet", systemImage: "bubble.left.and.bubble.right",
                        message: "This session has no messages yet — type in the terminal below to begin.")
                        .frame(height: 260)
                } else {
                    summary
                    requests
                    outputs
                    stats
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Recap (desktop's away summary) or, failing that, Claude's last reply.
    @ViewBuilder
    private var summary: some View {
        if let recap = insights.recap {
            OverviewSection(title: "Recap", detail: insights.recapDate.map { Fmt.relative($0) }) {
                Text(Markdown.inline(recap))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        } else if let reply = lastReply {
            OverviewSection(title: "Latest Reply", detail: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    // A teaser, so the requests and outputs below stay in view.
                    MarkdownText(reply.text.count > 400 ? String(reply.text.prefix(400)) + "…" : reply.text)
                    Button("Continue reading in Conversation") { onJump(reply.id) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // Everything the user asked, newest first — the fastest way into a long session.
    @ViewBuilder
    private var requests: some View {
        let all = Array(prompts.reversed())
        if !all.isEmpty {
            let shown = showAllPrompts ? all : Array(all.prefix(8))
            OverviewSection(title: "Your Requests", detail: "\(all.count)") {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, prompt in
                        if index > 0 { Divider() }
                        PromptRow(date: prompt.date, text: prompt.text) { onJump(prompt.id) }
                    }
                    if all.count > shown.count || showAllPrompts && all.count > 8 {
                        Divider()
                        Button(showAllPrompts ? "Show fewer" : "Show all \(all.count)") {
                            withAnimation { showAllPrompts.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // PRs, files handed over, files edited.
    @ViewBuilder
    private var outputs: some View {
        let edited = insights.editedFiles.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if !insights.pullRequests.isEmpty || !insights.deliveredFiles.isEmpty || !edited.isEmpty {
            OverviewSection(title: "Outputs", detail: nil) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(insights.pullRequests, id: \.self) { pr in
                        OutputRow(icon: "arrow.triangle.pull", title: "#\(pr.number)",
                                  subtitle: pr.repository) {
                            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                        }
                        .help(pr.url)
                        Divider()
                    }
                    ForEach(insights.deliveredFiles, id: \.self) { file in
                        let exists = FileManager.default.fileExists(atPath: file.path)
                        OutputRow(icon: "doc", title: (file.path as NSString).lastPathComponent,
                                  subtitle: file.caption, enabled: exists) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                        }
                        .help(exists ? file.path : "\(file.path) — no longer on this Mac")
                        Divider()
                    }
                    if !edited.isEmpty {
                        DisclosureGroup(isExpanded: $showEdited) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(edited, id: \.key) { path, count in
                                    EditedFileRow(path: path, count: count, root: session.workingDirectory)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Label("\(edited.count) files changed", systemImage: "pencil")
                                .font(.body)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var stats: some View {
        let window = session.contextWindow(mode: contextWindowMode)
        let pct = session.latestContextTokens > 0
            ? Int(Double(session.latestContextTokens) / Double(max(window, 1)) * 100) : nil
        return HStack(spacing: 10) {
            StatTile(value: "\(session.messageCount)", label: "messages")
            if let start = session.createdAt, let end = session.lastActivityAt {
                StatTile(value: Fmt.duration(end.timeIntervalSince(start)), label: "span")
            }
            if session.totalOutputTokens > 0 {
                StatTile(value: Fmt.tokens(session.totalOutputTokens), label: "output tokens")
            }
            if let pct { StatTile(value: "\(pct)%", label: "context of \(Fmt.window(window))") }
            if insights.compactions > 0 { StatTile(value: "\(insights.compactions)", label: "compactions") }
        }
    }
}

private struct OverviewSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

private struct PromptRow: View {
    let date: Date?
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(date.map(Fmt.short) ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show in Conversation")
    }
}

private struct OutputRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct EditedFileRow: View {
    let path: String
    let count: Int
    let root: String

    private var display: String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("×\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if FileManager.default.fileExists(atPath: path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        .help(path)
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 90, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Everything else about a session, kept out of the header.
private struct SessionInfo: View {
    let session: SessionSummary
    let contextWindowMode: ContextWindowMode

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Session ID", session.id)
            row("Folder", session.workingDirectory)
            if let wt = session.worktreeName { row("Worktree", wt) }
            if let branch = session.gitBranch { row("Branch", branch) }
            row("Created", Fmt.full(session.createdAt))
            row("Updated", Fmt.full(session.modifiedAt))
            let models = session.models.filter { !$0.hasPrefix("<") }.map(Fmt.model)
            if !models.isEmpty { row("Models", models.joined(separator: ", ")) }
            if session.latestContextTokens > 0 {
                let window = session.contextWindow(mode: contextWindowMode)
                row("Context", "\(Fmt.tokens(session.latestContextTokens)) of \(Fmt.window(window))")
            }
            if let v = session.claudeVersion { row("Claude Code", v) }
            row("File", "\(Fmt.bytes(session.fileSize)) · \(session.fileURL.lastPathComponent)")
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(3)
        }
    }
}

// MARK: - Conversation

private struct ConversationView: View {
    let items: [ConversationItem]
    let showNotes: Bool
    @Binding var jumpTarget: String?

    private var shown: [ConversationItem] {
        showNotes ? items : items.filter { if case .note = $0 { return false } else { return true } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(shown) { item in
                        ConversationItemView(item: item).id(item.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView_Compat(title: "No conversation yet", systemImage: "bubble.left.and.bubble.right",
                                                  message: "Messages appear here as the session runs.")
                }
            }
            .onAppear { scroll(proxy) }
            .onChange(of: jumpTarget) { _ in scroll(proxy) }
        }
    }

    /// To the requested item, else the newest one.
    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if let target = jumpTarget {
                proxy.scrollTo(target, anchor: .top)
                jumpTarget = nil
            } else if let last = shown.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .prompt(_, let date, let text):
            VStack(alignment: .leading, spacing: 6) {
                caption("You", date: date, icon: "person.crop.circle.fill", tint: .accentColor)
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)

        case .reply(_, let date, let model, let text):
            VStack(alignment: .leading, spacing: 6) {
                caption(model.map { "Claude · \(Fmt.model($0))" } ?? "Claude", date: date,
                        icon: "sparkle", tint: .orange)
                MarkdownText(text)
            }
            .padding(.horizontal, 4)

        case .activity(let activity):
            ActivityRow(activity: activity)

        case .note(_, _, let text):
            Text(text)
                .font(.caption)
                .italic()
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private func caption(_ title: String, date: Date?, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            if let date { Text(Fmt.full(date)).font(.caption).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.secondary)
    }
}

/// A stretch of tool work as one line; expands to the individual calls.
private struct ActivityRow: View {
    let activity: ConversationItem.Activity
    @State private var expanded = false

    private var summary: String {
        let counts = activity.toolCounts
        let calls = activity.callCount
        guard calls > 0 else { return "Thinking" }
        let names = counts.prefix(4).map { $0.count > 1 ? "\(Fmt.toolName($0.name)) ×\($0.count)" : Fmt.toolName($0.name) }
        let more = counts.count > 4 ? ", …" : ""
        return "\(calls) tool \(calls == 1 ? "call" : "calls") · " + names.joined(separator: ", ") + more
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: activity.hasError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .foregroundStyle(activity.hasError ? .orange : .secondary)
                    Text(summary).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(activity.blocks.enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

/// One tool call / result / thinking block, collapsed by default.
private struct BlockView: View {
    let block: TranscriptEvent.Block
    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let t):
            MarkdownText(t)
        case .thinking(let t):
            disclosure(title: "Thinking", systemImage: "brain", tint: .secondary) {
                Text(t).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .toolUse(let name, let input):
            disclosure(title: Fmt.toolName(name), systemImage: "terminal", tint: .indigo) {
                codeBlock(input)
            }
        case .toolResult(let text, let isError):
            disclosure(title: isError ? "Result (error)" : "Result",
                       systemImage: isError ? "exclamationmark.triangle" : "arrow.turn.down.right",
                       tint: isError ? .red : .green) {
                codeBlock(text)
            }
        case .image(let media):
            Label("Image (\(media))", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        case .note(let n):
            Text(n).font(.caption).foregroundStyle(.secondary).italic()
        }
    }

    @ViewBuilder
    private func disclosure<Content: View>(title: String, systemImage: String, tint: Color,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Label(title, systemImage: systemImage).font(.caption.weight(.medium))
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            if expanded { content() }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        CodeBlock(text: text.isEmpty ? "(empty)" : String(text.prefix(20_000)))
    }
}

// MARK: - Markdown rendering

/// Renders `Markdown.parse` blocks with native text styles.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) { blocks = Markdown.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Markdown.inline(text)).lineSpacing(2)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(Markdown.inline(text)).lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .code(_, let text):
            CodeBlock(text: text)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                Text(Markdown.inline(text)).foregroundStyle(.secondary).lineSpacing(2)
            }
        case .table(let header, let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Markdown.inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.inline(cell))
                        }
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
