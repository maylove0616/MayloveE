import AppKit

@MainActor
final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    /// Git status of a file, for coloring its name.
    var gitStatus: ((URL) -> GitFileChange.Kind?)?
    /// The file open in the selected editor tab, for "Select Opened File".
    var currentFile: (() -> URL?)?
    /// Called before a tree action runs, so the sidebar can switch to the tree.
    var onShowTree: (() -> Void)?

    private let root: FileNode
    private let outlineView = NSOutlineView()
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")
    private static let fontSize: CGFloat = 14

    init(rootURL: URL) {
        root = FileNode(url: rootURL, isDirectory: true)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 12
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(activateClickedRow)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        view = scrollView

        // The project folder is the single top-level node, open from the start, as in IntelliJ IDEA.
        outlineView.reloadData()
        outlineView.expandItem(root)
    }

    /// Tool window actions for the tree, shown by the sidebar next to its pane switcher.
    func makeActionsView() -> NSView {
        let locate = Self.headerButton(symbol: "scope", toolTip: "Select Opened File",
                                       action: #selector(selectOpenedFile))
        let collapse = Self.headerButton(symbol: "arrow.down.right.and.arrow.up.left", toolTip: "Collapse All",
                                         action: #selector(collapseAll))
        [locate, collapse].forEach { $0.target = self }
        let actions = NSStackView(views: [locate, collapse])
        actions.orientation = .horizontal
        actions.spacing = 6
        return actions
    }

    private static func headerButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        return button
    }

    /// Expands the tree down to the selected editor's file and selects it.
    @objc func selectOpenedFile() {
        onShowTree?()
        guard let file = currentFile?()?.standardizedFileURL.path else {
            NSSound.beep()
            return
        }
        var node = root
        outlineView.expandItem(root)
        while node.url.standardizedFileURL.path != file {
            // Compacted package nodes ("com.example.demo") point at their deepest directory.
            guard let next = node.children.first(where: {
                let path = $0.url.standardizedFileURL.path
                return path == file || file.hasPrefix(path + "/")
            }) else {
                NSSound.beep()
                return
            }
            if next.isDirectory { outlineView.expandItem(next) }
            node = next
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outlineView)
    }

    /// Collapses everything below the project folder, which stays open.
    @objc private func collapseAll() {
        onShowTree?()
        for child in root.children where child.isDirectory {
            outlineView.collapseItem(child, collapseChildren: true)
        }
    }

    /// Recolors visible rows after the Git status changed.
    func refreshStatus() {
        guard isViewLoaded else { return }
        let rows = IndexSet(integersIn: 0..<outlineView.numberOfRows)
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    /// Picks up files created or deleted on disk.
    func refreshFromDisk() {
        guard isViewLoaded else { return }
        for node in root.refresh() {
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            activate(row: outlineView.selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func activateClickedRow() {
        activate(row: outlineView.clickedRow)
    }

    private func activate(row: Int) {
        guard let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onOpenFile?(node.url)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children.count ?? 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode)?.children[index] ?? root
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        if node === root {
            return makeRootCell()
        }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.textField?.font = .systemFont(ofSize: Self.fontSize, weight: node === root ? .semibold : .regular)
        cell.toolTip = node === root ? node.url.path : nil
        if let kind = node.isDirectory ? nil : gitStatus?(node.url) {
            cell.textField?.textColor = kind.color
        } else {
            cell.textField?.textColor = node.isDimmed ? .secondaryLabelColor : .labelColor
        }
        cell.imageView?.image = FileIcon.image(for: node.url, isDirectory: node.isDirectory, isDimmed: node.isDimmed)
        return cell
    }

    /// The project folder, followed by its location dimmed, as in IntelliJ IDEA.
    private func makeRootCell() -> NSTableCellView {
        let cell = makeCell()
        cell.identifier = nil
        cell.toolTip = root.url.path
        cell.textField?.stringValue = root.name
        cell.textField?.font = .systemFont(ofSize: Self.fontSize, weight: .semibold)
        cell.textField?.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.imageView?.image = FileIcon.image(for: root.url, isDirectory: true)

        let pathLabel = NSTextField(labelWithString: (root.url.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(pathLabel)
        if let textField = cell.textField {
            // The name keeps its natural width; the path takes what is left.
            cell.constraints.filter { $0.firstItem === textField && $0.firstAttribute == .trailing }
                .forEach { $0.isActive = false }
            NSLayoutConstraint.activate([
                pathLabel.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 6),
                pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                pathLabel.firstBaselineAnchor.constraint(equalTo: textField.firstBaselineAnchor),
            ])
        }
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        for subview in [imageView, textField] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
