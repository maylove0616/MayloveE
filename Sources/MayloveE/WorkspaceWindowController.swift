import AppKit

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let rootURL: URL
    var onClose: (() -> Void)?

    private let editorArea = EditorAreaViewController()
    private var languageServer: JavaLanguageServer?
    private lazy var runController = makeRunController()

    init(rootURL: URL) {
        self.rootURL = rootURL

        let fileTree = FileTreeViewController(rootURL: rootURL)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: fileTree)
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

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "Workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        fileTree.onOpenFile = { [weak self] url in
            self?.editorArea.open(url)
        }
        editorArea.languageServerProvider = { [unowned self] in self.javaLanguageServer() }
        editorArea.onSelectionChange = { [weak self] url in self?.showSubtitle(for: url) }
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
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Only system-provided items, which AppKit creates itself.
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil
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
        if editorArea.isBottomPanelVisible {
            editorArea.hideBottomPanel()
        } else {
            editorArea.showBottomPanel(runController.console.view)
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
        runController.stop()
        languageServer?.stop()
        onClose?()
    }
}
