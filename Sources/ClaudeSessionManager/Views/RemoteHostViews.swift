import SwiftUI
import AppKit

/// Sheet for adding/managing SSH remote hosts (see `RemoteHostStore`).
/// Connection details (host, port, user, key file or password) are configured
/// entirely here — nothing is read from ~/.ssh/config.
struct RemoteHostsSheet: View {
    @EnvironmentObject var hostStore: RemoteHostStore
    @Environment(\.dismiss) private var dismiss

    /// Host currently loaded into the form for editing (nil = adding a new one).
    @State private var editingID: String?
    @State private var displayName = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: RemoteHost.AuthMethod = .privateKey
    @State private var password = ""
    @State private var identityFile = ""
    @State private var remoteRoot = "~/.claude/projects"
    @State private var defaultDirectory = ""
    @State private var testResults: [String: Result<Void, Error>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Hosts")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 16)
            Text("Sessions on each host are mirrored locally and stay in sync. Passwords are kept in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if hostStore.hosts.isEmpty {
                Text("No hosts yet — add your first one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(hostStore.hosts) { host in
                        RemoteHostRow(
                            host: host,
                            status: hostStore.syncStatus[host.id],
                            testResult: testResults[host.id],
                            isEditing: editingID == host.id,
                            onUpdate: { updated in hostStore.updateHost(updated) },
                            onTest: { Task { testResults[host.id] = await hostStore.testConnection(host) } },
                            onSync: { Task { await hostStore.sync(host) } },
                            onEdit: { beginEditing(host) },
                            onRemove: {
                                if editingID == host.id { resetForm() }
                                hostStore.removeHost(host)
                            }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 100, maxHeight: 200)
            }

            Divider()

            hostForm

            Divider()
            HStack {
                if let error = hostStore.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580)
    }

    // MARK: - Add / edit form

    private var editingName: String {
        editingID.flatMap { hostStore.host(withID: $0)?.displayName } ?? ""
    }

    private var hostForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingID == nil ? "Add Host" : "Edit “\(editingName)”")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    fieldLabel("Host")
                    HStack(spacing: 6) {
                        TextField("hostname or IP", text: $hostname)
                        Text("Port").font(.caption).foregroundStyle(.secondary)
                        TextField("22", text: $port).frame(width: 56)
                    }
                }
                GridRow {
                    fieldLabel("Username")
                    TextField("login user on the host", text: $username)
                }
                GridRow {
                    fieldLabel("Display name")
                    TextField("optional — how this host is labeled in the app", text: $displayName)
                }
                GridRow {
                    fieldLabel("Authentication")
                    Picker("", selection: $authMethod) {
                        ForEach(RemoteHost.AuthMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                GridRow {
                    fieldLabel(authMethod == .privateKey ? "Key file" : "Password")
                    switch authMethod {
                    case .privateKey:
                        HStack(spacing: 6) {
                            TextField("blank = default keys & ssh-agent", text: $identityFile)
                            Button("Browse…") { browseForIdentityFile() }
                        }
                    case .password:
                        SecureField(editingID == nil ? "stored in your Keychain" : "blank = keep current password",
                                    text: $password)
                    }
                }
                GridRow {
                    fieldLabel("Sessions folder")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("~/.claude/projects", text: $remoteRoot)
                        Text("Where Claude stores its sessions on the host.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    fieldLabel("New session dir")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("e.g. ~/projects (optional)", text: $defaultDirectory)
                        Text("Pre-filled working directory when starting a new session on this host.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Spacer()
                if editingID != nil {
                    Button("Cancel") { resetForm() }
                }
                Button(editingID == nil ? "Add Host" : "Save Changes") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func beginEditing(_ host: RemoteHost) {
        editingID = host.id
        displayName = host.displayName
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        identityFile = host.identityFile
        remoteRoot = host.remoteRoot
        defaultDirectory = host.defaultWorkingDirectory
        password = ""
    }

    private func resetForm() {
        editingID = nil
        displayName = ""; hostname = ""; port = "22"; username = ""
        authMethod = .privateKey; password = ""; identityFile = ""
        remoteRoot = "~/.claude/projects"; defaultDirectory = ""
    }

    private func submit() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostField = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = RemoteHost(
            id: editingID ?? UUID().uuidString,
            displayName: name.isEmpty ? hostField : name,
            hostname: hostField,
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? -1,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            identityFile: identityFile.trimmingCharacters(in: .whitespacesAndNewlines),
            remoteRoot: root.isEmpty ? "~/.claude/projects" : root,
            defaultWorkingDirectory: defaultDirectory.trimmingCharacters(in: .whitespacesAndNewlines))

        if let id = editingID, let existing = hostStore.host(withID: id) {
            draft.enabled = existing.enabled
            hostStore.updateHost(draft, password: password.isEmpty ? nil : password)
        } else {
            hostStore.addHost(draft, password: password.isEmpty ? nil : password)
        }
        if hostStore.errorMessage == nil { resetForm() }
    }

    private func browseForIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // keys usually live in ~/.ssh
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "Choose the private key / certificate file for this host"
        if panel.runModal() == .OK, let url = panel.url {
            identityFile = url.path
        }
    }
}

private struct RemoteHostRow: View {
    let host: RemoteHost
    let status: HostSyncStatus?
    let testResult: Result<Void, Error>?
    let isEditing: Bool
    let onUpdate: (RemoteHost) -> Void
    let onTest: () -> Void
    let onSync: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { host.enabled },
                set: { var h = host; h.enabled = $0; onUpdate(h) }
            ))
            .labelsHidden()
            .help(host.enabled ? "Enabled — sessions are shown and synced" : "Disabled — sessions hidden, no syncing")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName).font(.body.weight(.medium))
                    Text(host.authMethod.label)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Text(host.endpoint)
                    .font(.caption).foregroundStyle(.secondary)
                statusLine
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Test") { onTest() }.buttonStyle(.link)
                        .help("Check that the app can connect and authenticate")
                    Button("Sync Now") { onSync() }.buttonStyle(.link)
                        .help("Mirror this host's sessions to the local cache now")
                    Button(isEditing ? "Editing…" : "Edit") { onEdit() }
                        .buttonStyle(.link)
                        .disabled(isEditing)
                }
                Button(role: .destructive) { onRemove() } label: { Text("Remove") }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status?.phase {
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        default:
            if let last = status?.lastSyncedAt {
                Label("Synced \(Fmt.relative(last))", systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("Not synced yet", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if case .failure(let error) = testResult {
            Label("Test failed: \(error.localizedDescription)", systemImage: "wifi.exclamationmark")
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                .help(error.localizedDescription)
        } else if case .success = testResult {
            Label("Connection OK", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        }
    }
}

/// Prompt for a remote directory before starting a brand-new session on a host.
/// Pre-filled with the host's default working directory when one is set.
struct RemoteNewSessionSheet: View {
    let host: RemoteHost
    let onStart: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: String

    init(host: RemoteHost, onStart: @escaping (String) -> Void) {
        self.host = host
        self.onStart = onStart
        _directory = State(initialValue: host.defaultWorkingDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session on \(host.displayName)")
                .font(.title3.weight(.semibold))
            Text("Working directory on \(host.endpoint) to start Claude in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. ~/projects/myapp", text: $directory)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        // A sheet's @State can survive re-presentation, so the initial value
        // set in init doesn't reliably apply — refresh the pre-fill each time
        // the sheet actually appears.
        .onAppear { directory = host.defaultWorkingDirectory }
    }

    private func start() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return }
        onStart(dir)
        dismiss()
    }
}
