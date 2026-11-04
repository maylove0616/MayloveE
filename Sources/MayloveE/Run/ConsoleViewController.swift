import AppKit

/// Bottom panel showing a run's output, with clickable compiler errors and stack frames.
@MainActor
final class ConsoleViewController: NSViewController, NSTextViewDelegate {
    /// One point smaller than the editor, like IntelliJ's console.
    private static var font: NSFont { CodeFont.font(offset: -1) }
    /// Older output is dropped beyond this many characters to keep the view responsive.
    private static let maxLength = 2_000_000

    var onOpenLink: ((ConsoleLink) -> Void)?
    var onRerun: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    /// Called when a run starts or finishes, e.g. to enable the toolbar's Stop button.
    var onRunningChange: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView(usingTextLayoutManager: false)
    private var stopButton: NSButton!
    /// Start of the first line not yet scanned for links (it may still be incomplete).
    private var unscannedLineStart = 0

    var text: String { textView.string }

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let rerunButton = Self.button(symbol: "arrow.clockwise", tooltip: "Rerun (⌃R)", action: #selector(rerunClicked))
        rerunButton.target = self
        stopButton = Self.button(symbol: "stop.fill", tooltip: "Stop (⌘F2)", action: #selector(stopClicked))
        stopButton.target = self
        stopButton.isEnabled = false
        let closeButton = Self.button(symbol: "xmark", tooltip: "Hide (⌘4)", action: #selector(closeClicked))
        closeButton.target = self

        let header = NSStackView(views: [titleLabel, NSView(), rerunButton, stopButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = Self.font
        NotificationCenter.default.addObserver(self, selector: #selector(codeFontDidChange),
                                               name: CodeFont.didChange, object: nil)
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        for subview in [separator, header, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: separator.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    @objc private func codeFontDidChange() {
        textView.font = Self.font
        if let storage = textView.textStorage {
            storage.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Clears the console for a new run.
    func begin(title: String) {
        loadViewIfNeeded()
        textView.string = ""
        unscannedLineStart = 0
        setTitle(title)
        setRunning(true)
    }

    func setTitle(_ title: String) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
    }

    func setRunning(_ running: Bool) {
        loadViewIfNeeded()
        stopButton.isEnabled = running
        onRunningChange?(running)
    }

    func append(_ text: String, stream: RunSession.Stream) {
        append(text, color: stream == .stderr ? .systemRed : .labelColor)
    }

    /// Messages from the IDE itself (command line, build status, exit code).
    func appendSystem(_ text: String) {
        append(text, color: .secondaryLabelColor)
    }

    private func append(_ text: String, color: NSColor) {
        guard let storage = textView.textStorage else { return }
        let wasAtBottom = isScrolledToBottom
        storage.append(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color]))
        linkCompletedLines(in: storage)
        trimIfNeeded(storage)
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private var isScrolledToBottom: Bool {
        guard let clipView = textView.enclosingScrollView?.contentView else { return true }
        return clipView.bounds.maxY >= textView.frame.maxY - 20
    }

    private func linkCompletedLines(in storage: NSTextStorage) {
        let string = storage.string as NSString
        var location = unscannedLineStart
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            let end = NSMaxRange(lineRange)
            guard end > location, string.character(at: end - 1) == 0x0A else { break }
            for (range, link) in ConsoleLinkDetector.links(in: string.substring(with: lineRange)) {
                guard let url = link.url else { continue }
                storage.addAttribute(.link, value: url,
                                     range: NSRange(location: lineRange.location + range.location, length: range.length))
            }
            location = end
        }
        unscannedLineStart = location
    }

    private func trimIfNeeded(_ storage: NSTextStorage) {
        guard storage.length > Self.maxLength else { return }
        let string = storage.string as NSString
        let cut = string.lineRange(for: NSRange(location: storage.length - Self.maxLength * 4 / 5, length: 0)).location
        storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        unscannedLineStart = max(0, unscannedLineStart - cut)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let consoleLink = ConsoleLink(url: url) else { return false }
        onOpenLink?(consoleLink)
        return true
    }

    @objc private func rerunClicked() { onRerun?() }
    @objc private func stopClicked() { onStop?() }
    @objc private func closeClicked() { onClose?() }

    private static func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}
