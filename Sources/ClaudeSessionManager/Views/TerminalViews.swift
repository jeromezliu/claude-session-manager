import SwiftUI
import SwiftTerm

/// Hosts a `LocalProcessTerminalView` in SwiftUI, reparenting it into whichever
/// container is currently showing (embedded pane or floating window).
struct TerminalContainer: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView)
    }

    private func attach(to container: NSView) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }
}

/// Terminal shown inside the detail split, with a header to pop out or close.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(session.hasExited ? "Terminal · ended" : "Terminal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { session.popOut() } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Open terminal in a separate window")

                Button { TerminalManager.shared.end(session.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close terminal")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            TerminalContainer(terminal: session.view)
        }
    }
}

/// Terminal shown in its own window, with a button to embed it back.
struct PoppedTerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(session.session.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { session.popIn() } label: {
                    Label("Embed", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("Embed back in the main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            TerminalContainer(terminal: session.view)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
