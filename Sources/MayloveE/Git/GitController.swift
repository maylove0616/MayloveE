import AppKit
import os

/// Connects a workspace's Git repository to its views: status colors, the Commit tool window,
/// the branch widget, the log panel, diff windows, and remote operations.
@MainActor
final class GitController {
    private static let logger = Logger(subsystem: "MayloveE", category: "GitController")

    let commitView: CommitViewController
    let logView = GitLogViewController()
    /// The toolbar's branch widget.
    let branchButton = NSButton(title: "Git", target: nil, action: nil)
    private(set) var repository: GitRepository?
    /// Called when the repository is found or created, e.g. to watch its .git directory.
    var onRepositoryChange: ((GitRepository) -> Void)?

    private let rootURL: URL
    private let editorArea: EditorAreaViewController
    private let fileTree: FileTreeViewController
    private let sidebar: SidebarViewController
    private weak var window: NSWindow?
    private var diffWindows: [DiffWindowController] = []
    private var headOID: String?
    private var isBusy = false

    init(rootURL: URL, editorArea: EditorAreaViewController, fileTree: FileTreeViewController,
         sidebar: SidebarViewController, commitView: CommitViewController, window: NSWindow?) {
        self.rootURL = rootURL
        self.commitView = commitView
        self.editorArea = editorArea
        self.fileTree = fileTree
        self.sidebar = sidebar
        self.window = window

        branchButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        branchButton.imagePosition = .imageLeading
        branchButton.bezelStyle = .toolbar
        branchButton.target = self
        branchButton.action = #selector(showBranchMenu(_:))
        branchButton.toolTip = "Git Branches"

        editorArea.gitStatus = { [weak self] url in self?.repository?.change(for: url)?.kind }
        editorArea.gitBase = { [weak self] url in await self?.repository?.headContents(of: url) }
        fileTree.gitStatus = { [weak self] url in self?.repository?.change(for: url)?.kind }
        configureCommitView()
        configureLogView()
        updateBranchButton()

        Task {
            if let repository = await GitRepository.open(containing: rootURL) {
                attach(repository)
            }
        }
    }

    private func attach(_ repository: GitRepository) {
        self.repository = repository
        repository.onChange = { [weak self] in self?.statusDidChange() }
        onRepositoryChange?(repository)
        statusDidChange()
    }

    func refresh() {
        guard let repository else { return }
        Task { await repository.refresh() }
    }

    private func statusDidChange() {
        guard let repository else { return }
        fileTree.refreshStatus()
        editorArea.refreshGitStatus()
        commitView.show(repository: repository)
        sidebar.setCommitCount(commitView.changeCount)
        updateBranchButton()
        if repository.status.headOID != headOID {
            headOID = repository.status.headOID
            editorArea.refreshGitBases()
            if editorArea.isShowingInBottomPanel(logView.view) {
                reloadLog()
            }
        }
    }

    private func updateBranchButton() {
        guard let repository else {
            branchButton.title = "Version Control"
            return
        }
        let status = repository.status
        var title = status.branch ?? status.headOID.map { "Detached \($0.prefix(7))" } ?? "No commits"
        if status.ahead > 0 { title += " ↑\(status.ahead)" }
        if status.behind > 0 { title += " ↓\(status.behind)" }
        branchButton.title = title
    }

    // MARK: - Commit tool window

    private func configureCommitView() {
        commitView.onCommit = { [weak self] request in self?.commit(request) }
        commitView.onShowDiff = { [weak self] change in self?.showDiff(for: change) }
        commitView.onOpenFile = { [weak self] change in
            guard let self, let repository = self.repository else { return }
            self.editorArea.open(repository.url(for: change.path))
        }
        commitView.onRollback = { [weak self] changes in self?.rollback(changes) }
        commitView.onRefresh = { [weak self] in self?.refresh() }
        commitView.onCreateRepository = { [weak self] in self?.createRepository() }
        commitView.onAmendWithEmptyMessage = { [weak self] in
            guard let repository = self?.repository else { return }
            Task {
                if let message = await repository.lastCommitMessage(), self?.commitView.message.isEmpty == true {
                    self?.commitView.message = message
                }
            }
        }
    }

    /// ⌘K: shows the Commit tool window with the message focused.
    func showCommit() {
        sidebar.select(.commit)
        commitView.focusMessage()
        refresh()
    }

    private func commit(_ request: CommitViewController.Request) {
        guard let repository, editorArea.saveAll() else { return }
        perform("Committing…") {
            try await repository.commit(message: request.message, changes: request.changes, amend: request.amend)
            self.commitView.didCommit()
            let count = request.changes.count
            self.editorArea.setStatus("Committed \(count) file\(count == 1 ? "" : "s")")
            if request.push {
                try await self.pushAfterConfirmation()
            }
        }
    }

    // MARK: - Rollback and diff

