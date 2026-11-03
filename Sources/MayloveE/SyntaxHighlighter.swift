import AppKit
import SwiftTreeSitter

/// Colors the visible part of a text view using layout-manager temporary attributes,
/// so highlighting never touches the text storage or the undo stack.
@MainActor
final class SyntaxHighlighter: NSObject {
    private let syntax: JavaSyntax
    private weak var textView: NSTextView?
    private var tree: MutableTree?
    private var text = ""
    private var isReparseScheduled = false

    init?(textView: NSTextView) {
        guard let syntax = JavaSyntax.shared else { return nil }
        self.syntax = syntax
        self.textView = textView
        super.init()

        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(visibleRegionDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: clipView)
        }
    }

    /// Coalesces all edits made within one run-loop turn into a single reparse.
    func textDidChange() {
        guard !isReparseScheduled else { return }
        isReparseScheduled = true
        Task { @MainActor [weak self] in
            self?.reparse()
        }
    }

    func refresh() {
        if tree == nil {
            reparse()
        } else {
            highlightVisibleRange()
        }
    }

    private func reparse() {
        isReparseScheduled = false
        guard let textView else { return }
        text = textView.string
        tree = syntax.parse(text)
        highlightVisibleRange()
    }

    @objc private func visibleRegionDidChange(_ notification: Notification) {
        highlightVisibleRange()
    }

    private func highlightVisibleRange() {
        // While a reparse is pending, the tree's ranges refer to stale text.
        guard !isReparseScheduled,
              let tree,
              let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard visible.length > 0 else { return }

        let documentRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visible)
        for highlight in syntax.highlights(in: tree, text: text, range: visible) {
            guard let color = SyntaxTheme.color(for: highlight.nameComponents) else { continue }
            let range = NSIntersectionRange(highlight.range, documentRange)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }
    }
}

@MainActor
enum SyntaxTheme {
    private static let colors: [String: NSColor] = [
        "keyword": .systemPink,
        "variable.builtin": .systemPink,
        "type": .systemTeal,
        "string": .systemRed,
        "string.escape": .systemOrange,
        "number": .systemPurple,
        "constant": .systemPurple,
        "comment": .systemGray,
        "attribute": .systemBrown,
        "function": .systemBlue,
    ]

    /// Falls back from the most specific name, e.g. "function.method" → "function".
    static func color(for nameComponents: [String]) -> NSColor? {
        var components = nameComponents[...]
        while !components.isEmpty {
            if let color = colors[components.joined(separator: ".")] {
                return color
            }
            components = components.dropLast()
        }
        return nil
    }
}
