import AppKit

/// Vertical ruler that draws line numbers for a TextKit 1 text view.
@MainActor
final class LineNumberGutter: NSRulerView {
    var lineIndex = LineIndex("") {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func updateThickness() {
        let digits = max(3, String(lineIndex.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 20)
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Since macOS 26 rulers float over the clip view and `rect` is not limited to the
        // ruler, so painting `rect` would cover the text. Only paint our own bounds.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textLength = textView.textStorage?.length ?? 0
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let visibleChars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var line = lineIndex.line(containing: visibleChars.location)
        while line < lineIndex.lineCount {
            let start = lineIndex.lineStarts[line]
            if start > NSMaxRange(visibleChars) { break }

            let fragment: NSRect
            if start >= textLength {
                // The empty line after a trailing newline (or an empty document).
                fragment = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }

            let origin = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView)
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                   y: origin.y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }
}
