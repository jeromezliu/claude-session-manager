import SwiftUI

struct TranscriptView: View {
    enum Mode { case active, trashed }

    let session: SessionSummary
    var mode: Mode = .active
    var deletedNote: String? = nil
    var onContinue: () -> Void = {}
    var onRecover: () -> Void = {}
    var onPurge: () -> Void = {}

    @State private var events: [TranscriptEvent] = []
    @State private var loading = true
    @State private var watcher: FileWatcher?
    @AppStorage("showToolActivity") private var showToolActivity = false
    @AppStorage("contextWindowMode") private var contextWindowMode = "auto"

    /// Events for display: newest first, and (by default) only real conversation
    /// turns — attachments, system, meta and tool-only turns are hidden.
    private var displayedEvents: [TranscriptEvent] {
        let base = showToolActivity ? events : events.filter { event in
            event.blocks.contains { if case .text = $0 { return true } else { return false } }
        }
        return base.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedEvents.isEmpty {
                ContentUnavailableView_Compat(
                    title: events.isEmpty ? "Empty transcript" : "No conversation to show",
                    systemImage: "doc",
                    message: events.isEmpty
                        ? "No renderable messages in this session."
                        : "Only tool/system activity here — toggle the eye icon to show it."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(displayedEvents) { event in
                            EventView(event: event)
                        }
                    }
                    .padding(16)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(session.workingDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let deletedNote {
                        Label(deletedNote, systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { showToolActivity.toggle() } label: {
                        Image(systemName: showToolActivity ? "eye.fill" : "eye.slash")
                    }
                    .help(showToolActivity ? "Hide tool & system activity" : "Show tool & system activity")
                    headerActions
                }
            }

            // Metadata chips
            FlowChips(chips: chips)
        }
        .padding(16)
    }

    @ViewBuilder
    private var headerActions: some View {
        switch mode {
        case .active:
            Button(action: onContinue) {
                Label("Continue", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Resume this session in an internal terminal")
        case .trashed:
            HStack(spacing: 8) {
                Button(action: onRecover) {
                    Label("Recover", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .help("Restore this session to its original location")
                Button(role: .destructive, action: onPurge) {
                    Label("Delete Permanently", systemImage: "trash")
                }
                .help("Permanently delete this session")
            }
        }
    }

    private var chips: [String] {
        var c: [String] = []
        c.append("\(session.messageCount) messages")
        if session.latestContextTokens > 0 {
            let window = session.contextWindow(mode: contextWindowMode)
            let pct = Int((Double(session.latestContextTokens) / Double(max(window, 1))) * 100)
            c.append("context \(Fmt.tokens(session.latestContextTokens))/\(Fmt.window(window)) · \(pct)%")
        }
        if let branch = session.gitBranch, branch != "HEAD" { c.append("⎇ \(branch)") }
        if !session.models.isEmpty { c.append(session.models.map(Fmt.model).joined(separator: ", ")) }
        if session.totalOutputTokens > 0 { c.append("\(Fmt.tokens(session.totalOutputTokens)) out tokens") }
        if let v = session.claudeVersion { c.append("v\(v)") }
        c.append("created \(Fmt.full(session.createdAt))")
        c.append("updated \(Fmt.relative(session.modifiedAt))")
        c.append(Fmt.bytes(session.fileSize))
        c.append(session.id)
        return c
    }

    private func load() async {
        loading = true
        let url = session.fileURL
        let parsed = await Task.detached(priority: .userInitiated) {
            SessionParser.transcript(for: url)
        }.value
        events = parsed
        loading = false
    }

    /// Silent re-parse (no spinner) used when the file changes on disk.
    private func reload() async {
        let url = session.fileURL
        let parsed = await Task.detached(priority: .userInitiated) {
            SessionParser.transcript(for: url)
        }.value
        events = parsed
    }
}

// MARK: - Event rendering

private struct EventView: View {
    let event: TranscriptEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(roleLabel).font(.caption.weight(.semibold)).foregroundStyle(color)
                if let model = event.model { Text(Fmt.model(model)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if let ts = event.timestamp {
                    Text(Fmt.full(ts)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(event.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.15), lineWidth: 1))
    }

    private var roleLabel: String { event.kind.label }

    private var color: Color {
        switch event.kind {
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .orange
        case .attachment: return .teal
        case .meta: return .gray
        }
    }
}

private struct BlockView: View {
    let block: TranscriptEvent.Block
    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let t):
            Text(t)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let t):
            disclosure(title: "Thinking", systemImage: "brain", tint: .secondary) {
                Text(t).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

        case .toolUse(let name, let input):
            disclosure(title: "Tool · \(name)", systemImage: "wrench.and.screwdriver", tint: .indigo) {
                codeBlock(input)
            }

        case .toolResult(let text, let isError):
            disclosure(title: isError ? "Tool result (error)" : "Tool result",
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
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Label(title, systemImage: systemImage).font(.caption.weight(.medium))
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)

            if expanded { content() }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Simple wrapping row of small pill labels.
private struct FlowChips: View {
    let chips: [String]

    var body: some View {
        FlexWrap(spacing: 6, lineSpacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A lightweight wrapping HStack (avoids depending on newer Layout-only APIs).
private struct FlexWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
