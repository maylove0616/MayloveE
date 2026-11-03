import AppKit

enum Indentation {
    static let unit = "    "

    /// Text to insert for Return, given the current line's text before the cursor.
    static func newline(after linePrefix: String) -> String {
        let leading = linePrefix.prefix { $0 == " " || $0 == "\t" }
        let opensBlock = linePrefix.trimmingCharacters(in: .whitespaces).hasSuffix("{")
        return "\n" + leading + (opensBlock ? unit : "")
    }
}

final class CodeTextView: NSTextView {
    /// Gets the first look at key presses (e.g. to drive a popup); return true to consume.
    var keyDownInterceptor: ((NSEvent) -> Bool)?
    /// Text the user typed, after it was inserted.
    var onTyped: ((String) -> Void)?
    var onCompletionRequested: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    /// Character under the mouse, or nil when the pointer is not over text.
    var onHover: ((Int?) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func keyDown(with event: NSEvent) {
        if keyDownInterceptor?(event) == true { return }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        onTyped?(text)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else { return }
        let text = string as NSString
        let cursor = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: cursor, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        insertText(Indentation.newline(after: prefix), replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        insertText(Indentation.unit, replacementRange: selectedRange())
    }

    /// ⌥Esc / F5 map here by default.
    override func complete(_ sender: Any?) {
        onCompletionRequested?()
    }

    /// Plain Esc would otherwise invoke `complete(_:)`.
    override func cancelOperation(_ sender: Any?) {}

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandClick,
           let index = characterIndex(atWindowPoint: event.locationInWindow) {
            onCommandClick(index)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(characterIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    /// The character whose glyph lies under the point, not merely the nearest insertion point.
    func characterIndex(atWindowPoint windowPoint: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Rect of a character in this view's coordinates, for anchoring popovers.
    func rect(forCharacterAt index: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Applies several replacements as one undoable change, keeping the caret in place
    /// relative to the text before it.
    func apply(_ edits: [(range: NSRange, text: String)]) {
        guard isEditable, !edits.isEmpty else { return }
        var caret = selectedRange().location
        undoManager?.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard shouldChangeText(in: edit.range, replacementString: edit.text) else { continue }
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            didChangeText()
            if NSMaxRange(edit.range) <= caret {
                caret += (edit.text as NSString).length - edit.range.length
            }
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: caret, length: 0))
    }
}
