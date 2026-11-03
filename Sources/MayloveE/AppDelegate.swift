import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspaces: [WorkspaceWindowController] = []

    static func main() {
        // Writing to a language server that has exited must fail with an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NSApp.activate()

        // Allow `MayloveE <folder>` for quick launches from the terminal.
        let arguments = CommandLine.arguments.dropFirst()
        if let path = arguments.first {
            openWorkspace(at: URL(fileURLWithPath: path).standardizedFileURL)
        } else {
            openFolder(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspaces.allSatisfy { $0.confirmCloseAll() } ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaces.forEach { $0.terminateProcesses() }
    }

    @objc func increaseFontSize(_ sender: Any?) { CodeFont.increase() }
    @objc func decreaseFontSize(_ sender: Any?) { CodeFont.decrease() }
    @objc func resetFontSize(_ sender: Any?) { CodeFont.reset() }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(at: url)
    }

    private func openWorkspace(at url: URL) {
        if let existing = workspaces.first(where: { $0.rootURL == url }) {
            existing.showWindow(nil)
            return
        }
        let controller = WorkspaceWindowController(rootURL: url)
        controller.onClose = { [weak self, weak controller] in
            self?.workspaces.removeAll { $0 === controller }
        }
        workspaces.append(controller)
        controller.showWindow(nil)
    }
}
