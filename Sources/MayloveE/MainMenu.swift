import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(viewMenu()))
        mainMenu.addItem(submenuItem(codeMenu()))
        mainMenu.addItem(submenuItem(runMenu()))
        mainMenu.addItem(submenuItem(gitMenu()))
        mainMenu.addItem(submenuItem(windowMenu()))
        return mainMenu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: appName)
        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(WorkspaceWindowController.closeTab(_:)), keyEquivalent: "w")
        let closeWindow = menu.addItem(withTitle: "Close Window",
                                       action: #selector(NSWindow.performClose(_:)),
                                       keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let find = menu.addItem(withTitle: "Find…",
                                action: #selector(NSTextView.performFindPanelAction(_:)),
                                keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let findNext = menu.addItem(withTitle: "Find Next",
                                    action: #selector(NSTextView.performFindPanelAction(_:)),
                                    keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        return menu
    }

    /// ⌘0 belongs to the Commit tool window (IntelliJ's keymap), so reset uses ⌥⌘0.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Increase Font Size", action: #selector(AppDelegate.increaseFontSize(_:)),
                     keyEquivalent: "=")
        menu.addItem(withTitle: "Decrease Font Size", action: #selector(AppDelegate.decreaseFontSize(_:)),
                     keyEquivalent: "-")
        menu.addItem(withTitle: "Reset Font Size", action: #selector(AppDelegate.resetFontSize(_:)),
                     keyEquivalent: "0").keyEquivalentModifierMask = [.command, .option]
        return menu
    }

    /// Shortcuts follow IntelliJ IDEA's macOS keymap.
    private static func codeMenu() -> NSMenu {
        let menu = NSMenu(title: "Code")
        menu.addItem(withTitle: "Complete Code",
                     action: #selector(WorkspaceWindowController.completeCode(_:)),
                     keyEquivalent: " ").keyEquivalentModifierMask = [.control]
        menu.addItem(withTitle: "Go to Declaration",
                     action: #selector(WorkspaceWindowController.goToDeclaration(_:)),
                     keyEquivalent: "b")
        menu.addItem(withTitle: "Find Usages",
                     action: #selector(WorkspaceWindowController.findUsages(_:)),
                     keyEquivalent: functionKey(NSF7FunctionKey)).keyEquivalentModifierMask = [.option]
        menu.addItem(withTitle: "Quick Documentation",
                     action: #selector(WorkspaceWindowController.quickDocumentation(_:)),
                     keyEquivalent: functionKey(NSF1FunctionKey)).keyEquivalentModifierMask = []
        return menu
    }

    /// Shortcuts follow IntelliJ IDEA's macOS keymap.
    private static func runMenu() -> NSMenu {
        let menu = NSMenu(title: "Run")
        menu.addItem(withTitle: "Run Context Configuration",
                     action: #selector(WorkspaceWindowController.runContext(_:)),
                     keyEquivalent: "r").keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "Rerun",
                     action: #selector(WorkspaceWindowController.rerun(_:)),
                     keyEquivalent: "r").keyEquivalentModifierMask = [.control]
        menu.addItem(withTitle: "Stop",
                     action: #selector(WorkspaceWindowController.stopRun(_:)),
                     keyEquivalent: functionKey(NSF2FunctionKey)).keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show/Hide Console",
                     action: #selector(WorkspaceWindowController.toggleConsole(_:)),
                     keyEquivalent: "4")
        return menu
    }

    /// Shortcuts follow IntelliJ IDEA's macOS keymap.
    private static func gitMenu() -> NSMenu {
        let menu = NSMenu(title: "Git")
        menu.addItem(withTitle: "Commit…", action: #selector(WorkspaceWindowController.commitChanges(_:)),
                     keyEquivalent: "k")
        menu.addItem(withTitle: "Push…", action: #selector(WorkspaceWindowController.pushChanges(_:)),
                     keyEquivalent: "k").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Update Project…", action: #selector(WorkspaceWindowController.updateProject(_:)),
                     keyEquivalent: "t")
        menu.addItem(withTitle: "Fetch", action: #selector(WorkspaceWindowController.fetchChanges(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Branches…", action: #selector(WorkspaceWindowController.showBranches(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "New Branch…", action: #selector(WorkspaceWindowController.newBranch(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Diff", action: #selector(WorkspaceWindowController.showFileDiff(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Rollback…", action: #selector(WorkspaceWindowController.rollbackFile(_:)),
                     keyEquivalent: "z").keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show Git Log", action: #selector(WorkspaceWindowController.toggleGitLog(_:)),
                     keyEquivalent: "9")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Create Git Repository…",
                     action: #selector(WorkspaceWindowController.createGitRepository(_:)), keyEquivalent: "")
        return menu
    }

    private static func functionKey(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Project", action: #selector(WorkspaceWindowController.showProjectPane(_:)),
                     keyEquivalent: "1")
        menu.addItem(withTitle: "Commit", action: #selector(WorkspaceWindowController.showCommitPane(_:)),
                     keyEquivalent: "0")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select Next Tab",
                     action: #selector(WorkspaceWindowController.selectNextTab(_:)),
                     keyEquivalent: "]").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Select Previous Tab",
                     action: #selector(WorkspaceWindowController.selectPreviousTab(_:)),
                     keyEquivalent: "[").keyEquivalentModifierMask = [.command, .shift]
        NSApp.windowsMenu = menu
        return menu
    }
}
