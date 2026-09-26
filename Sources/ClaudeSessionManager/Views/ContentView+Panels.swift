import SwiftUI
import AppKit

extension ContentView {
    // MARK: - Open panels

    /// Import an existing skill folder (containing SKILL.md) into ~/.claude/skills.
    func importSkillFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a skill folder (must contain SKILL.md)"
        if panel.runModal() == .OK, let url = panel.url {
            if let created = skills.importSkill(from: url) {
                store.viewMode = .skills
                selectedSkill = created.id
            }
        }
    }

    /// Pick a folder (remembered as the new default), then start a session there.
    func chooseFolderAndStartNewSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        panel.message = "Choose the working directory for the new Claude session"
        panel.directoryURL = URL(fileURLWithPath: store.newSessionDir)
        if panel.runModal() == .OK, let url = panel.url {
            store.newSessionDir = url.path   // remember as the new default
            createNewSession(in: url)
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.rootURL
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            store.rootPath = url.path
        }
    }
}
