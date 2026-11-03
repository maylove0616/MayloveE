import AppKit

struct TabBarItem {
    let title: String
    let toolTip: String
    let isDirty: Bool
}

@MainActor
final class TabBarView: NSView {
    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stackView.orientation = .horizontal
        stackView.spacing = 0

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stackView

        for subview in [scrollView, stackView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func update(items: [TabBarItem], selectedIndex: Int?) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let tab = TabView(item: item, isSelected: index == selectedIndex)
            tab.onSelect = { [weak self] in self?.onSelect?(index) }
            tab.onClose = { [weak self] in self?.onClose?(index) }
            stackView.addArrangedSubview(tab)
        }
        if let selectedIndex {
            stackView.layoutSubtreeIfNeeded()
            let selected = stackView.arrangedSubviews[selectedIndex]
            selected.scrollToVisible(selected.bounds)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class TabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let isSelected: Bool
    private let closeButton: NSButton

    init(item: TabBarItem, isSelected: Bool) {
        self.isSelected = isSelected
        let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton = NSButton(image: closeImage ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)

        toolTip = item.toolTip

        let label = NSTextField(labelWithString: (item.isDirty ? "● " : "") + item.title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor

        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        for subview in [label, closeButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Clicks anywhere except the close button select the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}
