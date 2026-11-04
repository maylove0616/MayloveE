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

    static let currentLineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.04)
    }
    private static let indentGuideColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.08)
    }

    /// The caret line's rect in view coordinates, or nil while text is selected.
    var currentLineRect: NSRect? {
        guard let layoutManager, selectedRange().length == 0 else { return nil }
        let caret = selectedRange().location
        let fragment: NSRect
        if caret >= (textStorage?.length ?? 0), !layoutManager.extraLineFragmentRect.isEmpty {
            fragment = layoutManager.extraLineFragmentRect
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: caret, length: 0),
                                                  actualCharacterRange: nil)
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            let glyph = min(glyphs.location, layoutManager.numberOfGlyphs - 1)
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return NSRect(x: bounds.minX, y: fragment.minY + textContainerOrigin.y, width: bounds.width,
                      height: fragment.height)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let oldLine = currentLineRect
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        for rect in [oldLine, currentLineRect].compactMap({ $0 }) {
            setNeedsDisplay(rect)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = currentLineRect, line.intersects(rect) {
            Self.currentLineColor.setFill()
            line.intersection(rect).fill(using: .sourceOver)
        }
        drawIndentGuides(in: rect)
    }

    /// Thin vertical lines at each indent level inside a block, like IntelliJ's indent guides.
    /// Blank lines continue the guides of the lines around them.
    private func drawIndentGuides(in rect: NSRect) {
        guard let layoutManager, let textContainer, let font else { return }
        let text = string as NSString
        guard text.length > 0 else { return }
        let unit = Indentation.unit.count
        let columnWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let originX = textContainerOrigin.x + textContainer.lineFragmentPadding

        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        Self.indentGuideColor.setFill()
        var lineStart = text.lineRange(for: NSRange(location: visible.location, length: 0)).location
        while lineStart < text.length, lineStart <= NSMaxRange(visible) {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let indent = Self.indentColumns(of: text, lineRange: lineRange)
                ?? Self.blankLineIndent(in: text, around: lineRange)
            let levels = (indent - 1) / unit
            if levels > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: lineStart)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let top = fragment.minY + textContainerOrigin.y
                for level in 1...levels {
                    let x = floor(originX + CGFloat(level * unit) * columnWidth) + 0.5
                    NSRect(x: x - 0.5, y: top, width: 1, height: fragment.height).fill(using: .sourceOver)
                }
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    /// Leading whitespace in columns (a tab counts as one indent unit); nil for blank lines.
    private static func indentColumns(of text: NSString, lineRange: NSRange) -> Int? {
        var columns = 0
        for index in lineRange.location..<NSMaxRange(lineRange) {
            switch text.character(at: index) {
            case 0x20: columns += 1
            case 0x09: columns += Indentation.unit.count
            case 0x0A, 0x0D: return nil
            default: return columns
            }
        }
        return nil
    }

    /// A blank line takes the smaller indent of the nearest non-blank lines above and below,
    /// so guides run through blank lines inside a block but not between top-level blocks.
    private static func blankLineIndent(in text: NSString, around lineRange: NSRange) -> Int {
        let searchLimit = 200
        func nearest(from start: NSRange, forward: Bool) -> Int {
            var range = start
            for _ in 0..<searchLimit {
                if forward {
                    guard NSMaxRange(range) < text.length else { return 0 }
                    range = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                } else {
                    guard range.location > 0 else { return 0 }
                    range = text.lineRange(for: NSRange(location: range.location - 1, length: 0))
                }
                if let indent = indentColumns(of: text, lineRange: range) { return indent }
            }
            return 0
        }
        return min(nearest(from: lineRange, forward: false), nearest(from: lineRange, forward: true))
    }

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
