import AppKit

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                       NSMenuItemValidation {
    let rootURL: URL
    var onClose: (() -> Void)?

    private let editorArea = EditorAreaViewController()
    private let fileTree: FileTreeViewController
    private let sidebar: SidebarViewController
    private let git: GitController
    private var fileWatcher: FileWatcher?
    private var languageServer: JavaLanguageServer?
    private lazy var runController = makeRunController()
    /// What ▶ runs for the caret, shown in the toolbar like IntelliJ's run configuration widget.
    private let runTargetButton = NSButton(title: "Current File", target: nil, action: nil)
    private let runButton = WorkspaceWindowController.toolbarButton(
        symbol: "play.fill", color: .systemGreen, toolTip: "Run Context Configuration (⌃⇧R)")
    private let stopButton = WorkspaceWindowController.toolbarButton(
        symbol: "stop.fill", color: .systemRed, toolTip: "Stop (⌘F2)")

    init(rootURL: URL) {
        self.rootURL = rootURL

        let fileTree = FileTreeViewController(rootURL: rootURL)
        let commitView = CommitViewController()
        let sidebar = SidebarViewController(project: fileTree, commit: commitView,
                                            actions: fileTree.makeActionsView())
        self.fileTree = fileTree
        self.sidebar = sidebar

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 500
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: editorArea))

        // Full-size content lets the sidebar run up under the unified toolbar, as in Xcode and Finder.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 800))
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        window.title = rootURL.lastPathComponent
        window.representedURL = rootURL
        window.toolbarStyle = .unified
        window.center()

        git = GitController(rootURL: rootURL, editorArea: editorArea, fileTree: fileTree, sidebar: sidebar,
                            commitView: commitView, window: window)

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "Workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        fileTree.currentFile = { [weak self] in self?.editorArea.selectedEditor?.url }
        fileTree.onShowTree = { [weak sidebar] in sidebar?.select(.project) }
        fileTree.onOpenFile = { [weak self] url in
            self?.editorArea.open(url)
        }
        editorArea.languageServerProvider = { [unowned self] in self.javaLanguageServer() }
        editorArea.onSelectionChange = { [weak self] url in self?.showSubtitle(for: url) }
        editorArea.onCaretChange = { [weak self] in self?.updateRunTarget() }
        configureRunButtons()
        git.onRepositoryChange = { [weak self] repository in self?.watchFiles(gitDirectoryOf: repository) }
        watchFiles(gitDirectoryOf: nil)
    }

    /// Files changed outside the editor (terminal git, builds, other apps): refresh the tree,
    /// reload editors without unsaved changes, and re-read the Git status. A repository whose
    /// top level is above the opened folder has its .git directory watched as well.
    private func watchFiles(gitDirectoryOf repository: GitRepository?) {
        var urls = [rootURL]
        // The top level is the opened folder or one of its ancestors.
        if let repository, repository.root.path != rootURL.standardizedFileURL.path {
            urls.append(repository.root.appendingPathComponent(".git"))
        }
        fileWatcher?.stop()
        fileWatcher = FileWatcher(urls: urls) { [weak self] _ in
            guard let self else { return }
            self.fileTree.refreshFromDisk()
            self.editorArea.reloadEditorsFromDisk()
            self.git.refresh()
        }
    }

    private static let sidebarWidth: CGFloat = 260

    /// The selected file's path relative to the project, like Xcode's window subtitle.
    private func showSubtitle(for url: URL?) {
        guard let url else {
            window?.subtitle = ""
            return
        }
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let path = url.isFileURL ? url.standardizedFileURL.path : url.lastPathComponent
        window?.subtitle = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.branchItem, .flexibleSpace,
         Self.runTargetItem, Self.runItem, Self.stopItem]
    }

    private static let branchItem = NSToolbarItem.Identifier("Branch")
    private static let runTargetItem = NSToolbarItem.Identifier("RunTarget")
    private static let runItem = NSToolbarItem.Identifier("Run")
    private static let stopItem = NSToolbarItem.Identifier("Stop")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let views: [NSToolbarItem.Identifier: (label: String, view: NSView)] = [
            Self.branchItem: ("Branch", git.branchButton),
            Self.runTargetItem: ("Run Configuration", runTargetButton),
            Self.runItem: ("Run", runButton),
            Self.stopItem: ("Stop", stopButton),
        ]
        guard let entry = views[itemIdentifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = entry.label
        item.view = entry.view
        return item
    }

    private static func toolbarButton(symbol: String, color: NSColor, toolTip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.contentTintColor = color
        button.toolTip = toolTip
        return button
    }

    private func configureRunButtons() {
        runTargetButton.bezelStyle = .toolbar
        runTargetButton.imagePosition = .imageLeading
        runTargetButton.target = self
        runTargetButton.action = #selector(runContext(_:))
        runButton.target = self
        runButton.action = #selector(runContext(_:))
        stopButton.target = self
        stopButton.action = #selector(stopRun(_:))
        stopButton.isEnabled = false
        updateRunTarget()
    }

    /// Shows what Run would execute at the caret; disabled when there is nothing to run.
    private func updateRunTarget() {
        let target = editorArea.selectedEditor?.runTarget()
        runTargetButton.title = target?.title ?? "Current File"
        runTargetButton.image = Self.runTargetImage(for: target)
        runTargetButton.toolTip = target.map { "Run \($0.title) (⌃⇧R)" } ?? "Nothing to run at the caret"
        runTargetButton.isEnabled = target != nil
        runButton.isEnabled = target != nil
    }

    private static func runTargetImage(for target: RunTarget?) -> NSImage? {
        let (symbol, color): (String, NSColor) = switch target {
        case .mainClass: ("cup.and.saucer.fill", .systemOrange)
        case .testClass, .testMethod: ("checkmark.diamond.fill", .systemGreen)
        case nil: ("doc", .secondaryLabelColor)
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    }

    /// Started lazily so non-Java folders never pay for a JVM.
    private func javaLanguageServer() -> JavaLanguageServer {
        if let languageServer { return languageServer }
        let server = JavaLanguageServer(rootURL: rootURL)
        server.onStatusChange = { [weak self] status in self?.showLanguageServerStatus(status) }
        server.onDiagnostics = { [weak self] url, diagnostics in
            self?.editorArea.applyDiagnostics(diagnostics, for: url)
        }
        languageServer = server
        server.start()
        return server
    }

    private func showLanguageServerStatus(_ status: JavaLanguageServer.Status) {
        switch status {
        case .starting(let message): editorArea.setStatus("Java: \(message)")
        case .ready: editorArea.setStatus("Java: ready")
        case .failed(let message): editorArea.setStatus("Java unavailable: \(message)")
        case .stopped: editorArea.setStatus("")
        }
    }

    private func makeRunController() -> RunController {
        let controller = RunController(rootURL: rootURL) { [unowned self] in self.javaLanguageServer() }
        controller.onShowConsole = { [unowned self, unowned controller] in
            self.editorArea.showBottomPanel(controller.console.view)
        }
        controller.onHideConsole = { [unowned self] in self.editorArea.hideBottomPanel() }
        controller.onOpenLocation = { [unowned self] location in self.editorArea.navigate(to: location) }
        controller.saveAll = { [unowned self] in self.editorArea.saveAll() }
        controller.console.onRunningChange = { [unowned self] running in self.stopButton.isEnabled = running }
        return controller
    }

    /// Kills child processes without graceful shutdown, for app termination.
    func terminateProcesses() {
        runController.stop()
        languageServer?.terminate()
    }

    // MARK: - Run menu (IntelliJ IDEA macOS keymap)

    @objc func runContext(_ sender: Any?) {
        guard let editor = editorArea.selectedEditor, let target = editor.runTarget() else {
            NSSound.beep()
            editorArea.setStatus("Nothing to run: put the caret in a class with main() or a test")
            return
        }
        runController.run(target, from: editor.url)
    }

    @objc func rerun(_ sender: Any?) {
        runController.rerun()
    }

    @objc func stopRun(_ sender: Any?) {
        runController.stop()
    }

    @objc func toggleConsole(_ sender: Any?) {
        if editorArea.isShowingInBottomPanel(runController.console.view) {
            editorArea.hideBottomPanel()
        } else {
            editorArea.showBottomPanel(runController.console.view)
        }
    }

    // MARK: - Git menu (IntelliJ IDEA macOS keymap)

    @objc func commitChanges(_ sender: Any?) { git.showCommit() }
    @objc func pushChanges(_ sender: Any?) { git.push() }
    @objc func updateProject(_ sender: Any?) { git.pull() }
    @objc func fetchChanges(_ sender: Any?) { git.fetch() }
    @objc func showBranches(_ sender: Any?) { git.showBranchMenu(sender) }
    @objc func newBranch(_ sender: Any?) { git.newBranch() }
    @objc func toggleGitLog(_ sender: Any?) { git.toggleLog() }
    @objc func showFileDiff(_ sender: Any?) { git.showDiffForCurrentFile() }
    @objc func rollbackFile(_ sender: Any?) { git.rollbackCurrentFile() }
    @objc func createGitRepository(_ sender: Any?) { git.createRepository() }
    @objc func showProjectPane(_ sender: Any?) { sidebar.select(.project) }
    @objc func showCommitPane(_ sender: Any?) { git.showCommit() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(createGitRepository(_:)):
            return git.repository == nil
        case #selector(commitChanges(_:)), #selector(pushChanges(_:)), #selector(updateProject(_:)),
             #selector(fetchChanges(_:)), #selector(newBranch(_:)), #selector(toggleGitLog(_:)),
             #selector(showFileDiff(_:)), #selector(rollbackFile(_:)):
            return git.repository != nil
        default:
            return true
        }
    }

    @objc func completeCode(_ sender: Any?) {
        editorArea.selectedEditor?.triggerCompletion()
    }

    @objc func goToDeclaration(_ sender: Any?) {
        editorArea.selectedEditor?.goToDefinition()
    }

    @objc func findUsages(_ sender: Any?) {
        editorArea.selectedEditor?.findReferences()
    }

    @objc func quickDocumentation(_ sender: Any?) {
        editorArea.selectedEditor?.showQuickDocumentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc func closeTab(_ sender: Any?) {
        if editorArea.hasOpenTabs {
            editorArea.closeSelectedTab()
        } else {
            window?.performClose(sender)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        editorArea.saveSelectedEditor()
    }

    @objc func selectNextTab(_ sender: Any?) {
        editorArea.selectAdjacentTab(offset: 1)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        editorArea.selectAdjacentTab(offset: -1)
    }

    /// Returns false if the user cancelled closing because of unsaved changes.
    func confirmCloseAll() -> Bool {
        editorArea.confirmCloseAll()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editorArea.confirmCloseAll()
    }

    func windowWillClose(_ notification: Notification) {
        fileWatcher?.stop()
        runController.stop()
        languageServer?.stop()
        onClose?()
    }
}
