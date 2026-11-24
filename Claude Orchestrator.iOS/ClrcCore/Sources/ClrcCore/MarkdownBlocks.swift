import Foundation

/// One block of assistant text. Inline syntax (bold, `code`, links) stays in
/// the strings and is rendered by `inlineMarkdown`.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(Int, String)
    case code(language: String, text: String)
}

/// A small block-level markdown splitter for chat replies: paragraphs,
/// headings, list items and fenced code. Anything it does not recognise is
/// a paragraph, so no text is ever dropped.
public enum MarkdownBlocks {
    static let maxHeadingLevel = 6
    static let maxListIndent = 3

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (marker: String, language: String, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            if let open = fence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                fence = (marker, language, [])
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func fenceMarker(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...maxHeadingLevel).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= maxListIndent else { return nil }
        let body = line.dropFirst(indent)

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .bullet(body.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }

        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return .numbered(number, afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
