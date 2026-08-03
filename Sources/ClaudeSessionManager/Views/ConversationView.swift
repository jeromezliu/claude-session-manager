import SwiftUI

/// Native chat UI for a session: streams turns from `ConversationEngine`,
/// renders them with the same `EventView` the transcript uses, and offers an
/// input box plus model / permission pickers docked at the bottom.
struct ConversationView: View {
    @ObservedObject var engine: ConversationEngine
    var onOpenTerminal: () -> Void
    /// Concrete model ids seen in the user's sessions (most recent first).
    var availableModels: [String] = []

    @ObservedObject private var capabilities = CLICapabilities.shared
    @ObservedObject private var modelStore = ModelStore.shared
    @State private var input = ""
    @State private var slashCommands: [SlashCommand] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            if let error = engine.errorText {
                errorBar(error)
            }
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(engine.session.workingDirectory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button { onOpenTerminal() } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open this session in the raw terminal instead")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visibleMessages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 34))
                                .foregroundStyle(.tertiary)
                            Text(engine.isSupported ? "Start the conversation"
                                                     : "Conversation mode is local-only")
                                .font(.title3.weight(.semibold))
                            Text(engine.isSupported
                                 ? "Type below to continue this session with Claude."
                                 : "Open this session in the terminal to continue it on its remote host.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, event in
                        let prev = index > 0 ? visibleMessages[index - 1] : nil
                        let sameSpeaker = prev?.kind == event.kind
                        ChatTurnView(event: event, showSpeaker: !sameSpeaker)
                            .padding(.top, sameSpeaker ? DS.groupGap : DS.turnGap)
                            .id(event.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, DS.gutter)
                .padding(.vertical, DS.gutter)
            }
            .onChange(of: engine.messages.count) { _ in scrollToBottom(proxy) }
            .onAppear {
                scrollToBottom(proxy, animated: false)
                modelStore.loadIfNeeded()
                snapDefaultModel()
                slashCommands = SlashCommandCatalog.commands(projectDir: engine.session.workingDirectory)
            }
            .onChange(of: modelStore.models.count) { _ in snapDefaultModel() }
        }
    }

    private static let bottomAnchor = "conversation-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Activity banner

    @ViewBuilder
    private var activityBanner: some View {
        if engine.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(engine.phase.isEmpty ? "Working…" : engine.phase)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !engine.queued.isEmpty {
                    Text("· \(engine.queued.count) queued")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.elapsedLabel(engine.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
        }
    }

    /// The real, concrete models to offer: the live Models-API list when we
    /// have it, otherwise the concrete ids seen in the user's own sessions.
    /// No `default` / `(latest)` aliases — those are only a last-resort tag for
    /// a brand-new session whose model isn't chosen yet.
    private var pickerModels: [ModelStore.Model] {
        if !modelStore.models.isEmpty { return modelStore.models }
        return availableModels.map { .init(id: $0, display: ModelCatalog.label(for: $0)) }
    }

    /// A brand-new session starts on the CLI's `default`; once the real list is
    /// known, snap it to a concrete model (the user's most-recent one, else the
    /// newest available) so the picker never shows the word "Default".
    private func snapDefaultModel() {
        guard engine.model == "default" else { return }
        let preferred = availableModels.first { id in modelStore.models.contains { $0.id == id } }
            ?? modelStore.models.first?.id
        if let preferred { engine.model = preferred }
    }

    /// Conversation mode always hides non-conversation activity (no toggle):
    /// only real user/assistant prose shows, and tool/thinking blocks are
    /// stripped from otherwise-visible turns. What Claude is *doing* is
    /// reported by the activity banner instead, and the full detail stays
    /// available in the transcript (terminal) view's eye toggle.
    private var visibleMessages: [TranscriptEvent] {
        engine.messages.compactMap { event in
            let textOnly = event.blocks.filter {
                if case .text = $0 { return true } else { return false }
            }
            guard !textOnly.isEmpty else { return nil }
            return TranscriptEvent(id: event.id, kind: event.kind, timestamp: event.timestamp,
                                   model: event.model, blocks: textOnly)
        }
    }

    /// CLI-reported modes, plus the session's current mode if the installed CLI
    /// no longer lists it — a Picker with no matching tag renders blank.
    private var modeChoices: [String] {
        var modes = capabilities.permissionModes
        if !modes.contains(engine.permissionMode) {
            modes.insert(engine.permissionMode, at: 0)
        }
        return modes
    }

    private static func elapsedLabel(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    private func errorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer()
            Button { engine.errorText = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.red.opacity(0.08))
    }

    // MARK: - Bottom bar (activity + input + pickers)

    private var bottomBar: some View {
        VStack(spacing: 8) {
            activityBanner
            if !slashSuggestions.isEmpty { slashSuggestionList }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(engine.isSupported ? "Message Claude…  ⌘↩ to send · / commands · ! bash"
                                              : "Conversation mode is local-only",
                          text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.rControl))
                    .disabled(!engine.isSupported)
                    .onSubmit(sendIfPossible)

                if engine.isRunning {
                    Button(role: .destructive) { engine.stop() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop the current turn")
                }
                Button(action: sendIfPossible) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!engine.isSupported || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Picker("Model", selection: $engine.model) {
                    ForEach(pickerModels) { Text($0.display).tag($0.id) }
                    // Keep the current selection valid so the picker never blanks.
                    if !pickerModels.contains(where: { $0.id == engine.model }) {
                        Text(ModelCatalog.label(for: engine.model)).tag(engine.model)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Model for new turns — the real models your account can use")

                Picker("Permissions", selection: $engine.permissionMode) {
                    ForEach(modeChoices, id: \.self) { mode in
                        Text(PermissionModeCatalog.label(for: mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("How tool use is governed this turn")

                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Commands to suggest right now: shown while the input is a partial `/name`
    /// (a slash, no space yet), filtered by what's typed.
    private var slashSuggestions: [SlashCommand] {
        guard engine.isSupported, input.hasPrefix("/"),
              !input.contains(" "), !input.contains("\n") else { return [] }
        let q = input.dropFirst().lowercased()
        let matches = q.isEmpty ? slashCommands
                                : slashCommands.filter { $0.name.lowercased().hasPrefix(q) }
        return Array(matches.prefix(8))
    }

    /// Autocomplete popover that floats above the input as you type `/…`.
    /// Clicking a row completes the command; keep typing to filter.
    private var slashSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashSuggestions) { cmd in
                Button { input = cmd.invocation + " " } label: {
                    HStack(spacing: 8) {
                        Text(cmd.invocation)
                            .font(.callout.monospaced())
                        if let d = cmd.description, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(cmd.scope).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.rControl))
        .overlay(RoundedRectangle(cornerRadius: DS.rControl).stroke(Color.secondary.opacity(0.2)))
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func sendIfPossible() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.isSupported else { return }
        engine.send(text)
        input = ""
    }
}
