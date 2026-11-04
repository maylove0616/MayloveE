import AppKit
import os

/// Tab bar plus the currently selected editor.
@MainActor
final class EditorAreaViewController: NSViewController {
    private static let logger = Logger(subsystem: "MayloveE", category: "EditorArea")

    private let tabBar = TabBarView()
    private let breadcrumbBar = BreadcrumbBar()
    private var breadcrumbHeight: NSLayoutConstraint!
    private var tabBarHeight: NSLayoutConstraint!
    /// Editors on top, the bottom panel (console) below.
    private let splitView = NSSplitView()
    private let contentView = NSView()
    private let bottomPanel = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Double-click a file to open it")
    private let statusLabel = NSTextField(labelWithString: "")
    /// Caret position, line separator, encoding and indent of the selected editor.
    private let editorInfo = NSStackView()
    private let caretLabel = EditorAreaViewController.infoLabel()
    private let lineSeparatorLabel = EditorAreaViewController.infoLabel()

    private var editors: [EditorViewController] = []
    private var selectedIndex: Int?

    /// Supplies the workspace's Java language server; called the first time a Java file opens.
    var languageServerProvider: (() -> JavaLanguageServer)?
    /// Called with the selected editor's URL, or nil when the last tab closes.
    var onSelectionChange: ((URL?) -> Void)?
    /// Called after the selected editor's caret moved or another editor was selected.
    var onCaretChange: (() -> Void)?
    /// Git status of a file, for coloring its tab title.
    var gitStatus: ((URL) -> GitFileChange.Kind?)?
    /// The committed contents of a file, for the gutter's change bars.
    var gitBase: ((URL) async -> String?)?

    var hasOpenTabs: Bool { !editors.isEmpty }

    var selectedEditor: EditorViewController? {
        selectedIndex.map { editors[$0] }
    }

