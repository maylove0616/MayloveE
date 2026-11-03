import AppKit
import os

/// Tab bar plus the currently selected editor.
@MainActor
final class EditorAreaViewController: NSViewController {
    private static let logger = Logger(subsystem: "MayloveE", category: "EditorArea")

    private let tabBar = TabBarView()
    /// Editors on top, the bottom panel (console) below.
    private let splitView = NSSplitView()
    private let contentView = NSView()
    private let bottomPanel = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Double-click a file to open it")
    private let statusLabel = NSTextField(labelWithString: "")

    private var editors: [EditorViewController] = []
    private var selectedIndex: Int?

    /// Supplies the workspace's Java language server; called the first time a Java file opens.
    var languageServerProvider: (() -> JavaLanguageServer)?

    var hasOpenTabs: Bool { !editors.isEmpty }

    var selectedEditor: EditorViewController? {
        selectedIndex.map { editors[$0] }
    }

    override func loadView() {
        let container = NSView()
        emptyLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }

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

        for subview in [tabBar, splitView, emptyLabel, statusSeparator, statusLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(tabBar)
        container.addSubview(splitView)
        container.addSubview(statusSeparator)
        container.addSubview(statusLabel)
        contentView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Required: the split view's own constraints would otherwise outweigh the intrinsic height.
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            splitView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        view = container
        reloadTabBar()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    var isBottomPanelVisible: Bool { !bottomPanel.isHidden }

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

    func applyDiagnostics(_ diagnostics: [LSPDiagnostic], for url: URL) {
        editors.first { Self.isSameFile($0.url, url) }?.setDiagnostics(diagnostics)
    }

    private func add(_ editor: EditorViewController) {
        editor.onDirtyChange = { [weak self] in self?.reloadTabBar() }
        editor.onNavigate = { [weak self] location in self?.navigate(to: location) }
        addChild(editor)
        editors.append(editor)
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
    }

    private func closeTab(at index: Int) {
        let editor = editors[index]
        guard confirmSaveIfNeeded(editor) else { return }

        let previousSelection = selectedIndex
        editor.close()
        editor.view.removeFromSuperview()
        editor.removeFromParent()
        editors.remove(at: index)
        selectedIndex = nil

        guard !editors.isEmpty, let previousSelection else {
            reloadTabBar()
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
            TabBarItem(title: $0.url.lastPathComponent, toolTip: $0.url.path, isDirty: $0.isDirty)
        }
        tabBar.update(items: items, selectedIndex: selectedIndex)
        emptyLabel.isHidden = !editors.isEmpty
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