    /// ⌥⌘Z outside the Commit tool window rolls back the current file.
    func rollbackCurrentFile() {
        guard let url = editorArea.selectedEditor?.url, let change = repository?.change(for: url) else {
            return NSSound.beep()
        }
        rollback([change])
    }

    private func rollback(_ changes: [GitFileChange]) {
        guard let repository, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = changes.count == 1
            ? "Rollback changes in \(URL(fileURLWithPath: changes[0].path).lastPathComponent)?"
            : "Rollback changes in \(changes.count) files?"
        let removed = changes.filter { $0.kind == .untracked || $0.kind == .added }.count
        alert.informativeText = "Local changes will be lost."
            + (removed > 0 ? " \(removed) new file\(removed == 1 ? "" : "s") will be deleted from disk." : "")
            + "\n\n" + changes.prefix(10).map(\.path).joined(separator: "\n")
            + (changes.count > 10 ? "\n…" : "")
        alert.addButton(withTitle: "Rollback")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.perform("Rolling back…") {
                    try await repository.rollback(changes)
                    let urls = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
                        .map(repository.url(for:))
                    self.editorArea.discardChanges(in: urls)
                    self.fileTree.refreshFromDisk()
                }
            }
        }
    }

    /// Diff of a local change against HEAD; the right side is the editor's text when the file is open.
    func showDiff(for change: GitFileChange) {
        guard let repository else { return }
        Task {
            let fileURL = repository.url(for: change.path)
            let basePath = change.originalPath ?? change.path
            let base = change.kind == .untracked || change.kind == .added
                ? "" : await repository.contents(of: basePath, at: "HEAD") ?? ""
            let current = change.kind == .deleted
                ? "" : editorArea.openText(of: fileURL) ?? (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let head = repository.status.headOID.map { "HEAD (\($0.prefix(7)))" } ?? "HEAD"
            openDiff(path: change.path, left: .init(label: "\(head) — \(basePath)", text: base),
                     right: .init(label: "Your version — \(change.path)", text: current))
        }
    }

    /// ⌘D outside the Commit tool window: the current file against HEAD.
    func showDiffForCurrentFile() {
        guard let url = editorArea.selectedEditor?.url, let change = repository?.change(for: url) else {
            return NSSound.beep()
        }
        showDiff(for: change)
    }

    private func showDiff(for change: GitFileChange, in commit: GitCommit) {
        guard let repository else { return }
        Task {
            let parent = commit.parents.first
            let basePath = change.originalPath ?? change.path
            let base = change.kind == .added || parent == nil
                ? "" : await repository.contents(of: basePath, at: parent ?? "") ?? ""
            let current = change.kind == .deleted ? "" : await repository.contents(of: change.path, at: commit.hash) ?? ""
            openDiff(path: change.path,
                     left: .init(label: "\(parent.map { String($0.prefix(7)) } ?? "Empty") — \(basePath)", text: base),
                     right: .init(label: "\(commit.shortHash) — \(change.path)", text: current))
        }
    }

    private func openDiff(path: String, left: DiffWindowController.Version, right: DiffWindowController.Version) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let controller = DiffWindowController(title: "Diff: \(name)", fileName: name, left: left, right: right)
        controller.onClose = { [weak self, weak controller] in
            self?.diffWindows.removeAll { $0 === controller }
        }
        diffWindows.append(controller)
        controller.showWindow(nil)
    }

    // MARK: - Branches

    @objc func showBranchMenu(_ sender: Any?) {
        let menu = NSMenu()
        guard let repository else {
            menu.addItem(Self.item("Create Git Repository…") { [weak self] in self?.createRepository() })
            popUp(menu)
            return
        }
        menu.addItem(Self.item("Update Project…", shortcut: ("t", [.command])) { [weak self] in self?.pull() })
        menu.addItem(Self.item("Commit…", shortcut: ("k", [.command])) { [weak self] in self?.showCommit() })
        menu.addItem(Self.item("Push…", shortcut: ("k", [.command, .shift])) { [weak self] in self?.push() })
        menu.addItem(Self.item("Fetch") { [weak self] in self?.fetch() })
        menu.addItem(.separator())
        menu.addItem(Self.item("New Branch…") { [weak self] in self?.newBranch() })

        let local = repository.branches.filter { !$0.isRemote }
        if !local.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Local"))
            for branch in local {
                let item = Self.item(branch.name) { [weak self] in self?.checkout(branch) }
                item.state = branch.isCurrent ? .on : .off
                item.toolTip = branch.upstream.map { "Tracks \($0)" }
                menu.addItem(item)
            }
        }
        let remote = repository.branches.filter(\.isRemote)
        if !remote.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Remote"))
            for branch in remote {
                menu.addItem(Self.item(branch.name) { [weak self] in self?.checkout(branch) })
            }
        }
        popUp(menu)
    }

    private func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: branchButton.bounds.height + 4), in: branchButton)
    }

    private func checkout(_ branch: GitBranch) {
        guard let repository, !branch.isCurrent, editorArea.saveAll() else { return }
        perform("Checking out \(branch.name)…") {
            try await repository.checkout(branch)
            self.didChangeWorkingTree()
            self.editorArea.setStatus("Checked out \(repository.status.branch ?? branch.name)")
        }
    }

    func newBranch() {
        guard let repository, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Create New Branch"
        alert.informativeText = "The branch starts from the current commit and is checked out."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "feature/name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            MainActor.assumeIsolated {
                self.perform("Creating \(name)…") {
                    try await repository.createBranch(name)
                    self.editorArea.setStatus("Created and checked out \(name)")
                }
            }
        }
    }

    // MARK: - Remote

    /// ⌘T, IntelliJ's "Update Project".
    func pull() {
        guard let repository, editorArea.saveAll() else { return }
        perform("Updating project…") {
            let output = try await repository.pull()
            self.didChangeWorkingTree()
            let summary = output.split(separator: "\n").last.map(String.init) ?? "Updated"
            self.editorArea.setStatus("Update: \(summary.trimmingCharacters(in: .whitespaces))")
        }
    }

    func push() {
        perform("Pushing…") { try await self.pushAfterConfirmation() }
    }

    func fetch() {
        guard let repository else { return }
        perform("Fetching…") {
            try await repository.fetch()
            self.editorArea.setStatus("Fetched")
        }
    }

    /// Lists the outgoing commits and pushes after the user confirms, as IntelliJ's push dialog.
    private func pushAfterConfirmation() async throws {
        guard let repository, let window else { return }
        let commits = try await repository.outgoingCommits()
        let status = repository.status
        if commits.isEmpty && status.upstream != nil {
            editorArea.setStatus("Nothing to push: \(status.branch ?? "HEAD") is up to date with \(status.upstream ?? "")")
            return
        }
        let target = status.upstream ?? "a new remote branch \(status.branch ?? "")"
        let alert = NSAlert()
        alert.messageText = "Push \(commits.count) commit\(commits.count == 1 ? "" : "s") to \(target)?"
        alert.informativeText = commits.prefix(15).map { "\($0.shortHash)  \($0.subject)" }.joined(separator: "\n")
            + (commits.count > 15 ? "\n…" : "")
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
        editorArea.setStatus("Pushing…")
        _ = try await repository.push()
        editorArea.setStatus("Pushed \(commits.count) commit\(commits.count == 1 ? "" : "s") to \(repository.status.upstream ?? target)")
    }

    // MARK: - Log

    func toggleLog() {
        if editorArea.isShowingInBottomPanel(logView.view) {
            editorArea.hideBottomPanel()
        } else {
            editorArea.showBottomPanel(logView.view)
            reloadLog()
        }
    }

    private func configureLogView() {
        logView.onClose = { [weak self] in self?.editorArea.hideBottomPanel() }
        logView.onRefresh = { [weak self] in self?.reloadLog() }
        logView.onSelectCommit = { [weak self] commit in
            guard let repository = self?.repository else { return }
            Task {
                do {
                    let files = try await repository.files(in: commit)
                    self?.logView.show(files: files, for: commit)
                } catch {
                    Self.logger.error("git diff-tree failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        logView.onShowDiff = { [weak self] change, commit in self?.showDiff(for: change, in: commit) }
    }

    private func reloadLog() {
        guard let repository else {
            logView.show(commits: [], branch: nil)
            return
        }
        Task {
            do {
                logView.show(commits: try await repository.log(), branch: repository.status.branch)
            } catch {
                show(error)
            }
        }
    }

    // MARK: - Repository

    func createRepository() {
        guard repository == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Create Git repository in \(rootURL.lastPathComponent)?"
        alert.informativeText = "Runs git init in \(rootURL.path)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.perform("Creating repository…") {
                    self.attach(try await GitRepository.initialize(at: self.rootURL))
                    self.editorArea.setStatus("Created Git repository")
                }
            }
        }
    }

    /// After checkout or pull: files on disk changed under the editors and the tree.
    private func didChangeWorkingTree() {
        editorArea.reloadEditorsFromDisk()
        editorArea.refreshGitBases()
        fileTree.refreshFromDisk()
    }

    /// Runs one Git operation at a time, with progress in the status bar and errors in a sheet.
    private func perform(_ progress: String, _ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return NSSound.beep() }
        isBusy = true
        commitView.setBusy(true)
        editorArea.setStatus(progress)
        Task {
            defer {
                isBusy = false
                commitView.setBusy(false)
            }
            do {
                try await operation()
            } catch {
                editorArea.setStatus("")
                show(error)
            }
        }
    }

    private func show(_ error: Error) {
        Self.logger.error("Git operation failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git operation failed"
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The shortcut is only displayed; the main menu's Git items handle the keys.
    private static func item(_ title: String, shortcut: (String, NSEvent.ModifierFlags)? = nil,
                             action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let (key, modifiers) = shortcut {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }
}

/// A menu item that runs a closure, for menus built on the fly.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
