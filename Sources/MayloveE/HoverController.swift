import AppKit

/// Shows documentation or diagnostics in a popover after the mouse rests on a word.
@MainActor
final class HoverController {
    private static let delay: Duration = .milliseconds(500)
    private static let maxSize = NSSize(width: 560, height: 360)
    private static let inset = NSSize(width: 10, height: 8)

    private unowned let textView: CodeTextView
    private let provider: (Int) async -> [HoverPart]
    private var popover: NSPopover?
    /// The word the visible popover belongs to; moving within it keeps the popover open.
    private var shownWord: NSRange?
    private var generation = 0

    init(textView: CodeTextView, provider: @escaping (Int) async -> [HoverPart]) {
        self.textView = textView
        self.provider = provider
    }

    func mouseMoved(to index: Int?) {
        if let index, let shownWord, NSLocationInRange(index, shownWord) { return }
        close()
        guard let index else { return }
        let requestGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self, requestGeneration == self.generation else { return }
            let parts = await self.provider(index)
            guard !parts.isEmpty, requestGeneration == self.generation else { return }
            self.show(parts, at: index)
        }
    }

    /// Shows the provider's content for `index` immediately (Quick Documentation).
    func showNow(at index: Int) {
        close()
        let requestGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let parts = await self.provider(index)
            guard requestGeneration == self.generation else { return }
            if parts.isEmpty {
                NSSound.beep()
            } else {
                self.show(parts, at: index)
            }
        }
    }

    func show(_ message: String, at index: Int) {
        show([.plain(message)], at: index)
    }

    var isShowing: Bool { popover != nil }

    func show(_ parts: [HoverPart], at index: Int) {
        close()
        // NSPopover raises if the anchor view is not in a window, e.g. after a tab switch.
        guard textView.window != nil else { return }
        let controller = NSViewController()
        controller.view = Self.makeContentView(HoverRenderer.render(parts))
        controller.preferredContentSize = controller.view.frame.size

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = controller
        popover.show(relativeTo: textView.rect(forCharacterAt: index), of: textView, preferredEdge: .maxY)
        self.popover = popover
        shownWord = Self.wordRange(in: textView.string as NSString, around: index)
    }

    func close() {
        generation += 1
        shownWord = nil
        popover?.close()
        popover = nil
    }

    /// A selectable text view sized to its content, scrolling once it exceeds `maxSize`.
    private static func makeContentView(_ text: NSAttributedString) -> NSView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = inset
        textView.textStorage?.setAttributedString(text)

        let textWidth = maxSize.width - 2 * inset.width
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return textView
        }
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)

        let contentWidth = ceil(min(used.width + 2 * container.lineFragmentPadding, textWidth)) + 2 * inset.width
        let contentHeight = ceil(used.height) + 2 * inset.height
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        container.containerSize = NSSize(width: contentWidth - 2 * inset.width, height: .greatestFiniteMagnitude)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth,
                                                    height: min(contentHeight, maxSize.height)))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = contentHeight > maxSize.height
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    private static func wordRange(in text: NSString, around index: Int) -> NSRange {
        let start = CompletionController.wordStart(in: text, before: index)
        var end = index
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
              CompletionController.isIdentifier(scalar) {
            end += 1
        }
        return NSRange(location: start, length: max(end - start, 1))
    }
}
