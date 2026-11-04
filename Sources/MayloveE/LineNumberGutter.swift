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

    /// Uncommitted changes against Git HEAD, drawn as bars at the gutter's right edge.
    var changes: [LineHunk] = [] {
        didSet {
            changedLines = [:]
            deletionsBefore = []
            for hunk in changes {
                if hunk.new.isEmpty {
                    deletionsBefore.insert(hunk.new.lowerBound)
                } else {
                    for line in hunk.new { changedLines[line] = hunk.kind }
                }
            }
            needsDisplay = true
        }
    }

    /// Custom per-line labels, e.g. original line numbers in a diff with blank filler lines.
    var lineLabels: [String]? {
        didSet { needsDisplay = true }
    }

    private var font = CodeFont.gutterFont()
    private var changedLines: [Int: LineHunk.Kind] = [:]
    /// Lines that have deleted lines just above them.
    private var deletionsBefore: Set<Int> = []

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
        NotificationCenter.default.addObserver(self, selector: #selector(codeFontDidChange),
                                               name: CodeFont.didChange, object: nil)
    }

    @objc private func codeFontDidChange() {
        font = CodeFont.gutterFont()
        updateThickness()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func updateThickness() {
        let digits = max(3, String(lineIndex.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 24)
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Since macOS 26 rulers float over the clip view and `rect` is not limited to the
        // ruler, so painting `rect` would cover the text. Only paint our own bounds.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        // A faint tint sets the gutter apart from the text, as in IntelliJ IDEA.
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var currentLineAttributes = attributes
        currentLineAttributes[.foregroundColor] = NSColor.labelColor
        let selection = textView.selectedRange()
        let currentLine = selection.length == 0 ? lineIndex.line(containing: selection.location) : nil
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
            let label = (lineLabels.map { line < $0.count ? $0[line] : "" } ?? String(line + 1)) as NSString
            let isCurrent = line == currentLine
            if isCurrent {
                CodeTextView.currentLineColor.setFill()
                NSRect(x: 0, y: origin.y, width: bounds.width - 1, height: fragment.height).fill(using: .sourceOver)
            }
            let lineAttributes = isCurrent ? currentLineAttributes : attributes
            let size = label.size(withAttributes: lineAttributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12,
                                   y: origin.y + (fragment.height - size.height) / 2),
                       withAttributes: lineAttributes)
            drawChangeMarker(forLine: line, top: origin.y, height: fragment.height)
            line += 1
        }
    }

    private func drawChangeMarker(forLine line: Int, top: CGFloat, height: CGFloat) {
        let x = bounds.maxX - 7
        if let kind = changedLines[line] {
            kind.color.setFill()
            NSRect(x: x, y: top, width: 3, height: height).fill()
        }
        if deletionsBefore.contains(line) {
            // A small triangle pointing into the text, on the boundary where lines were removed.
            LineHunk.Kind.deleted.color.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: top - 4))
            path.line(to: NSPoint(x: x + 5, y: top))
            path.line(to: NSPoint(x: x, y: top + 4))
            path.close()
            path.fill()
        }
    }
}
