import SwiftUI

/// Refresh button whose icon spins one full turn on each click — clear feedback
/// that the action fired even when the list is unchanged.
struct RefreshButton: View {
    let action: () -> Void
    @State private var angle = 0.0

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.6)) { angle += 360 }
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Refresh")
    }
}
