import SwiftUI

/// One turn in the conversation, rendered as a native chat message rather than
/// a boxed transcript event: the user's prompt sits right-aligned in a single
/// accent bubble, Claude's reply sits left-aligned as clean typographic text
/// with no container, so Markdown (headings, code, lists) carries the styling.
///
/// `showSpeaker` is false when this turn has the same author as the one above,
/// so a back-and-forth doesn't repeat the "Claude" label on every line.
struct ChatTurnView: View {
    let event: TranscriptEvent
    var showSpeaker: Bool = true

    private var isUser: Bool { event.kind == .user }

    private var texts: [String] {
        event.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 40)
                bubbleBody
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: DS.rBubble))
                    .frame(maxWidth: DS.userBubbleMaxWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if showSpeaker { speaker }
                bubbleBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speaker: some View {
        HStack(spacing: 6) {
            Text("Claude")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let model = event.model {
                Text(Fmt.model(model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(texts.enumerated()), id: \.offset) { _, t in
                MarkdownText(text: t)
            }
        }
    }
}
