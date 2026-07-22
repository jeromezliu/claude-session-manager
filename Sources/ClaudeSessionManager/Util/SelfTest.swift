import AppKit
import Foundation

/// End-to-end check of the trash pipeline (trash → list → recover → purge) on a
/// synthetic session. Gated behind `CSM_SELFTEST=1`; writes a PASS/FAIL log to
/// `CSM_SELFTEST_OUT` and quits. Never runs in normal use.
enum SelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CSM_SELFTEST"] == "1" else { return }
        Task {
            let log = await run()
            let out = ProcessInfo.processInfo.environment["CSM_SELFTEST_OUT"] ?? "/tmp/csm_selftest.txt"
            try? log.write(toFile: out, atomically: true, encoding: .utf8)
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    private static func run() async -> String {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL") \(name)") }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("csm-selftest-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmp.appendingPathComponent("-tmp-fakeproj", isDirectory: true)
        let id = UUID().uuidString
        let fileURL = projectDir.appendingPathComponent(id).appendingPathExtension("jsonl")

        do {
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let content = """
            {"type":"user","message":{"role":"user","content":"hello selftest"},"cwd":"/tmp/fakeproj","sessionId":"\(id)","timestamp":"2026-07-14T10:00:00.000Z"}
            {"type":"ai-title","aiTitle":"Self Test Session","sessionId":"\(id)"}
            """
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            // 1. Parse
            guard let summary = SessionParser.summary(for: fileURL) else {
                return (lines + ["FAIL parse-summary (nil)"]).joined(separator: "\n")
            }
            check("parse-title", summary.title == "Self Test Session")
            check("parse-messageCount", summary.messageCount == 1)

            // 2. Trash
            try await TrashManager.trash(summary)
            check("trash-original-removed", !fm.fileExists(atPath: fileURL.path))

            // 3. List
            let listed = TrashManager.list()
            guard let entry = listed.first(where: { $0.originalPath == fileURL.path }) else {
                return (lines + ["FAIL trash-list (entry not found)"]).joined(separator: "\n")
            }
            check("trash-list-found", true)
            check("trash-file-exists", fm.fileExists(atPath: entry.trashedURL.path))
            check("trash-meta-exists", fm.fileExists(atPath: entry.metaURL.path))
            check("trash-title-preserved", entry.summary.title == "Self Test Session")

            // 4. Recover
            let restored = try await TrashManager.recover(entry)
            check("recover-back-at-original", fm.fileExists(atPath: fileURL.path))
            check("recover-returns-original-path", restored.path == fileURL.path)
            check("recover-trash-file-gone", !fm.fileExists(atPath: entry.trashedURL.path))
            check("recover-removed-from-list", !TrashManager.list().contains { $0.originalPath == fileURL.path })

            // 5. Trash again, then purge permanently
            guard let summary2 = SessionParser.summary(for: fileURL) else {
                return (lines + ["FAIL reparse-after-recover"]).joined(separator: "\n")
            }
            try await TrashManager.trash(summary2)
            guard let entry2 = TrashManager.list().first(where: { $0.originalPath == fileURL.path }) else {
                return (lines + ["FAIL retrash-list"]).joined(separator: "\n")
            }
            try TrashManager.purge(entry2)
            check("purge-file-gone", !fm.fileExists(atPath: entry2.trashedURL.path))
            check("purge-meta-gone", !fm.fileExists(atPath: entry2.metaURL.path))
            check("purge-removed-from-list", !TrashManager.list().contains { $0.originalPath == fileURL.path })

            try? fm.removeItem(at: tmp)

            // 6. Ephemeral filtering against the real projects dir
            let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
            if let withTemp = try? SessionStore.scan(root: root, includeTemp: true),
               let noTemp = try? SessionStore.scan(root: root, includeTemp: false) {
                let visibleWith = withTemp.groups.flatMap { $0.sessions }.count
                let visibleNo = noTemp.groups.flatMap { $0.sessions }.count
                check("ephemeral-some-hidden", noTemp.hidden > 0)
                check("ephemeral-count-consistent", visibleWith - visibleNo == noTemp.hidden)
                check("ephemeral-no-analysis-visible",
                      !noTemp.groups.contains { $0.path.contains("claude-analysis") || $0.path.hasPrefix("/private/var/folders/") })
                lines.append("INFO visible=\(visibleNo) hidden=\(noTemp.hidden) (withTemp=\(visibleWith))")
            } else {
                lines.append("FAIL ephemeral-scan (scan threw)")
            }
        } catch {
            lines.append("FAIL exception: \(error.localizedDescription)")
        }

        let passed = lines.filter { $0.hasPrefix("PASS") }.count
        let failed = lines.filter { $0.hasPrefix("FAIL") }.count
        lines.append("SUMMARY \(passed) passed, \(failed) failed")
        return lines.joined(separator: "\n")
    }
}
