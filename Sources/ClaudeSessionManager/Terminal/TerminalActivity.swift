import AppKit
import SwiftTerm

/// Observable activity state for one session's terminal. Kept separate from
/// `TerminalSession` so frequent "working" flips only re-render the affected
/// row's indicator, not the whole session list.
@MainActor
final class TerminalActivity: ObservableObject {
    /// The terminal process is alive.
    @Published var isRunning = true
    /// Output arrived recently — Claude is actively producing output.
    @Published var isWorking = false

    private var idleWork: DispatchWorkItem?
    private let idleInterval: TimeInterval = 0.9

    func noteOutput() {
        guard isRunning else { return }
        if !isWorking { isWorking = true }        // publishes only on transition
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isWorking = false }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleInterval, execute: work)
    }

    func stop() {
        idleWork?.cancel()
        isWorking = false
        isRunning = false
    }
}

/// A `LocalProcessTerminalView` that reports incoming output so the UI can show
/// a per-session activity indicator.
final class ActivityTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let callback = onOutput
        DispatchQueue.main.async { callback?() }
    }
}
