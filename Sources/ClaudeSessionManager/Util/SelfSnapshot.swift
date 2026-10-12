import AppKit

/// Renders the app's own key window to a PNG from *inside* the process.
/// This does not use the display/screen-recording APIs, so it works without
/// Screen Recording TCC permission. Gated behind the `CSM_SNAPSHOT` env var
/// (value = destination file path) so it's a no-op in normal use.
enum SelfSnapshot {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CSM_SNAPSHOT"], !path.isEmpty else { return }
        bringToFront()
        // Give the scan + SwiftUI layout time to settle, then capture.
        let delay = ProcessInfo.processInfo.environment["CSM_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: URL(fileURLWithPath: path))
            // Quit after capturing so an automated run terminates cleanly.
            if ProcessInfo.processInfo.environment["CSM_SNAPSHOT_QUIT"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }

    /// Launched from a background process (a script, a test), recent macOS
    /// creates the window but doesn't put it on screen; snapshots need it there.
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    /// Capture the current key window (e.g. an in-app terminal window).
    static func captureKeyWindow(to url: URL) {
        bringToFront()
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        guard let window else { return }
        captureWindow(window.attachedSheet ?? window, to: url)
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        captureWindow(window, to: url)
    }

    private static func captureWindow(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: props) else { return }
        try? data.write(to: url)
    }
}
