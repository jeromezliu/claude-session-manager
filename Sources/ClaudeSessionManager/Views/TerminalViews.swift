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

    /// Move the shared terminal view into this container, pinned to its edges
    /// with Auto Layout so it always fills regardless of when layout happens
    /// (fixes a 0×0 frame after being reparented from a window).
    private func attach(to container: NSView) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminal.needsDisplay = true
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
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
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
