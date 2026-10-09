import SwiftUI

/// The session list, grouped like the Mac sidebar (category › group, else
/// project), with live status; splits into list + detail on iPad.
struct SessionsView: View {
    @EnvironmentObject private var client: RemoteClient
    @EnvironmentObject private var hosts: HostStore
    @State private var selection: String?
    @State private var search = ""
    @State private var showNew = false
    @State private var showSettings = false

    private struct Section: Identifiable {
        let id: String
        let title: String
        var sessions: [RemoteSessionInfo]
    }

    private var filtered: [RemoteSessionInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return client.sessions }
        return client.sessions.filter {
            $0.title.lowercased().contains(q) || ($0.lastPrompt?.lowercased().contains(q) ?? false)
                || $0.project.lowercased().contains(q) || ($0.group?.lowercased().contains(q) ?? false)
        }
    }

    /// Sessions needing an answer first, then by category/group/project.
    private var sections: [Section] {
        var out: [Section] = []
        let waiting = filtered.filter { $0.hostedPhase == .waiting }
        if !waiting.isEmpty { out.append(Section(id: "waiting", title: "Needs You", sessions: waiting)) }
        var order: [String] = []
        var byKey: [String: Section] = [:]
        for s in filtered where s.hostedPhase != .waiting {
            let title = [s.category, s.group ?? s.project].compactMap { $0 }.joined(separator: " › ")
            if byKey[title] == nil { order.append(title); byKey[title] = Section(id: title, title: title, sessions: []) }
            byKey[title]!.sessions.append(s)
        }
        return out + order.compactMap { byKey[$0] }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sections) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(section.sessions, id: \.id) { s in
                            SessionRowView(session: s).tag(s.id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search sessions")
            .refreshable { client.refreshSessions() }
            .navigationTitle(client.hostName ?? "Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { ConnectionBadge(state: client.state) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(client.state != .connected)
                }
            }
            .overlay {
                if client.sessions.isEmpty {
                    switch client.state {
                    case .connected: ContentUnavailableView("No sessions", systemImage: "tray")
                    case .failed(let m): ContentUnavailableView("Can't connect", systemImage: "wifi.exclamationmark",
                                                                description: Text(m))
                    default: ProgressView("Connecting to your Mac…")
                    }
                }
            }
        } detail: {
            if let id = selection, let info = client.sessions.first(where: { $0.id == id }) {
                SessionDetailView(info: info)
                    .id(id)
            } else if selection != nil {
                // Just started from here; the list catches up in a moment.
                ProgressView("Starting…").task { client.refreshSessions() }
            } else {
                ContentUnavailableView("Pick a session", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $showNew) {
            NewSessionView { id in selection = id }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct SessionRowView: View {
    let session: RemoteSessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(Fmt.relative(session.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            if let p = session.lastPrompt, p != session.title {
                Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 10) {
                if let g = session.group {
                    Label { Text(g) } icon: {
                        Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(GroupColor.color(for: g))
                    }
                } else {
                    Label(session.project, systemImage: "folder")
                }
                StatusBadge(session: session)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let session: RemoteSessionInfo

    var body: some View {
        if let elsewhere = session.busyElsewhere {
            Label("In \(elsewhere)", systemImage: "lock").foregroundStyle(.secondary)
        } else {
            switch session.hostedPhase {
            case .waiting?: Label("Needs you", systemImage: "hand.raised.fill").foregroundStyle(.orange)
            case .running?, .starting?: Label("Working", systemImage: "circle.fill").foregroundStyle(.green)
            default: EmptyView()
            }
        }
    }
}

struct ConnectionBadge: View {
    let state: RemoteClient.State

    var body: some View {
        switch state {
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: ProgressView()
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                if let host = hosts.current {
                    SwiftUI.Section("Mac") {
                        LabeledContent("Name", value: client.hostName ?? host.name)
                        LabeledContent("Status", value: statusText)
                        LabeledContent("Addresses", value: host.addresses.joined(separator: ", "))
                        LabeledContent("Port", value: String(host.port))
                        LabeledContent("Security code", value: host.securityCode)
                    }
                    SwiftUI.Section {
                        Button("Reconnect") { client.reconnectNow() }
                        Button("Unpair This Mac", role: .destructive) { confirmUnpair = true }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    if let host = hosts.current {
                        client.disconnect()
                        hosts.remove(host)
                    }
                    dismiss()
                }
            } message: {
                Text("You'll need a new pairing code to connect again. Revoke the device on the Mac too.")
            }
        }
    }

    private var statusText: String {
        switch client.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed(let m): return m
        case .idle: return "Not connected"
        }
    }
}
