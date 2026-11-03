import AppKit

/// SF Symbol icons for files and folders, colored by kind, shared by the file tree and the tab bar.
@MainActor
enum FileIcon {
    private struct Style {
        let symbol: String
        let color: NSColor
    }

    private static let byExtension: [String: Style] = [
        "java": Style(symbol: "cup.and.saucer.fill", color: .systemOrange),
        "class": Style(symbol: "cup.and.saucer.fill", color: .systemGray),
        "xml": Style(symbol: "chevron.left.forwardslash.chevron.right", color: .systemPurple),
        "html": Style(symbol: "chevron.left.forwardslash.chevron.right", color: .systemPurple),
        "json": Style(symbol: "curlybraces", color: .systemYellow),
        "properties": Style(symbol: "gearshape.fill", color: .systemGray),
        "yml": Style(symbol: "gearshape.fill", color: .systemGray),
        "yaml": Style(symbol: "gearshape.fill", color: .systemGray),
        "md": Style(symbol: "doc.richtext", color: .systemBlue),
        "txt": Style(symbol: "doc.text", color: .secondaryLabelColor),
        "sh": Style(symbol: "terminal.fill", color: .secondaryLabelColor),
        "jar": Style(symbol: "shippingbox.fill", color: .systemBrown),
        "png": Style(symbol: "photo", color: .systemTeal),
        "jpg": Style(symbol: "photo", color: .systemTeal),
        "gif": Style(symbol: "photo", color: .systemTeal),
        "svg": Style(symbol: "photo", color: .systemTeal),
    ]

    private static let file = Style(symbol: "doc", color: .secondaryLabelColor)

    static func image(for url: URL, isDirectory: Bool = false, isDimmed: Bool = false) -> NSImage? {
        let style = isDirectory ? folderStyle(for: url) : (byExtension[url.pathExtension.lowercased()] ?? file)
        let color = isDimmed ? NSColor.tertiaryLabelColor : style.color
        return NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    }

    /// Test sources are green and resources orange, as in IntelliJ IDEA; other folders blue.
    private static func folderStyle(for url: URL) -> Style {
        let path = url.path
        if path.contains("/src/test/") || path.hasSuffix("/src/test") {
            return Style(symbol: "folder.fill", color: .systemGreen)
        }
        if url.lastPathComponent == "resources" {
            return Style(symbol: "folder.fill", color: .systemOrange)
        }
        return Style(symbol: "folder.fill", color: .systemBlue)
    }
}
