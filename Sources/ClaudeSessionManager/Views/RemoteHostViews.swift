import SwiftUI

/// Sheet for adding/managing SSH remote hosts (see `RemoteHostStore`).
struct RemoteHostsSheet: View {
    @EnvironmentObject var hostStore: RemoteHostStore
    @Environment(\.dismiss) private var dismiss

    @State private var newAlias = ""
    @State private var newDisplayName = ""
    @State private var newRoot = "~/.claude/projects"
    @State private var testResults: [String: Result<Void, Error>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Hosts")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 16)
            Text("Each host must already exist as a `Host` entry in ~/.ssh/config.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            List {
                ForEach(hostStore.hosts) { host in
                    RemoteHostRow(
                        host: host,
                        status: hostStore.syncStatus[host.id],
                        testResult: testResults[host.id],
                        onUpdate: { updated in hostStore.updateHost(updated) },
                        onTest: { Task { testResults[host.id] = await hostStore.testConnection(host) } },
                        onSync: { Task { await hostStore.sync(host) } },
                        onRemove: { hostStore.removeHost(host) }
                    )
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 120, maxHeight: 260)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Host").font(.headline)
                HStack {
                    TextField("Alias (e.g. devbox)", text: $newAlias)
                    TextField("Display name (optional)", text: $newDisplayName)
                }
                HStack {
                    TextField("Remote root", text: $newRoot)
                    Button("Add") {
                        hostStore.addHost(alias: newAlias, displayName: newDisplayName, remoteRoot: newRoot)
                        newAlias = ""; newDisplayName = ""; newRoot = "~/.claude/projects"
                    }
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)

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
        .frame(width: 520)
    }
}

private struct RemoteHostRow: View {
    let host: RemoteHost
    let status: HostSyncStatus?
    let testResult: Result<Void, Error>?
    let onUpdate: (RemoteHost) -> Void
    let onTest: () -> Void
    let onSync: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { host.enabled },
                set: { var h = host; h.enabled = $0; onUpdate(h) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName).font(.body.weight(.medium))
                Text("\(host.alias) · \(host.remoteRoot)")
                    .font(.caption).foregroundStyle(.secondary)
                statusLine
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Test") { onTest() }.buttonStyle(.link)
                    Button("Sync Now") { onSync() }.buttonStyle(.link)
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
        } else if case .success = testResult {
            Label("Connection OK", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        }
    }
}

/// Prompt for a remote directory before starting a brand-new session on a host.
struct RemoteNewSessionSheet: View {
    let host: RemoteHost
    let onStart: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session on \(host.displayName)")
                .font(.title3.weight(.semibold))
            Text("Enter the working directory on \(host.alias) to start Claude in.")
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
    }

    private func start() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return }
        onStart(dir)
        dismiss()
    }
}
