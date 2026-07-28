import Foundation
import Combine

/// The permission modes offered in the conversation picker.
///
/// Read from the installed CLI itself (`claude --help` documents the accepted
/// `--permission-mode` values) rather than hardcoded, so a new mode appears
/// after a `brew upgrade` without an app change. `default` is always included:
/// it's what sessions record in their `permission-mode` lines and the CLI
/// accepts it, even though it isn't in the printed choices list.
enum PermissionModeCatalog {
    /// Shipped list, used until (or unless) the CLI is successfully queried.
    static let fallback = ["plan", "default", "acceptEdits", "bypassPermissions"]

    /// Least → most autonomy. Modes the CLI reports that aren't listed here get
    /// appended at the end, so an unknown new mode is still selectable.
    private static let preferredOrder = [
        "plan", "manual", "default", "acceptEdits", "auto", "dontAsk", "bypassPermissions",
    ]

    private static let labels: [String: String] = [
        "plan": "Plan · read-only",
        "manual": "Manual · ask",
        "default": "Use my allow rules",
        "acceptEdits": "Auto-accept edits",
        "auto": "Auto",
        "dontAsk": "Don't ask",
        "bypassPermissions": "Full auto",
    ]

    static func label(for mode: String) -> String {
        if let l = labels[mode] { return l }
        // Prettify an unknown mode: "someNewMode" → "Some New Mode".
        var out = ""
        for ch in mode {
            if ch.isUppercase && !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func ordered(_ modes: [String]) -> [String] {
        var modes = modes
        if !modes.contains("default") { modes.insert("default", at: 0) }
        let known = preferredOrder.filter { modes.contains($0) }
        let extra = modes.filter { !preferredOrder.contains($0) }.sorted()
        return known + extra
    }

    /// BLOCKING: runs `claude --help` and parses the choices. Never call this
    /// from a SwiftUI body — `waitUntilExit()` pumps the run loop, which lets
    /// SwiftUI re-enter and deadlock. `CLICapabilities` calls it off-main.
    static func query() -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ClaudeCLI.binaryPath)
        p.arguments = ["--help"]
        p.environment = ClaudeCLI.turnEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let help = String(data: data, encoding: .utf8) else { return nil }

        // Help text wraps, so collapse whitespace before matching.
        let flat = help.replacingOccurrences(of: "\\s+", with: " ",
                                             options: .regularExpression)
        guard let optRange = flat.range(of: "--permission-mode") else { return nil }
        let tail = flat[optRange.upperBound...]
        guard let choicesStart = tail.range(of: "(choices:"),
              let choicesEnd = tail[choicesStart.upperBound...].range(of: ")") else { return nil }
        let list = tail[choicesStart.upperBound..<choicesEnd.lowerBound]

        let modes = list.split(separator: ",").compactMap { chunk -> String? in
            let t = chunk.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return t.isEmpty ? nil : t
        }
        return modes.isEmpty ? nil : modes
    }
}

/// What the installed `claude` supports, resolved once in the background so no
/// view ever blocks on spawning a process.
@MainActor
final class CLICapabilities: ObservableObject {
    static let shared = CLICapabilities()

    @Published private(set) var permissionModes: [String] =
        PermissionModeCatalog.ordered(PermissionModeCatalog.fallback)

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) {
            guard let modes = PermissionModeCatalog.query() else { return }
            let ordered = PermissionModeCatalog.ordered(modes)
            await MainActor.run { self.permissionModes = ordered }
        }
    }
}
