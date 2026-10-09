import SwiftUI
import AppKit

extension ContentView {
    // Dev-only hooks driven by CSM_* environment variables (see docs/ and
    // SelfSnapshot); none of these run in normal use.

    /// When launched in snapshot mode, pick the first session so the detail pane
    /// shows a real transcript in the captured image.
    func autoSelectForSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard env["CSM_SNAPSHOT"] != nil else { return }
        // CSM_SNAPSHOT_SESSION picks a specific session (e.g. an idle one, to show the composer).
        if let id = env["CSM_SNAPSHOT_SESSION"], store.visibleSession(withID: id) != nil {
            selectedSessions = [id]
            return
        }
        guard selectedSessions.isEmpty, let session = store.sections.first?.sessions.first else { return }
        selectedSessions = [session.id]
    }

    /// Dev-only: open a terminal for the first session and snapshot that window.
    func maybeTerminalSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_SNAPSHOT_TERM"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let session = store.sections.first?.sessions.first {
                selectedSessions = [session.id]
                store.continueSession(session)
            }
            if ProcessInfo.processInfo.environment["CSM_TERM_MAX"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { terminalMaximized = true }
            }
            if ProcessInfo.processInfo.environment["CSM_TERM_POPOUT"] == "1",
               let s = store.sections.first?.sessions.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    terminals.session(for: s.id)?.popOut()
                    if ProcessInfo.processInfo.environment["CSM_TERM_POPIN"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            terminals.session(for: s.id)?.popIn()
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Dev-only: create a new session and snapshot the embedded detail pane.
    func maybeNewSessionSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_NEWSESSION_SNAP"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            createNewSession(in: URL(fileURLWithPath: NSHomeDirectory()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
            }
        }
    }

    /// Dev-only: open the Skills tab, select the first skill, and snapshot.
    func maybeSkillsSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CSM_SKILLS_SNAP"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            store.viewMode = .skills
            selectedSkill = skills.skills.first?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
            }
        }
    }

    /// Dev-only: start a headless chat (CSM_CHAT_DIR, CSM_CHAT_PROMPT,
    /// CSM_CHAT_MODEL) and snapshot once it asks for approval (or after 60s).
    func maybeChatSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CSM_CHAT_SNAP"], !path.isEmpty, let dir = env["CSM_CHAT_DIR"] else { return }
        SelfSnapshot.bringToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let chat: HostedSession
            do {
                chat = try host.startNew(in: dir, prompt: env["CSM_CHAT_PROMPT"] ?? "Say hi", model: env["CSM_CHAT_MODEL"])
            } catch {
                FileHandle.standardError.write(Data("CSM chat snapshot: couldn't start: \(error.localizedDescription)\n".utf8))
                return
            }
            FileHandle.standardError.write(Data("CSM chat snapshot: started in \(dir)\n".utf8))
            startingPrompt = env["CSM_CHAT_PROMPT"] ?? "Say hi"
            startingChat = chat
            Task { @MainActor in
                for _ in 0..<120 where chat.pending.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                SelfSnapshot.captureKeyWindow(to: URL(fileURLWithPath: path))
                if env["CSM_SNAPSHOT_QUIT"] == "1" { host.stopAll(); NSApp.terminate(nil) }
            }
        }
    }
}
