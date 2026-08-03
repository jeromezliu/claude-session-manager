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

    enum ColAlign { case leading, center, trailing }

    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(index: String, text: String)
        case quote(String)
        case code(language: String, body: String)
        case table(header: [String], rows: [[String]], aligns: [ColAlign])
        case rule

        @ViewBuilder var view: some View {
            switch self {
            case .paragraph(let s):
                MarkdownInline(s)
            case .table(let header, let rows, let aligns):
                MarkdownTable(header: header, rows: rows, aligns: aligns)
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

            // GitHub table: a row containing "|" immediately followed by a
            // delimiter row like `|---|:--:|`. Checked before the rule/heading
            // cases so the delimiter isn't mistaken for a horizontal rule.
            if trimmed.contains("|"), i + 1 < lines.count, isDelimiterRow(lines[i + 1]) {
                flushParagraph()
                let header = splitRow(line)
                let aligns = splitRow(lines[i + 1]).map(alignment(for:))
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty || !l.contains("|") { break }
                    rows.append(splitRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, aligns: aligns))
                continue
            }

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

    // MARK: - Table helpers

    /// A GitHub table delimiter row: every `|`-separated cell is `:?-+:?`
    /// (dashes with optional alignment colons), and there's at least one dash.
    static func isDelimiterRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        let cells = splitRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy {
            $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
        }
    }

    /// Split a table row into trimmed cells, dropping the optional outer pipes.
    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(for delimiterCell: String) -> ColAlign {
        let c = delimiterCell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":"), right = c.hasSuffix(":")
        if left && right { return .center }
        if right { return .trailing }
        return .leading
    }
}

/// A Markdown table rendered with a native `Grid`: bold header, one hairline
/// under it, cells aligned per the delimiter row. Scrolls horizontally so a
/// wide table never forces the whole pane to grow.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownText.ColAlign]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(header, c)
                            .font(.callout.weight(.semibold))
                            .gridColumnAlignment(hAlign(c))
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { c in
                            cell(rows[r], c).font(.callout)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.rInline))
    }

    private func hAlign(_ col: Int) -> HorizontalAlignment {
        switch col < aligns.count ? aligns[col] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// One cell with inline Markdown (bold/italic/code/links) applied.
    private func cell(_ row: [String], _ col: Int) -> some View {
        let raw = col < row.count ? row[col] : ""
        let attr = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
        return Text(attr).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
