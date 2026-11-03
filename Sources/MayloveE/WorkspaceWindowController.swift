import AppKit

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let rootURL: URL
    var onClose: (() -> Void)?

    private let editorArea = EditorAreaViewController()
    private var languageServer: JavaLanguageServer?

    init(rootURL: URL) {
        self.rootURL = rootURL

        let fileTree = FileTreeViewController(rootURL: rootURL)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: fileTree)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 500
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: editorArea))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.title = rootURL.lastPathComponent
        window.representedURL = rootURL
        window.center()

        super.init(window: window)

        window.delegate = self
        fileTree.onOpenFile = { [weak self] url in
            self?.editorArea.open(url)
        }
        editorArea.languageServerProvider = { [unowned self] in self.javaLanguageServer() }
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

    /// Kills the language server without the shutdown handshake, for app termination.
    func terminateLanguageServer() {
        languageServer?.terminate()
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
        languageServer?.stop()
        onClose?()
    }
}
