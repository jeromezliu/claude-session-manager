import SwiftUI

/// Lightweight block-level Markdown renderer for chat/transcript text.
///
/// SwiftUI's `Text(AttributedString(markdown:))` only handles *inline* syntax
/// (bold/italic/code spans/links) — it collapses block structure. This renders
/// real blocks: fenced code, headings, bullet/numbered lists, blockquotes, and
/// horizontal rules, with inline markdown applied within each paragraph/line.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block model

    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(index: String, text: String)
        case quote(String)
        case code(language: String, body: String)
        case rule

        @ViewBuilder var view: some View {
            switch self {
            case .paragraph(let s):
                MarkdownInline(s)
            case .heading(let level, let s):
                MarkdownInline(s)
                    .font(.system(size: [22, 19, 17, 15, 14, 13][min(max(level - 1, 0), 5)],
                                  weight: .semibold))
                    .padding(.top, 2)
            case .bullet(let s):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    MarkdownInline(s)
                }
            case .numbered(let idx, let s):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(idx + ".").foregroundStyle(.secondary).monospacedDigit()
                    MarkdownInline(s)
                }
            case .quote(let s):
                HStack(spacing: 8) {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                    MarkdownInline(s).foregroundStyle(.secondary)
                }
            case .code(let lang, let body):
                CodeBlock(language: lang, code: body)
            case .rule:
                Divider().padding(.vertical, 2)
            }
        }
    }

    // MARK: - Parser

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang, body: body.joined(separator: "\n")))
                i += 1   // skip closing fence
                continue
            }

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); blocks.append(.rule); i += 1; continue
            }

            if let hashes = trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level,
                                       text: String(trimmed[hashes.upperBound...])))
                i += 1; continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                i += 1; continue
            }

            if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                flushParagraph()
                let num = trimmed[trimmed.startIndex..<m.upperBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                blocks.append(.numbered(index: num, text: String(trimmed[m.upperBound...])))
                i += 1; continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                i += 1; continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }
}

/// A single paragraph/line rendered with inline markdown (bold/italic/code/link).
private struct MarkdownInline: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
    }
}

/// Monospaced code block with a subtle background; scrolls horizontally.
private struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.rInline))
    }
}
