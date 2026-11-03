import AppKit

/// IntelliJ IDEA's Commit tool window: changed files with checkboxes, a message, Commit / Commit and Push.
@MainActor
final class CommitViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                  NSTextViewDelegate, NSMenuItemValidation {
    struct Request {
        let message: String
        let changes: [GitFileChange]
        let amend: Bool
        let push: Bool
    }

    var onCommit: ((Request) -> Void)?
    var onShowDiff: ((GitFileChange) -> Void)?
    var onOpenFile: ((GitFileChange) -> Void)?
    var onRollback: (([GitFileChange]) -> Void)?
    var onRefresh: (() -> Void)?
    var onCreateRepository: (() -> Void)?
    /// Called when Amend is turned on with an empty message, to prefill the last commit's message.
    var onAmendWithEmptyMessage: (() -> Void)?

    private final class Group {
        let title: String
        var items: [Item] = []
        init(title: String) { self.title = title }
    }

    private final class Item {
        var change: GitFileChange
        init(_ change: GitFileChange) { self.change = change }
    }

    private let changesGroup = Group(title: "Changes")
    private let untrackedGroup = Group(title: "Unversioned Files")
    private var groups: [Group] = []
    /// Tracked changes are included by default and unversioned files excluded, as in IntelliJ.
    private var excludedTracked: Set<String> = []
    private var includedUntracked: Set<String> = []

