import SwiftUI

@main
struct ClaudeSessionManagerApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup("Claude Session Manager") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 600)
                .task { await store.reload() }
                .onAppear {
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
