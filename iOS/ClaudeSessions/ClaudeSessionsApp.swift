import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @StateObject private var hosts = HostStore()
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase
    /// A pairing link opened from outside (QR in the Camera app, a pasted URL).
    @State private var incomingLink: PairingLink?

    var body: some Scene {
        WindowGroup {
            RootView(incomingLink: $incomingLink)
                .environmentObject(hosts)
                .environmentObject(client)
                .onOpenURL { url in incomingLink = PairingLink(url.absoluteString) }
                .onAppear { connectIfPaired() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { client.reconnectNow() }
                }
        }
    }

    private func connectIfPaired() {
        guard let host = hosts.current, let token = hosts.token(for: host) else { return }
        client.connect(to: host, token: token)
    }
}

struct RootView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var client: RemoteClient
    @Binding var incomingLink: PairingLink?

    var body: some View {
        Group {
            if hosts.current == nil {
                WelcomeView()
            } else {
                SessionsView()
            }
        }
        .sheet(item: Binding(get: { incomingLink.map(IdentifiedLink.init) }, set: { incomingLink = $0?.link })) { item in
            PairingView(initialLink: item.link)
        }
    }
}

struct IdentifiedLink: Identifiable {
    let link: PairingLink
    var id: String { link.fingerprint + link.code }
}
