import AppKit

/// Turns jdtls hover content (signature + Javadoc as Markdown) into styled text.
enum HoverRenderer {
    private static let fontSize: CGFloat = 13

    static func render(_ parts: [HoverPart]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            switch part {
            case .code(let code):
                result.append(NSAttributedString(string: code.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .markdown(let markdown):
                result.append(renderMarkdown(normalizeMarkdown(markdown)))
            case .plain(let text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
        }
        return result
    }

    /// Reflows Javadoc-style Markdown: unwraps hard-wrapped paragraphs, turns `* ` list markers
    /// into bullets, drops links (they point at jdt:// URIs) and the "Source:" footer.
    static func normalizeMarkdown(_ markdown: String) -> String {
        let withoutLinks = markdown.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                                         options: .regularExpression)
        let lines = withoutLinks.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Source:") }
            .map { $0.replacingOccurrences(of: #"^(\s*)[*-] "#, with: "$1• ", options: .regularExpression) }

        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
            current = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("•") || current.isEmpty {
                current.append(trimmed.hasPrefix("•") ? line.replacingOccurrences(of: "  ", with: "    ") : trimmed)
            } else {
                current[current.count - 1] += " " + trimmed
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func renderMarkdown(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: fontSize)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: base, .foregroundColor: NSColor.labelColor])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var font = base
            var color = NSColor.labelColor
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular)
                    color = .systemPink
                }
                if intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters),
                                             attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}
