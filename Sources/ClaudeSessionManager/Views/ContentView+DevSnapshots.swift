import SwiftUI
import AppKit

extension ContentView {
    // Dev-only hooks driven by CSM_* environment variables (see docs/ and
    // SelfSnapshot); none of these run in normal use.

    /// When launched in snapshot mode, pick the first session so the detail pane
    /// shows a real transcript in the captured image.
    func autoSelectForSnapshot() {
        guard ProcessInfo.processInfo.environment["CSM_SNAPSHOT"] != nil else { return }
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
}
