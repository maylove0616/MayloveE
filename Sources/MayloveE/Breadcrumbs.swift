import AppKit
import SwiftTreeSitter

/// One enclosing declaration at the caret, e.g. a class or method.
struct Breadcrumb: Equatable {
    enum Kind {
        case `class`, interface, `enum`, record, annotation, method, constructor
    }

    let title: String
    let kind: Kind
    /// The declaration's name, for jumping to it.
    let nameRange: NSRange
}

/// Finds the declarations enclosing a caret position using the tree-sitter syntax tree.
@MainActor
enum BreadcrumbResolver {
    private static let kinds: [String: Breadcrumb.Kind] = [
        "class_declaration": .class,
        "interface_declaration": .interface,
        "enum_declaration": .enum,
        "record_declaration": .record,
        "annotation_type_declaration": .annotation,
        "method_declaration": .method,
        "constructor_declaration": .constructor,
    ]

    /// Outermost first.
    static func resolve(text: String, caret: Int) -> [Breadcrumb] {
        guard let syntax = JavaSyntax.shared, let tree = syntax.parse(text), let root = tree.rootNode else {
            return []
        }
        let source = text as NSString
        let caretBytes = UInt32(caret * 2)
        var crumbs: [Breadcrumb] = []
        var current = root.descendant(in: caretBytes..<caretBytes)
        while let node = current {
            if let type = node.nodeType, let kind = kinds[type], let name = node.child(byFieldName: "name") {
                let title = source.substring(with: name.range)
                let isCallable = kind == .method || kind == .constructor
                crumbs.append(Breadcrumb(title: isCallable ? "\(title)()" : title, kind: kind, nameRange: name.range))
            }
            current = node.parent
        }
        return crumbs.reversed()
    }
}

/// The caret's enclosing declarations above the editor, like IntelliJ's breadcrumbs; click one to jump to it.
@MainActor
final class BreadcrumbBar: NSView {
    static let height: CGFloat = 28

    var onSelect: ((Breadcrumb) -> Void)?

    private let stackView = NSStackView()
    private var crumbs: [Breadcrumb] = []
    private var file: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `file` leads the trail, so the bar is never empty for an open file.
    func update(file: URL?, crumbs: [Breadcrumb]) {
        guard crumbs != self.crumbs || file != self.file || stackView.arrangedSubviews.isEmpty else { return }
        self.crumbs = crumbs
        self.file = file
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let file {
            stackView.addArrangedSubview(Self.item(title: file.lastPathComponent, image: FileIcon.image(for: file)))
        }
        for (index, crumb) in crumbs.enumerated() {
            stackView.addArrangedSubview(Self.separator())
            let button = Self.item(title: crumb.title, image: Self.image(for: crumb.kind))
            button.tag = index
            button.target = self
            button.action = #selector(crumbClicked(_:))
            stackView.addArrangedSubview(button)
        }
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbs.indices.contains(sender.tag) else { return }
        onSelect?(crumbs[sender.tag])
    }

    private static func item(title: String, image: NSImage?) -> NSButton {
        let button = NSButton(title: title, image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = image == nil ? .noImage : .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private static func separator() -> NSImageView {
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .tertiaryLabelColor
        return view
    }

    /// Letter badges in IntelliJ's colors: classes blue, interfaces green, methods red.
    private static func image(for kind: Breadcrumb.Kind) -> NSImage? {
        let (symbol, color): (String, NSColor) = switch kind {
        case .class: ("c.circle.fill", .systemBlue)
        case .interface: ("i.circle.fill", .systemGreen)
        case .enum: ("e.circle.fill", .systemTeal)
        case .record: ("r.circle.fill", .systemIndigo)
        case .annotation: ("at.circle.fill", .systemGreen)
        case .method, .constructor: ("m.circle.fill", .systemPink)
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color])))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds by default, so painting `dirtyRect` could cover the tab bar.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
