import AppKit
import Testing
@testable import MayloveE

@MainActor
struct SidebarLayoutTests {
    /// Regression: the Commit pane's controls used to need more width than the sidebar had,
    /// so switching to it widened the sidebar.
    @Test func switchingPanesKeepsSidebarWidth() async throws {
        _ = NSApplication.shared
        let project = try TestJavaProject.make(files: ["src/main/java/demo/App.java": "class App {}\n"])
        defer { try? FileManager.default.removeItem(at: project) }
        let git = GitClient(directory: project)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "init"])

        let controller = WorkspaceWindowController(rootURL: project)
        defer { controller.terminateProcesses() }
        let window = try #require(controller.window)
        controller.showWindow(nil)
        let split = try #require(controller.contentViewController as? NSSplitViewController)
        let sidebar = split.splitViewItems[0].viewController.view
        // Wait until the repository is found, so the Commit pane shows its full controls.
        try await TestJavaProject.waitUntil(timeout: .seconds(10)) {
            sidebar.window != nil && controller.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceWindowController.commitChanges(_:)), keyEquivalent: ""))
        }
        window.layoutIfNeeded()
        let width = sidebar.frame.width

        controller.showCommitPane(nil)
        window.layoutIfNeeded()
        #expect(sidebar.frame.width == width)

        controller.showProjectPane(nil)
        window.layoutIfNeeded()
        #expect(sidebar.frame.width == width)
    }
}
