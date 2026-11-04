import AppKit

/// Side-by-side diff of two versions of a file, as IntelliJ IDEA's diff viewer.
@MainActor
final class DiffWindowController: NSWindowController, NSWindowDelegate {
    struct Version {
        let label: String
        let text: String
    }

    var onClose: (() -> Void)?

    private let diff: AlignedDiff
    private let leftPane: DiffPane
    private let rightPane: DiffPane
    private var isSyncingScroll = false
    private var currentBlock: Int?

    init(title: String, fileName: String, left: Version, right: Version) {
        diff = AlignedDiff(old: left.text, new: right.text)
        let isJava = fileName.hasSuffix(".java")
        leftPane = DiffPane(label: left.label, side: diff.left, blocks: diff.blocks, isJava: isJava)
        rightPane = DiffPane(label: right.label, side: diff.right, blocks: diff.blocks, isJava: isJava)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DiffWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        syncScrolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var differenceCount: Int { diff.blocks.count }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        leftPane.didAppear()
        rightPane.didAppear()
        if !diff.blocks.isEmpty {
            show(block: 0)
        }
    }

    private func makeContent() -> NSView {
        let previous = Self.button(symbol: "arrow.up", tooltip: "Previous Difference (⇧F7)",
                                   action: #selector(previousDifference(_:)))
        let next = Self.button(symbol: "arrow.down", tooltip: "Next Difference (F7)",
                               action: #selector(nextDifference(_:)))
        for button in [previous, next] { button.target = self }
        previous.keyEquivalent = Self.f7
        previous.keyEquivalentModifierMask = [.shift]
        next.keyEquivalent = Self.f7
        next.keyEquivalentModifierMask = []

        let summary = NSTextField(labelWithString: diff.blocks.isEmpty
                                  ? "Contents are identical"
                                  : "\(diff.blocks.count) difference\(diff.blocks.count == 1 ? "" : "s")")
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 12)

        let header = NSStackView(views: [previous, next, summary])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftPane)
        split.addArrangedSubview(rightPane)

        let container = NSView()
        for subview in [header, split] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async {
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        }
        return container
    }

    /// Both sides have the same rows, so scrolling one vertically scrolls the other to the same offset.
    private func syncScrolling() {
        for (source, target) in [(leftPane, rightPane), (rightPane, leftPane)] {
            let clipView = source.scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                   object: clipView, queue: .main) { [weak self, weak target] _ in
                MainActor.assumeIsolated {
                    guard let self, let target, !self.isSyncingScroll else { return }
                    self.isSyncingScroll = true
                    let targetClip = target.scrollView.contentView
                    targetClip.scroll(to: NSPoint(x: targetClip.bounds.origin.x, y: clipView.bounds.origin.y))
                    target.scrollView.reflectScrolledClipView(targetClip)
                    self.isSyncingScroll = false
                }
            }
        }
    }

    @objc func nextDifference(_ sender: Any?) {
        guard !diff.blocks.isEmpty else { return NSSound.beep() }
        show(block: currentBlock.map { min($0 + 1, diff.blocks.count - 1) } ?? 0)
    }

    @objc func previousDifference(_ sender: Any?) {
        guard !diff.blocks.isEmpty else { return NSSound.beep() }
        show(block: currentBlock.map { max($0 - 1, 0) } ?? 0)
    }

    private func show(block index: Int) {
        currentBlock = index
        rightPane.scroll(toRow: diff.blocks[index].rows.lowerBound)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private static let f7 = UnicodeScalar(NSF7FunctionKey).map { String(Character($0)) } ?? ""

    private static func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

/// One side of the diff: a caption above a read-only text view with line numbers.
@MainActor
private final class DiffPane: NSView {
    private static var font: NSFont { CodeFont.font(offset: -1) }

    let scrollView = NSScrollView()
    private let textView = DiffTextView(usingTextLayoutManager: false)
    private var highlighter: SyntaxHighlighter?

    init(label: String, side: AlignedDiff.Side, blocks: [AlignedDiff.Block], isJava: Bool) {
        super.init(frame: .zero)

        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = Self.font
        NotificationCenter.default.addObserver(self, selector: #selector(codeFontDidChange),
                                               name: CodeFont.didChange, object: nil)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = side.text
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = unlimited
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = unlimited
        textView.lineIndex = LineIndex(side.text)
        for block in blocks {
            // Filler rows only get a faint tint, so the real lines of a block stand out.
            for row in block.rows {
                let isFiller = side.numbers[row] == nil
                textView.rowBackgrounds[row] = block.kind.color.withAlphaComponent(isFiller ? 0.06 : 0.18)
            }
        }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let gutter = LineNumberGutter(textView: textView)
        gutter.lineIndex = LineIndex(side.text)
        gutter.lineLabels = side.labels
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        if isJava {
            highlighter = SyntaxHighlighter(textView: textView)
        }

        for subview in [caption, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func didAppear() {
        highlighter?.refresh()
    }

    @objc private func codeFontDidChange() {
        textView.font = Self.font
        highlighter?.refresh()
        textView.needsDisplay = true
    }

    /// Puts `row` about a third of the way down the view.
    func scroll(toRow row: Int) {
        guard let rect = textView.rect(forRow: row) else { return }
        // scrollToVisible respects the floating ruler's inset, unlike setting the clip view's origin.
        let height = scrollView.contentView.bounds.height
        textView.scrollToVisible(NSRect(x: 0, y: max(0, rect.minY - height / 3), width: 1, height: height))
    }
}

/// A text view that paints full-width backgrounds behind given rows.
@MainActor
private final class DiffTextView: NSTextView {
    var rowBackgrounds: [Int: NSColor] = [:]
    var lineIndex = LineIndex("")

    func rect(forRow row: Int) -> NSRect? {
        guard let layoutManager, row < lineIndex.lineCount else { return nil }
        let start = lineIndex.lineStarts[row]
        let fragment: NSRect
        if start >= (textStorage?.length ?? 0) {
            fragment = layoutManager.extraLineFragmentRect
        } else {
            fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                      effectiveRange: nil)
        }
        return fragment.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var row = lineIndex.line(containing: characters.location)
        let end = lineIndex.line(containing: NSMaxRange(characters))
        while row <= end {
            if let color = rowBackgrounds[row], let rowRect = self.rect(forRow: row) {
                color.setFill()
                NSRect(x: rect.minX, y: rowRect.minY, width: rect.width, height: rowRect.height)
                    .fill(using: .sourceOver)
            }
            row += 1
        }
    }
}
