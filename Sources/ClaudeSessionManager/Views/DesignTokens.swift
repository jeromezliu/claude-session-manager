import SwiftUI

/// One small, shared set of visual constants so every surface uses the same
/// spacing rhythm and corner-radius scale. Keeping these in one place is what
/// makes the app read as one coherent piece rather than a pile of screens.
enum DS {
    // Corner radii — exactly three steps, used everywhere.
    /// Inline code, small chips.
    static let rInline: CGFloat = 6
    /// Controls, inputs, cards, transcript events.
    static let rControl: CGFloat = 10
    /// Chat bubbles (the one place that reads as "soft").
    static let rBubble: CGFloat = 14

    // Spacing rhythm.
    static let gutter: CGFloat = 14      // outer padding of panes
    static let turnGap: CGFloat = 16     // between speakers in the chat
    static let groupGap: CGFloat = 6     // between same-speaker turns

    /// Max width of a right-aligned user bubble, so long prompts don't stretch
    /// edge-to-edge on a wide window.
    static let userBubbleMaxWidth: CGFloat = 560
}