    override func loadView() {
        let container = NSView()
        emptyLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        breadcrumbBar.onSelect = { [weak self] crumb in self?.selectedEditor?.reveal(crumb.nameRange) }

        // Only UTF-8 files are editable, and Tab inserts `Indentation.unit`.
        let encodingLabel = Self.infoLabel()
        encodingLabel.stringValue = "UTF-8"
        let indentLabel = Self.infoLabel()
        indentLabel.stringValue = "\(Indentation.unit.count) spaces"
        for label in [caretLabel, lineSeparatorLabel, encodingLabel, indentLabel] {
            editorInfo.addArrangedSubview(label)
        }
        editorInfo.spacing = 16
        editorInfo.isHidden = true
        breadcrumbBar.isHidden = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(contentView)
        splitView.addArrangedSubview(bottomPanel)
        // The console keeps its height when the window resizes.
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        bottomPanel.isHidden = true

        for subview in [tabBar, breadcrumbBar, splitView, emptyLabel, statusSeparator, statusLabel, editorInfo]
            as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(tabBar)
        container.addSubview(breadcrumbBar)
        container.addSubview(editorInfo)
        breadcrumbHeight = breadcrumbBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        container.addSubview(splitView)
        container.addSubview(statusSeparator)
        container.addSubview(statusLabel)
        contentView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            // Below the toolbar: the window's content view extends under it.
            tabBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Required: the split view's own constraints would otherwise outweigh the intrinsic height.
            tabBarHeight,
            breadcrumbBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            breadcrumbHeight,
            splitView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -26),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: editorInfo.leadingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
            editorInfo.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            editorInfo.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        view = container
        reloadTabBar()
    }

    private static func infoLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Refreshes the breadcrumbs and the status bar's editor details for the selected editor.
    private func updateCaretInfo() {
        guard let editor = selectedEditor else {
            editorInfo.isHidden = true
            breadcrumbBar.isHidden = true
            breadcrumbHeight.constant = 0
            onCaretChange?()
            return
        }
        let caret = editor.caretLocation
        caretLabel.stringValue = caret.selectedLength > 0
            ? "\(caret.line):\(caret.column) (\(caret.selectedLength) chars)"
            : "\(caret.line):\(caret.column)"
        lineSeparatorLabel.stringValue = editor.lineSeparatorName
        editorInfo.isHidden = false
        breadcrumbBar.update(file: editor.url, crumbs: editor.breadcrumbs())
        breadcrumbBar.isHidden = false
        breadcrumbHeight.constant = BreadcrumbBar.height
        onCaretChange?()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    var isBottomPanelVisible: Bool { !bottomPanel.isHidden }

    func isShowingInBottomPanel(_ panel: NSView) -> Bool {
        isBottomPanelVisible && panel.superview === bottomPanel
    }

    /// Shows `panel` (e.g. the console) below the editors, giving it about a third of the height.
    func showBottomPanel(_ panel: NSView) {
        if panel.superview !== bottomPanel {
            bottomPanel.subviews.forEach { $0.removeFromSuperview() }
            panel.frame = bottomPanel.bounds
            panel.autoresizingMask = [.width, .height]
            bottomPanel.addSubview(panel)
        }
        guard bottomPanel.isHidden else { return }
        bottomPanel.isHidden = false
        splitView.adjustSubviews()
        splitView.setPosition(splitView.bounds.height * 0.65, ofDividerAt: 0)
    }

    func hideBottomPanel() {
        bottomPanel.isHidden = true
        splitView.adjustSubviews()
        selectedEditor?.didBecomeVisible()
    }

    /// Saves every modified editor, e.g. before a build; returns false if any save failed.
    func saveAll() -> Bool {
        editors.filter(\.isDirty).allSatisfy { save($0) }
    }

    func open(_ url: URL) {
        if let index = editors.firstIndex(where: { Self.isSameFile($0.url, url) }) {
            select(index)
            return
        }
        let server = url.pathExtension == "java" ? languageServerProvider?() : nil
        add(EditorViewController(url: url, languageServer: server))
    }

    /// Opens a declaration or usage: a project file, or JDK/library source fetched from jdtls.
    func navigate(to location: LSPLocation) {
        if location.url.isFileURL || editors.contains(where: { Self.isSameFile($0.url, location.url) }) {
            open(location.url)
            selectedEditor?.reveal(location.range)
            return
        }
        guard let server = languageServerProvider?() else { return }
        Task {
            do {
                guard let contents = try await server.classFileContents(location.url) else {
                    setStatus("No source available for \(location.url.lastPathComponent)")
                    return
                }
                add(EditorViewController(url: location.url, contents: contents, isEditable: false,
                                         languageServer: server))
                selectedEditor?.reveal(location.range)
            } catch {
                Self.logger.error("Cannot load \(location.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                setStatus("Cannot open \(location.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Recolors tab titles after the Git status changed.
    func refreshGitStatus() {
        reloadTabBar()
    }

    /// Re-reads every editor's committed contents, e.g. after a commit or branch switch.
    func refreshGitBases() {
        editors.forEach(loadGitBase)
    }

    /// Reloads editors without unsaved changes whose files changed on disk.
    func reloadEditorsFromDisk() {
        for editor in editors where editor.reloadFromDisk() {
            loadGitBase(for: editor)
        }
    }

    /// After a Git rollback: rolled-back files lose their unsaved changes, deleted files lose their tabs.
    func discardChanges(in urls: [URL]) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        for index in editors.indices.reversed() where paths.contains(editors[index].url.standardizedFileURL.path) {
            let editor = editors[index]
            if FileManager.default.fileExists(atPath: editor.url.path) {
                editor.reloadFromDisk(discardingChanges: true)
                loadGitBase(for: editor)
            } else {
                closeTab(at: index, confirm: false)
            }
        }
    }

    /// The text of an open editor (with unsaved changes), if the file is open.
    func openText(of url: URL) -> String? {
        editors.first { Self.isSameFile($0.url, url) }?.text
    }

    private func loadGitBase(for editor: EditorViewController) {
        guard let gitBase, editor.url.isFileURL else { return }
        let url = editor.url
        Task { [weak editor] in
            let base = await gitBase(url)
            editor?.gitBase = base
        }
    }

    func applyDiagnostics(_ diagnostics: [LSPDiagnostic], for url: URL) {
        editors.first { Self.isSameFile($0.url, url) }?.setDiagnostics(diagnostics)
    }

    private func add(_ editor: EditorViewController) {
        editor.onDirtyChange = { [weak self] in self?.reloadTabBar() }
        editor.onNavigate = { [weak self] location in self?.navigate(to: location) }
        editor.onCaretChange = { [weak self, weak editor] in
            guard let self, let editor, editor === self.selectedEditor else { return }
            self.updateCaretInfo()
        }
        addChild(editor)
        editors.append(editor)
        loadGitBase(for: editor)
        select(editors.count - 1)
    }

    /// File URLs compare by path; jdt:// URLs for library sources compare exactly.
    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.isFileURL && rhs.isFileURL {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }
        return lhs.absoluteString == rhs.absoluteString
    }

    func saveSelectedEditor() {
        if let editor = selectedEditor {
            save(editor)
        }
    }

    func closeSelectedTab() {
        if let selectedIndex {
            closeTab(at: selectedIndex)
        }
    }

    /// Selects the tab `offset` positions away, wrapping around.
    func selectAdjacentTab(offset: Int) {
        guard let selectedIndex, !editors.isEmpty else { return }
        let count = editors.count
        select(((selectedIndex + offset) % count + count) % count)
    }

    /// Asks about every unsaved editor; returns false if the user cancelled.
    func confirmCloseAll() -> Bool {
        editors.allSatisfy { confirmSaveIfNeeded($0) }
    }

    private func select(_ index: Int) {
        let editor = editors[index]
        if let current = selectedEditor, current !== editor {
            current.willBecomeHidden()
            current.view.removeFromSuperview()
        }
        selectedIndex = index

        if editor.view.superview == nil {
            editor.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(editor.view)
            NSLayoutConstraint.activate([
                editor.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                editor.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                editor.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                editor.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        reloadTabBar()
        editor.didBecomeVisible()
        updateCaretInfo()
        onSelectionChange?(editor.url)
    }

    private func closeTab(at index: Int, confirm: Bool = true) {
        let editor = editors[index]
        guard !confirm || confirmSaveIfNeeded(editor) else { return }

        let previousSelection = selectedIndex
        editor.close()
        editor.view.removeFromSuperview()
        editor.removeFromParent()
        editors.remove(at: index)
        selectedIndex = nil

        guard !editors.isEmpty, let previousSelection else {
            reloadTabBar()
            updateCaretInfo()
            onSelectionChange?(nil)
            return
        }
        if previousSelection > index {
            select(previousSelection - 1)
        } else {
            select(min(previousSelection, editors.count - 1))
        }
    }

    private func confirmSaveIfNeeded(_ editor: EditorViewController) -> Bool {
        guard editor.isDirty else { return true }
        switch SavePrompt.ask(fileName: editor.url.lastPathComponent) {
        case .save: return save(editor)
        case .discard: return true
        case .cancel: return false
        }
    }

    @discardableResult
    private func save(_ editor: EditorViewController) -> Bool {
        do {
            try editor.save()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private func reloadTabBar() {
        let items = editors.map {
            TabBarItem(title: $0.url.lastPathComponent, toolTip: $0.url.path, isDirty: $0.isDirty,
                       icon: FileIcon.image(for: $0.url), titleColor: gitStatus?($0.url)?.color)
        }
        tabBar.update(items: items, selectedIndex: selectedIndex)
        emptyLabel.isHidden = !editors.isEmpty
        // No empty strip above the placeholder when nothing is open.
        tabBar.isHidden = editors.isEmpty
        tabBarHeight.constant = editors.isEmpty ? 0 : TabBarView.height
    }
}

@MainActor
private enum SavePrompt {
    enum Choice { case save, discard, cancel }

    static func ask(fileName: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
