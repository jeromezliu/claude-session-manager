import SwiftUI

@main
struct ClaudeSessionManagerApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var skills = SkillStore()

    var body: some Scene {
        WindowGroup("Claude Session Manager") {
            ContentView()
                .environmentObject(store)
                .environmentObject(skills)
                .frame(minWidth: 960, minHeight: 600)
                .task { await store.reload() }
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
