import SwiftUI

/// Stable Finder-tag-like color per group name.
enum GroupColor {
    private static let palette: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .indigo, .brown, .cyan]

    static func color(for name: String) -> Color {
        // djb2: stable across launches (unlike String.hashValue).
        let h = name.unicodeScalars.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return palette[Int(h % UInt64(palette.count))]
    }
}
