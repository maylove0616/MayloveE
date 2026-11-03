import AppKit

/// Bottom-panel history of the current branch: commits on the left, the selected commit's files on the right.
@MainActor
final class GitLogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// Called when the commit selection changes; the owner answers with `show(files:for:)`.
    var onSelectCommit: ((GitCommit) -> Void)?
    var onShowDiff: ((GitFileChange, GitCommit) -> Void)?

    private let commitTable = NSTableView()
    private let fileTable = NSTableView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "Git Log")
    private var commits: [GitCommit] = []
    private var files: [GitFileChange] = []
    private var filesCommit: GitCommit?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let refresh = Self.button(symbol: "arrow.clockwise", tooltip: "Refresh", action: #selector(refreshClicked))
        let close = Self.button(symbol: "xmark", tooltip: "Hide (⌘9)", action: #selector(closeClicked))
        for button in [refresh, close] { button.target = self }
        let header = NSStackView(views: [titleLabel, NSView(), refresh, close])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)

        configure(commitTable, columns: [("subject", "Subject", 400), ("author", "Author", 140), ("date", "Date", 130)])
        configure(fileTable, columns: [("file", "Changed Files", 100)])
        fileTable.target = self
        fileTable.doubleAction = #selector(fileDoubleClicked)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true

        let rightPane = NSView()
        let fileScroll = Self.scrollView(for: fileTable)
        for subview in [detailLabel, fileScroll] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            rightPane.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            detailLabel.topAnchor.constraint(equalTo: rightPane.topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -8),
            fileScroll.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),
            fileScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            fileScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            fileScroll.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(Self.scrollView(for: commitTable))
        split.addArrangedSubview(rightPane)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)

        let separator = NSBox()
        separator.boxType = .separator
        let container = NSView()
        for subview in [separator, header, split] as [NSView] {
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
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = container
    }

    func show(commits: [GitCommit], branch: String?) {
        loadViewIfNeeded()
        let selectedHash = selectedCommit?.hash
        self.commits = commits
        titleLabel.stringValue = "Git Log" + (branch.map { " — \($0)" } ?? "")
        commitTable.reloadData()
        let row = commits.firstIndex { $0.hash == selectedHash } ?? (commits.isEmpty ? nil : 0)
        if let row {
            commitTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            commitTable.scrollRowToVisible(row)
        } else {
            show(files: [], for: nil)
        }
    }

    /// The selected commit's changed files, delivered by the owner after `onSelectCommit`.
    func show(files: [GitFileChange], for commit: GitCommit?) {
        guard commit?.hash == selectedCommit?.hash else { return }
        self.files = files
        filesCommit = commit
        if let commit {
            let date = Self.dateFormatter.string(from: commit.date)
            detailLabel.stringValue = "\(commit.subject)\n\(commit.shortHash) · \(commit.author) · \(date)"
                + (commit.refs.isEmpty ? "" : "\n\(commit.refs)")
        } else {
            detailLabel.stringValue = ""
        }
        fileTable.reloadData()
    }

    private var selectedCommit: GitCommit? {
        let row = commitTable.selectedRow
        return row >= 0 && row < commits.count ? commits[row] : nil
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func closeClicked() { onClose?() }

    @objc private func fileDoubleClicked() {
        let row = fileTable.clickedRow
        guard row >= 0, row < files.count, let filesCommit else { return }
        onShowDiff?(files[row], filesCommit)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === commitTable ? commits.count : files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(column), owner: self)
            as? NSTableCellView ?? Self.makeCell(identifier: column)
        let label = cell.textField
        label?.textColor = .labelColor
        cell.imageView?.image = nil
        if tableView === commitTable {
            let commit = commits[row]
            switch column {
            case "subject":
                label?.attributedStringValue = Self.subject(commit)
            case "author":
                label?.stringValue = commit.author
                label?.textColor = .secondaryLabelColor
            default:
                label?.stringValue = Self.dateFormatter.string(from: commit.date)
                label?.textColor = .secondaryLabelColor
            }
        } else {
            let change = files[row]
            label?.stringValue = change.originalPath.map { "\($0) → \(change.path)" } ?? change.path
            label?.textColor = change.kind.color
            // Keep the file name visible; long paths lose their start.
            label?.lineBreakMode = .byTruncatingHead
            cell.imageView?.image = FileIcon.image(for: URL(fileURLWithPath: change.path))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === commitTable else { return }
        if let selectedCommit {
            onSelectCommit?(selectedCommit)
        } else {
            show(files: [], for: nil)
        }
    }

    /// Branch and tag labels before the subject, as in IntelliJ's log.
    private static func subject(_ commit: GitCommit) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let refs = commit.refs.components(separatedBy: ", ").filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "HEAD -> ", with: "") }
        for ref in refs where ref != "HEAD" {
            text.append(NSAttributedString(string: " \(ref) ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: ref.contains("/") ? NSColor.systemPurple : NSColor.systemGreen,
            ]))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: commit.subject, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]))
        return text
    }

    private func configure(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
    }

    private static func scrollView(for table: NSTableView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    private static func makeCell(identifier: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        // The label truncates rather than squeezing the icon.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [imageView, label])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.imageView = imageView
        cell.textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}
