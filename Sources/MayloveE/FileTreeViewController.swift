import AppKit

@MainActor
final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    /// Git status of a file, for coloring its name.
    var gitStatus: ((URL) -> GitFileChange.Kind?)?

    private let root: FileNode
    private let outlineView = NSOutlineView()
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")

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
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: node === root ? .semibold : .regular)
        cell.toolTip = node === root ? node.url.path : nil
        if let kind = node.isDirectory ? nil : gitStatus?(node.url) {
            cell.textField?.textColor = kind.color
        } else {
            cell.textField?.textColor = node.isDimmed ? .secondaryLabelColor : .labelColor
        }
        cell.imageView?.image = FileIcon.image(for: node.url, isDirectory: node.isDirectory, isDimmed: node.isDimmed)
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
