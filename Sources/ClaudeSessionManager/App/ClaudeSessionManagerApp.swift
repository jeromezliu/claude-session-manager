import SwiftUI

@main
struct ClaudeSessionManagerApp: App {
    @StateObject private var remoteHosts: RemoteHostStore
    @StateObject private var store: SessionStore
    @StateObject private var skills: SkillStore
    @StateObject private var host = SessionHost()

    init() {
        let remoteHostStore = RemoteHostStore()
        _remoteHosts = StateObject(wrappedValue: remoteHostStore)
        _store = StateObject(wrappedValue: SessionStore(remoteHosts: remoteHostStore))
        _skills = StateObject(wrappedValue: SkillStore(remoteHosts: remoteHostStore))
    }

    var body: some Scene {
        WindowGroup("Claude Session Manager") {
            ContentView()
                .environmentObject(store)
                .environmentObject(skills)
                .environmentObject(remoteHosts)
                .environmentObject(host)
                // Hosted claude processes end with the app.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    host.stopAll()
                }
                .frame(minWidth: 960, minHeight: 600)
                .task { await store.reload() }
                // Groups / titles may have changed in Claude Desktop meanwhile.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.refreshQuietly() }
                }
                .onAppear {
                    skills.start()
                    SelfSnapshot.runIfRequested()
                    SelfTest.runIfRequested()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await store.reload() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
