import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(codeMenu()))
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

    private static func functionKey(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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
