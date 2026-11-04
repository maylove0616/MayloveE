import AppKit

struct ListPopupRow {
    let title: String
    let detail: String?
}

/// A borderless list shown under the caret, used for completion and navigation choices.
/// It never takes focus; the text view forwards navigation keys via `handleKey`.
@MainActor
final class ListPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows = 10
    private static let width: CGFloat = 560

    var onAccept: ((Int) -> Void)?

    private let panel: NSPanel
    private let tableView = NSTableView()
    private var rows: [ListPopupRow] = []
    private var anchor: NSRect = .zero
    private weak var parentWindow: NSWindow?

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()

        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = scrollView
    }

    var isVisible: Bool { panel.isVisible }

    /// - Parameter anchor: screen rect of the caret; the list opens below it, or above if there is no room.
    func show(rows: [ListPopupRow], anchor: NSRect, in window: NSWindow) {
        self.rows = rows
        self.anchor = anchor
        parentWindow = window
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let height = CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight + 2
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 2)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = anchor.maxY + 2
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Handles navigation keys while visible. Returns true if the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1)                       // down
        case 126: moveSelection(by: -1)                      // up
        case 121: moveSelection(by: Self.maxVisibleRows)     // page down
        case 116: moveSelection(by: -Self.maxVisibleRows)    // page up
        case 36, 76, 48: acceptSelection()                   // return, enter, tab
        case 53: hide()                                      // escape
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func acceptSelection() {
        let row = tableView.selectedRow
        hide()
        if row >= 0 { onAccept?(row) }
    }

    @objc private func tableDoubleClicked() {
        if tableView.clickedRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
            acceptSelection()
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ListPopupCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()

        let item = rows[row]
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        field.attributedStringValue = text
        return field
    }
}
