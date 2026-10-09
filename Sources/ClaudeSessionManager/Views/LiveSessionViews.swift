import SwiftUI

/// Bottom of the detail pane for a session the app can drive: pending
/// approvals, a status line, and the message composer. Sending to a session
/// that isn't hosted yet resumes it headless first.
struct SessionComposer: View {
    let session: SessionSummary
    /// Called after a message goes out (the detail switches to Conversation).
    var onSent: () -> Void = {}

    @EnvironmentObject private var host: SessionHost
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let live = host.hosted(session.id) {
                LiveControls(hosted: live)
            }
            if let blocker = host.blocker(for: session.id), host.hosted(session.id) == nil {
                Label(blocker.readOnlyNote, systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(blocker.localizedDescription + " Close it there to continue in the app.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                composer
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(.bar)
    }

    /// Messages-style field: one line to start, grows to ~7, send button
    /// inside the trailing edge.
    private var composer: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Message Claude…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 20, maxHeight: 130)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(empty ? Color.secondary.opacity(0.4) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(empty)
            .help("Send (⌘↩)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = draft
        do {
            let live = try host.resume(session)
            live.send(text)
            draft = ""
            error = nil
            onSent()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Status, approvals and controls of a running hosted session.
struct LiveControls: View {
    @ObservedObject var hosted: HostedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hosted.pending) { request in
                RequestCard(request: request, cwd: hosted.cwd) { hosted.answer(request.id, $0) }
            }
            HStack(spacing: 10) {
                PhaseBadge(phase: hosted.phase)
                if !hosted.queued.isEmpty {
                    Label("\(hosted.queued.count) queued", systemImage: "tray.and.arrow.down")
                        .help("Sent once the open request is answered")
                }
                if let reason = hosted.exitReason {
                    Text(reason).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Picker("Mode", selection: Binding(get: { hosted.permissionMode },
                                                  set: { hosted.setPermissionMode($0) })) {
                    ForEach(PermissionModes.choices, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(hosted.phase == .exited)
                .help("Permission mode for this session")
                if hosted.phase == .running || hosted.phase == .waiting {
                    Button(role: .destructive) { hosted.interrupt() } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Interrupt the current turn")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

struct PhaseBadge: View {
    let phase: HostedSession.Phase

    var body: some View {
        switch phase {
        case .starting: Label("Starting…", systemImage: "hourglass")
        case .idle: Label("Ready", systemImage: "checkmark.circle")
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Claude is working…") }
        case .waiting: Label("Waiting for you", systemImage: "hand.raised.fill").foregroundStyle(.orange)
        case .exited: Label("Ended", systemImage: "stop.fill")
        }
    }
}

/// One approval / question / plan review.
struct RequestCard: View {
    let request: PendingRequest
    /// The session's folder, so paths can be shown relative to it.
    var cwd: String = ""
    let onDecision: (RequestDecision) -> Void

    @State private var denyReason = ""
    @State private var showDeny = false
    /// Question text → chosen labels.
    @State private var choices: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.kind {
            case .permission: permission
            case .question: question
            case .plan: plan
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
    }

    // MARK: Permission

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Allow \(Fmt.toolName(request.ask.displayName ?? request.ask.toolName))?").font(.headline)
            } icon: {
                Image(systemName: "hand.raised").foregroundStyle(.orange)
            }
            // The CLI's description often just repeats the file name; skip it then.
            if let d = request.ask.description, !d.isEmpty,
               d != request.ask.input["file_path"]?.stringValue.map({ ($0 as NSString).lastPathComponent }) {
                Text(d).foregroundStyle(.secondary)
            }
            ToolInputPreview(toolName: request.ask.toolName, input: request.ask.input, cwd: cwd)
            if let blocked = request.ask.blockedPath {
                Label("Outside the allowed folders: \(blocked)", systemImage: "folder.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showDeny {
                TextField("Tell Claude why (optional)", text: $denyReason)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onDecision(.deny(message: denyReason)) }
            }
            HStack {
                Button("Allow") { onDecision(.allow(always: false)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                if request.ask.suggestions != nil {
                    Button("Always Allow") { onDecision(.allow(always: true)) }
                        .help(alwaysHelp)
                }
                Spacer()
                Button(showDeny ? "Deny with Reason" : "Deny", role: .destructive) {
                    if showDeny || !denyReason.isEmpty { onDecision(.deny(message: denyReason)) }
                    else { showDeny = true }
                }
                if showDeny {
                    Button("Deny") { onDecision(.deny(message: "")) }
                }
            }
        }
    }

    /// What "Always Allow" will add, from the CLI's own suggestions.
    private var alwaysHelp: String {
        let rules = request.ask.suggestions?.arrayValue?.flatMap { s -> [String] in
            (s["rules"]?.arrayValue ?? []).compactMap { r in
                guard let tool = r["toolName"]?.stringValue else { return nil }
                return r["ruleContent"]?.stringValue.map { "\(tool)(\($0))" } ?? tool
            }
        } ?? []
        return rules.isEmpty ? "Don't ask again for this" : "Adds: " + rules.joined(separator: ", ")
    }

    // MARK: Question

    private var questions: [JSONValue] { request.ask.input["questions"]?.arrayValue ?? [] }

    private var question: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude has a question", systemImage: "questionmark.bubble").font(.headline)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let text = q["question"]?.stringValue ?? ""
                let multi = q["multiSelect"] == .bool(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).fontWeight(.medium)
                    ForEach(Array((q["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, opt in
                        let label = opt["label"]?.stringValue ?? ""
                        let selected = choices[text, default: []].contains(label)
                        Button {
                            var set = multi ? choices[text, default: []] : []
                            if selected { set.remove(label) } else { set.insert(label) }
                            choices[text] = set
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: selected ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                           : (multi ? "square" : "circle"))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(label)
                                    if let d = opt["description"]?.stringValue {
                                        Text(d).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Other…", text: Binding(get: { other[text, default: ""] }, set: { other[text] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button("Answer") { onDecision(.answer(answers)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answers.count < questions.count)
                Spacer()
                Button("Skip", role: .destructive) { onDecision(.deny(message: "The user skipped the question.")) }
            }
        }
    }

    /// Typed "Other" wins; multi-select joins labels the way the CLI does.
    private var answers: [String: String] {
        var result: [String: String] = [:]
        for q in questions {
            guard let text = q["question"]?.stringValue else { continue }
            let typed = other[text, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { result[text] = typed; continue }
            let picked = choices[text, default: []]
            if !picked.isEmpty { result[text] = picked.sorted().joined(separator: ", ") }
        }
        return result
    }

    // MARK: Plan

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Review Claude's plan", systemImage: "list.bullet.clipboard").font(.headline)
            ScrollView {
                MarkdownText(request.ask.input["plan"]?.stringValue ?? "")
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: 260)
            TextField("Feedback to keep planning (optional)", text: $denyReason)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Approve Plan") { onDecision(.approvePlan) }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Keep Planning") {
                    onDecision(.deny(message: denyReason.isEmpty ? "Keep planning." : denyReason))
                }
            }
        }
    }
}

/// The interesting part of a tool call's input: a command, a path, or the
/// old/new text of an edit.
struct ToolInputPreview: View {
    let toolName: String
    let input: JSONValue
    var cwd: String = ""

    var body: some View {
        switch toolName {
        case "Bash":
            code((input["command"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "Edit", "MultiEdit":
            VStack(alignment: .leading, spacing: 4) {
                path
                if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
                    DiffPreview(old: old, new: new)
                }
            }
        case "Write":
            VStack(alignment: .leading, spacing: 4) {
                path
                code(String((input["content"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)))
            }
        default:
            if let p = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
                pathLabel(p)
            } else if let data = try? JSONSerialization.data(withJSONObject: input.anyValue, options: [.prettyPrinted, .sortedKeys]),
                      let s = String(data: data, encoding: .utf8), s.count > 2 {
                code(String(s.prefix(1500)))
            }
        }
    }

    @ViewBuilder private var path: some View {
        if let p = input["file_path"]?.stringValue { pathLabel(p) }
    }

    /// One line, relative to the session folder (or ~), middle-truncated.
    private func pathLabel(_ p: String) -> some View {
        Label {
            Text(DisplayPath.short(p, relativeTo: cwd))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "doc").foregroundStyle(.secondary)
        }
        .help(p)
    }

    private func code(_ s: String) -> some View {
        ScrollView(.horizontal) {
            Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Removed lines in red, added in green — enough to judge an edit at a glance.
struct DiffPreview: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(line.removed ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var lines: [(text: String, removed: Bool)] {
        let o = old.components(separatedBy: "\n").prefix(40).map { ("- " + $0, true) }
        let n = new.components(separatedBy: "\n").prefix(40).map { ("+ " + $0, false) }
        return Array(o) + Array(n)
    }
}

/// The reply as it streams, before it lands in the transcript file.
struct LiveReplyView: View {
    @ObservedObject var hosted: HostedSession

    var body: some View {
        if !hosted.liveText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(.orange)
                    Text("Claude").font(.caption.weight(.semibold))
                    ProgressView().controlSize(.mini)
                }
                .foregroundStyle(.secondary)
                MarkdownText(hosted.liveText)
            }
            .padding(.horizontal, 4)
            .id("live")
        }
    }
}

/// Small sidebar/list indicator for a hosted session.
struct HostedDot: View {
    @ObservedObject var hosted: HostedSession

    var body: some View {
        switch hosted.phase {
        case .waiting:
            Circle().fill(Color.orange).frame(width: 7, height: 7).help("Waiting for your approval")
        case .running, .starting:
            Circle().fill(Color.green).frame(width: 7, height: 7).help("Claude is working")
        case .idle:
            Circle().stroke(Color.green, lineWidth: 1.5).frame(width: 7, height: 7).help("Hosted session, idle")
        case .exited:
            EmptyView()
        }
    }
}

/// "New Chat": a headless session started from the app, no terminal.
struct NewChatSheet: View {
    let defaultFolder: String
    let onStart: (_ folder: String, _ prompt: String, _ mode: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var prompt = ""
    @State private var mode = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Chat").font(.headline)
            HStack {
                TextField("Folder", text: $folder).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: folder)
                    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                }
            }
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Picker("Permissions", selection: $mode) {
                ForEach(PermissionModes.choices, id: \.id) { Text($0.label).tag($0.id) }
            }
            .fixedSize()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(folder, prompt, mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !FileManager.default.fileExists(atPath: folder))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { folder = defaultFolder }
    }
}

/// Shown while a new chat's transcript file doesn't exist yet: what was
/// asked, the reply as it streams, and any approval it needs.
struct StartingChatView: View {
    @ObservedObject var hosted: HostedSession
    /// The first message, as sent.
    var prompt: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Chat").font(.title3.weight(.semibold))
                Label(DisplayPath.short(hosted.cwd), systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hosted.cwd)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("You", systemImage: "person.crop.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    LiveReplyView(hosted: hosted)
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if hosted.liveText.isEmpty && hosted.pending.isEmpty && hosted.phase != .exited {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting session…") }
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            LiveControls(hosted: hosted).padding(.bottom, 10)
        }
    }
}

/// Permission modes the app offers (bypass stays out: it skips every check).
enum PermissionModes {
    struct Choice { let id: String; let label: String }
    static let choices = [
        Choice(id: "default", label: "Ask before edits"),
        Choice(id: "acceptEdits", label: "Accept edits"),
        Choice(id: "auto", label: "Auto"),
        Choice(id: "plan", label: "Plan only"),
    ]
    static let allowedRemotely: Set<String> = Set(choices.map(\.id))
}

/// Paths for display: relative to a folder when inside it, else with ~.
enum DisplayPath {
    static func short(_ path: String, relativeTo base: String = "") -> String {
        if !base.isEmpty {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
