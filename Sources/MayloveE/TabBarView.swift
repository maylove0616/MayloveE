import AppKit

struct TabBarItem {
    let title: String
    let toolTip: String
    let isDirty: Bool
    let icon: NSImage?
    /// Overrides the default title color, e.g. for Git status.
    let titleColor: NSColor?
}

@MainActor
final class TabBarView: NSView {
    static let height: CGFloat = 32

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

    /// A faint tint over the editor background, so the selected tab reads as part of the editor.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        dirtyRect.fill(using: .sourceOver)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class TabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let isSelected: Bool
    private let isDirty: Bool
    private let closeButton: NSButton
    private var isHovered = false {
        didSet {
            updateCloseButton()
            needsDisplay = true
        }
    }

    private static let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    private static let dirtyImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Modified")?
        .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))

    init(item: TabBarItem, isSelected: Bool) {
        self.isSelected = isSelected
        isDirty = item.isDirty
        closeButton = NSButton(image: Self.closeImage ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)

        toolTip = item.toolTip

        let iconView = NSImageView(image: item.icon ?? NSImage())
        iconView.imageScaling = .scaleNone

        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        label.textColor = item.titleColor ?? (isSelected ? .labelColor : .secondaryLabelColor)

        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        updateCloseButton()

        for subview in [iconView, label, closeButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The close button shows on the selected or hovered tab; otherwise a modified tab shows a dot in its place.
    private func updateCloseButton() {
        if isHovered || (isSelected && !isDirty) {
            closeButton.image = Self.closeImage
            closeButton.isHidden = false
        } else {
            closeButton.image = Self.dirtyImage
            closeButton.isHidden = !isDirty
        }
    }

    // Clicks anywhere except the close button select the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? hit : self
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
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
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bounds.fill(using: .sourceOver)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}