    private let outlineView = NSOutlineView()
    private let messageView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "Commit Message")
    private let amendCheckbox = NSButton(checkboxWithTitle: "Amend", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let commitAndPushButton = NSButton(title: "Commit and Push…", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No local changes")
    private let repositoryContent = NSView()
    private let noRepositoryView = NSStackView()
    private var isBusy = false

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ChangeCell")

    var changeCount: Int { changesGroup.items.count + untrackedGroup.items.count }

    var message: String {
        get { messageView.string }
        set {
            messageView.string = newValue
            updateControls()
        }
    }

    override func loadView() {
        let container = NSView()
        configureRepositoryContent()
        configureNoRepositoryView()
        for subview in [repositoryContent, noRepositoryView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            repositoryContent.topAnchor.constraint(equalTo: container.topAnchor),
            repositoryContent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            repositoryContent.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            repositoryContent.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            noRepositoryView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            noRepositoryView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            noRepositoryView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        view = container
        show(repository: nil)
    }

    private func configureRepositoryContent() {
        let refresh = Self.button(symbol: "arrow.clockwise", tooltip: "Refresh", action: #selector(refreshClicked))
        let diff = Self.button(symbol: "arrow.left.arrow.right", tooltip: "Show Diff (⌘D)",
                               action: #selector(showDiff(_:)))
        let rollback = Self.button(symbol: "arrow.uturn.backward", tooltip: "Rollback… (⌥⌘Z)",
                                   action: #selector(rollback(_:)))
        for button in [refresh, diff, rollback] { button.target = self }
        let toolbar = NSStackView(views: [refresh, diff, rollback, NSView()])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 8
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(showDiff(_:))
        outlineView.menu = makeContextMenu()

        let listScroll = NSScrollView()
        listScroll.documentView = outlineView
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor

        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 12)
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        messageView.delegate = self
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.allowsUndo = true
        messageView.autoresizingMask = [.width]
        messageView.isVerticallyResizable = true
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .lineBorder
        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 12)

        amendCheckbox.target = self
        amendCheckbox.action = #selector(amendToggled)
        commitButton.bezelStyle = .push
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.toolTip = "Commit (⌘↩)"
        commitAndPushButton.bezelStyle = .push
        commitAndPushButton.target = self
        commitAndPushButton.action = #selector(commitAndPushClicked)
        let buttons = NSStackView(views: [commitButton, commitAndPushButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        // Below the sidebar's holding priority: a narrow sidebar squeezes the buttons instead of
        // the buttons widening the sidebar.
        for button in [commitButton, commitAndPushButton] {
            button.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        }

        let separator = NSBox()
        separator.boxType = .separator

        for subview in [toolbar, listScroll, emptyLabel, separator, messageScroll, placeholder, amendCheckbox,
                        buttons] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            repositoryContent.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: repositoryContent.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: repositoryContent.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: repositoryContent.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            listScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: repositoryContent.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: repositoryContent.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: repositoryContent.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: repositoryContent.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            messageScroll.leadingAnchor.constraint(equalTo: repositoryContent.leadingAnchor, constant: 8),
            messageScroll.trailingAnchor.constraint(equalTo: repositoryContent.trailingAnchor, constant: -8),
            messageScroll.heightAnchor.constraint(equalToConstant: 110),
            placeholder.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 7),
            placeholder.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: 10),
            amendCheckbox.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 6),
            amendCheckbox.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: amendCheckbox.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: repositoryContent.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: repositoryContent.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: repositoryContent.bottomAnchor, constant: -10),
        ])
    }

    private func configureNoRepositoryView() {
        let label = NSTextField(wrappingLabelWithString: "This folder is not under Git version control.")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        let create = NSButton(title: "Create Git Repository…", target: self, action: #selector(createRepositoryClicked))
        create.bezelStyle = .push
        noRepositoryView.orientation = .vertical
        noRepositoryView.spacing = 10
        noRepositoryView.addArrangedSubview(label)
        noRepositoryView.addArrangedSubview(create)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Diff", action: #selector(showDiff(_:)), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Jump to Source", action: #selector(jumpToSource(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let rollback = menu.addItem(withTitle: "Rollback…", action: #selector(rollback(_:)), keyEquivalent: "z")
        rollback.keyEquivalentModifierMask = [.command, .option]
        rollback.target = self
        return menu
    }

    // MARK: - State

    /// Shows the repository's changes, keeping selection and checkbox choices for files still listed.
    func show(repository: GitRepository?) {
        loadViewIfNeeded()
        repositoryContent.isHidden = repository == nil
        noRepositoryView.isHidden = repository != nil
        let changes = repository?.status.changes ?? []

        let selectedPaths = Set(selectedItems().map(\.change.path))
        changesGroup.items = items(for: changes.filter { !$0.isUntracked }, reusing: changesGroup.items)
        untrackedGroup.items = items(for: changes.filter(\.isUntracked), reusing: untrackedGroup.items)
        groups = [changesGroup, untrackedGroup].filter { !$0.items.isEmpty }
        let current = Set(changes.map(\.path))
        excludedTracked.formIntersection(current)
        includedUntracked.formIntersection(current)

        outlineView.reloadData()
        groups.forEach { outlineView.expandItem($0) }
        let rows = (0..<outlineView.numberOfRows).filter { row in
            (outlineView.item(atRow: row) as? Item).map { selectedPaths.contains($0.change.path) } ?? false
        }
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        emptyLabel.isHidden = !groups.isEmpty
        updateControls()
    }

    private func items(for changes: [GitFileChange], reusing existing: [Item]) -> [Item] {
        let byPath = Dictionary(existing.map { ($0.change.path, $0) }, uniquingKeysWith: { first, _ in first })
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { change in
            guard let item = byPath[change.path] else { return Item(change) }
            item.change = change
            return item
        }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        updateControls()
    }

    func focusMessage() {
        view.window?.makeFirstResponder(messageView)
    }

    var includedChanges: [GitFileChange] {
        (changesGroup.items + untrackedGroup.items).map(\.change).filter(isIncluded)
    }

    private func isIncluded(_ change: GitFileChange) -> Bool {
        change.isUntracked ? includedUntracked.contains(change.path) : !excludedTracked.contains(change.path)
    }

    private func setIncluded(_ included: Bool, _ change: GitFileChange) {
        if change.isUntracked {
            if included { includedUntracked.insert(change.path) } else { includedUntracked.remove(change.path) }
        } else {
            if included { excludedTracked.remove(change.path) } else { excludedTracked.insert(change.path) }
        }
    }

    private func updateControls() {
        placeholder.isHidden = !messageView.string.isEmpty
        let hasMessage = !messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let amend = amendCheckbox.state == .on
        let canCommit = !isBusy && hasMessage && (amend || !includedChanges.isEmpty)
        commitButton.isEnabled = canCommit
        commitAndPushButton.isEnabled = canCommit
    }

    /// Selected files, or the clicked row when the context menu opens outside the selection.
    private func selectedItems() -> [Item] {
        var rows = outlineView.selectedRowIndexes
        let clicked = outlineView.clickedRow
        if clicked >= 0 && !rows.contains(clicked) {
            rows = IndexSet(integer: clicked)
        }
        return rows.flatMap { row -> [Item] in
            switch outlineView.item(atRow: row) {
            case let item as Item: return [item]
            case let group as Group: return group.items
            default: return []
            }
        }
    }

    // MARK: - Actions

    @objc private func commitClicked() { requestCommit(push: false) }
    @objc private func commitAndPushClicked() { requestCommit(push: true) }

    private func requestCommit(push: Bool) {
        guard commitButton.isEnabled else { return NSSound.beep() }
        onCommit?(Request(message: messageView.string, changes: includedChanges,
                          amend: amendCheckbox.state == .on, push: push))
    }

    @objc private func amendToggled() {
        if amendCheckbox.state == .on && messageView.string.isEmpty {
            onAmendWithEmptyMessage?()
        }
        updateControls()
    }

    /// Resets the form after a successful commit.
    func didCommit() {
        message = ""
        amendCheckbox.state = .off
        updateControls()
    }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func createRepositoryClicked() { onCreateRepository?() }

    @objc func showDiff(_ sender: Any?) {
        guard let item = selectedItems().first else { return NSSound.beep() }
        onShowDiff?(item.change)
    }

    @objc func jumpToSource(_ sender: Any?) {
        guard let item = selectedItems().first, item.change.kind != .deleted else { return NSSound.beep() }
        onOpenFile?(item.change)
    }

    @objc func rollback(_ sender: Any?) {
        let changes = selectedItems().map(\.change)
        guard !changes.isEmpty else { return NSSound.beep() }
        onRollback?(changes)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !selectedItems().isEmpty
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        switch outlineView.item(atRow: row) {
        case let item as Item:
            setIncluded(sender.state == .on, item.change)
        case let group as Group:
            // A mixed group becomes fully included.
            let include = group.items.contains { !isIncluded($0.change) }
            group.items.forEach { setIncluded(include, $0.change) }
        default:
            return
        }
        let rows = IndexSet(integersIn: 0..<outlineView.numberOfRows)
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        updateControls()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateControls()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Group)?.items.count ?? (item == nil ? groups.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Group)?.items[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ChangeCellView
            ?? ChangeCellView(identifier: Self.cellIdentifier, target: self, action: #selector(checkboxClicked(_:)))
        switch item {
        case let group as Group:
            let included = group.items.filter { isIncluded($0.change) }.count
            cell.configure(state: included == 0 ? .off : included == group.items.count ? .on : .mixed,
                           icon: nil, title: group.title, titleColor: .labelColor, isBold: true,
                           detail: "\(group.items.count) file\(group.items.count == 1 ? "" : "s")")
        case let item as Item:
            let url = URL(fileURLWithPath: item.change.path)
            let directory = url.deletingLastPathComponent().relativePath
            cell.configure(state: isIncluded(item.change) ? .on : .off,
                           icon: FileIcon.image(for: url), title: url.lastPathComponent,
                           titleColor: item.change.kind.color, isBold: false,
                           detail: directory == "." ? "" : directory)
            cell.toolTip = item.change.originalPath.map { "\($0) → \(item.change.path)" } ?? item.change.path
        default:
            return nil
        }
        return cell
    }

    private static func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

/// Checkbox, icon, file name and its directory.
@MainActor
private final class ChangeCellView: NSTableCellView {
    private let checkbox: NSButton
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        checkbox = NSButton(checkboxWithTitle: "", target: target, action: action)
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.allowsMixedState = true
        iconView.imageScaling = .scaleNone
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [checkbox, iconView, titleLabel, detailLabel])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(state: NSControl.StateValue, icon: NSImage?, title: String, titleColor: NSColor,
                   isBold: Bool, detail: String) {
        checkbox.state = state
        iconView.image = icon
        iconView.isHidden = icon == nil
        titleLabel.stringValue = title
        titleLabel.textColor = titleColor
        titleLabel.font = .systemFont(ofSize: 13, weight: isBold ? .semibold : .regular)
        detailLabel.stringValue = detail
        toolTip = nil
    }
}
