import SwiftUI

// MARK: - Markdown rendering

/// Renders `Markdown.parse` blocks with native text styles.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) { blocks = Markdown.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // Never smaller than body text: h1 > h2 > h3+ (bold body).
            Text(Markdown.inline(text))
                .font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(Markdown.inline(text)).lineSpacing(2)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(Markdown.inline(text)).lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .code(_, let text):
            CodeBlock(text: text)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                Text(Markdown.inline(text)).foregroundStyle(.secondary).lineSpacing(2)
            }
        case .table(let header, let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Markdown.inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.inline(cell))
                        }
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
