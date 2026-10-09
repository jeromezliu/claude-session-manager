import Foundation

/// Block-level Markdown, enough for Claude's replies: headings, paragraphs,
/// lists, fenced code, quotes, tables and rules. Inline syntax (bold, code,
/// links) is left to `AttributedString(markdown:)` when rendering.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for bullets or "1." etc. for ordered items.
    case listItem(marker: String, indent: Int, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum Markdown {

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Heading.
            if let level = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }

            // Horizontal rule.
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let c = trimmed.first, "-*_".contains(c) {
                flushParagraph(); blocks.append(.rule); i += 1; continue
            }

            // Table: a pipe row followed by a separator row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Block quote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // List item.
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                i += 1; continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count / 2
        let s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            return .listItem(marker: "•", indent: indent, text: String(s.dropFirst(2)))
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", indent: indent, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("|"), s.contains("-") else { return false }
        return s.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var s = Substring(row)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown (bold, italics, `code`, links) as an AttributedString,
    /// falling back to plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
