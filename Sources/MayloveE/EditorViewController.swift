import AppKit
import os

/// One open file: text view, line-number gutter, syntax highlighting and language features.
@MainActor
final class EditorViewController: NSViewController, NSTextViewDelegate {
    private static let logger = Logger(subsystem: "MayloveE", category: "Editor")

    let url: URL
    var onDirtyChange: (() -> Void)?
    /// Asks the editor area to open a location, possibly in another file.
    var onNavigate: ((LSPLocation) -> Void)?
    /// Called at most once per run loop pass after the caret moved or the text changed.
    var onCaretChange: (() -> Void)?

    private(set) var isDirty = false {
        didSet {
            if isDirty != oldValue { onDirtyChange?() }
        }
    }

    private let initialContents: String
    private let isEditable: Bool
    /// Java source we could read, so highlighting and the language server apply.
    private let isJavaSource: Bool
    private let languageServer: JavaLanguageServer?
    private let textView = CodeTextView(usingTextLayoutManager: false)
    private var gutter: LineNumberGutter?
    private var highlighter: SyntaxHighlighter?
    private var lineIndex: LineIndex

    /// Document version sent to the language server; bumped on every edit.
    private(set) var version = 1
    private var isSyncPending = false
    private var diagnostics: [LSPDiagnostic] = []
    private var completion: CompletionController?
    private var hover: HoverController?
    private let locationChooser = ListPopup()
    private var chooserLocations: [LSPLocation] = []

    /// The file's committed contents; nil when untracked or not in a Git repository.
    var gitBase: String? {
        didSet {
            if gitBase != oldValue { scheduleGitMarkers() }
        }
    }
    private var isGitMarkersPending = false
    private var isCaretChangePending = false

    /// Opens a file from disk for editing.
    convenience init(url: URL, languageServer: JavaLanguageServer?) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            self.init(url: url, contents: contents, isEditable: true, languageServer: languageServer)
        } catch {
            self.init(url: url,
                      contents: "Cannot display \(url.lastPathComponent) as UTF-8 text:\n\(error.localizedDescription)",
                      isEditable: false, languageServer: nil)
        }
    }

    /// Opens given contents; read-only editors are used for JDK and library sources (jdt:// URLs).
    init(url: URL, contents: String, isEditable: Bool, languageServer: JavaLanguageServer?) {
        self.url = url
        self.initialContents = contents
        self.isEditable = isEditable
        self.isJavaSource = languageServer != nil && ["java", "class"].contains(url.pathExtension)
        self.languageServer = isJavaSource ? languageServer : nil
        lineIndex = LineIndex(contents)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        configureTextView()
        scrollView.documentView = textView

        let gutter = LineNumberGutter(textView: textView)
        gutter.lineIndex = lineIndex
        if let gitBase {
            gutter.changes = LineDiff.hunks(old: gitBase, new: initialContents)
        }
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.gutter = gutter

        view = scrollView

        if isJavaSource || (isEditable && url.pathExtension == "java") {
            highlighter = SyntaxHighlighter(textView: textView)
        }
        if let languageServer {
            configureLanguageFeatures(languageServer)
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismissPopups),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(codeFontDidChange),
                                               name: CodeFont.didChange, object: nil)
    }

    @objc private func codeFontDidChange() {
        dismissPopups()
        textView.font = CodeFont.font()
        highlighter?.refresh()
    }

    private func configureTextView() {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = CodeFont.font()
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Code should not soft-wrap.
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = unlimited
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = unlimited
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.string = initialContents
        textView.isEditable = isEditable
        textView.delegate = self
    }

    private func configureLanguageFeatures(_ server: JavaLanguageServer) {
        let url = self.url
        server.didOpen(url, text: initialContents, version: version)

        if isEditable {
            completion = CompletionController(textView: textView, dependencies: .init(
                complete: { [unowned self] position in
                    self.syncIfNeeded()
                    return try await server.completion(url, at: position)
                },
                resolve: { item in try await server.resolve(item) },
                lineIndex: { [unowned self] in self.lineIndex },
                documentVersion: { [unowned self] in self.version }
            ))
        }
        hover = HoverController(textView: textView) { [unowned self] index in
            await self.hoverText(at: index)
        }
        locationChooser.onAccept = { [unowned self] index in
            self.onNavigate?(self.chooserLocations[index])
        }

        textView.keyDownInterceptor = { [unowned self] event in
            self.hover?.close()
            return self.completion?.handleKey(event) == true || self.locationChooser.handleKey(event)
        }
        textView.onTyped = { [unowned self] text in self.completion?.didType(text) }
        textView.onCompletionRequested = { [unowned self] in self.completion?.trigger() }
        textView.onCommandClick = { [unowned self] index in
            self.hover?.close()
            self.goToDefinition(at: index)
        }
        textView.onHover = { [unowned self] index in self.hover?.mouseMoved(to: index) }

        setDiagnostics(server.diagnostics(for: url))
    }

    /// Called by the editor area after this editor's view is placed on screen.
    func didBecomeVisible() {
        view.superview?.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(textView)
        highlighter?.refresh()
    }

    /// Called by the editor area before this editor's view leaves the screen (tab switch or close),
    /// so no pending hover or popup tries to attach to a view outside any window.
    func willBecomeHidden() {
        dismissPopups()
    }

    /// Called by the editor area when the tab closes.
    func close() {
        willBecomeHidden()
        languageServer?.didClose(url)
    }

    func save() throws {
        guard isEditable, isDirty else { return }

        // Write to a temporary file and swap it in, which keeps the original's
        // permissions (e.g. the executable bit on mvnw) and avoids half-written files.
        let fileManager = FileManager.default
        let directory = try fileManager.url(for: .itemReplacementDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: url,
                                            create: true)
        defer { try? fileManager.removeItem(at: directory) }
        let temporaryURL = directory.appendingPathComponent(url.lastPathComponent)
        try Data(textView.string.utf8).write(to: temporaryURL)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)

        textView.breakUndoCoalescing()
        isDirty = false
        syncIfNeeded()
        languageServer?.didSave(url)
    }

    /// The current text, including unsaved changes.
    var text: String { textView.string }

    /// Picks up the file's new contents after it changed on disk (e.g. a branch switch).
    /// Unsaved changes are kept unless discarded (Git rollback); returns whether the text was replaced.
    @discardableResult
    func reloadFromDisk(discardingChanges: Bool = false) -> Bool {
        guard isViewLoaded, isEditable, !isDirty || discardingChanges, url.isFileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              contents != textView.string,
              let storage = textView.textStorage else { return false }

        let selection = textView.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: contents)
        // The undo stack refers to the old text.
        textView.undoManager?.removeAllActions(withTarget: textView)
        let length = (contents as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        lineIndex = LineIndex(contents)
        gutter?.lineIndex = lineIndex
        highlighter?.textDidChange()
        version += 1
        scheduleSync()
        scheduleGitMarkers()
        isDirty = false
        return true
    }

    /// Recomputes the gutter's change bars once per run loop pass, not per keystroke.
    private func scheduleGitMarkers() {
        guard !isGitMarkersPending else { return }
        isGitMarkersPending = true
        Task { [weak self] in
            guard let self else { return }
            self.isGitMarkersPending = false
            self.gutter?.changes = self.gitBase.map { LineDiff.hunks(old: $0, new: self.textView.string) } ?? []
        }
    }

    // MARK: - Language features

    func triggerCompletion() {
        completion?.trigger()
    }

    func goToDefinition() {
        goToDefinition(at: caretIndexForLookup())
    }

    func findReferences() {
        guard let languageServer else { return }
        let index = caretIndexForLookup()
        syncIfNeeded()
        let position = lineIndex.position(of: index)
        Task {
            do {
                let locations = try await languageServer.references(url, at: position)
                navigate(to: locations, from: index, emptyMessage: "No usages found")
            } catch {
                Self.logger.error("Find usages failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// One-based line and column of the caret, and the number of selected characters.
    var caretLocation: (line: Int, column: Int, selectedLength: Int) {
        let selection = textView.selectedRange()
        let position = lineIndex.position(of: selection.location)
        return (position.line + 1, position.character + 1, selection.length)
    }

    /// "CRLF" when the file uses Windows line endings, otherwise "LF".
    var lineSeparatorName: String {
        textView.string.contains("\r\n") ? "CRLF" : "LF"
    }

    /// Declarations enclosing the caret, outermost first; empty for non-Java files.
    func breadcrumbs() -> [Breadcrumb] {
        guard highlighter != nil else { return [] }
        return BreadcrumbResolver.resolve(text: textView.string, caret: textView.selectedRange().location)
    }

    /// Moves the caret to a range in this file, e.g. from a breadcrumb.
    func reveal(_ range: NSRange) {
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(textView)
    }

    private func scheduleCaretChange() {
        guard !isCaretChangePending else { return }
        isCaretChangePending = true
        Task { [weak self] in
            guard let self else { return }
            self.isCaretChangePending = false
            self.onCaretChange?()
        }
    }

    /// What Run should execute for the caret position, if anything; only for project sources.
    func runTarget() -> RunTarget? {
        guard isJavaSource, isEditable else { return nil }
        return RunTargetResolver.resolve(text: textView.string, caret: textView.selectedRange().location)
    }

    func showQuickDocumentation() {
        hover?.showNow(at: caretIndexForLookup())
    }

    func setDiagnostics(_ items: [LSPDiagnostic]) {
        diagnostics = items
        guard isViewLoaded, let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length else { return }

        let whole = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
        for diagnostic in items where diagnostic.severity == .error || diagnostic.severity == .warning {
            guard let range = underlineRange(for: diagnostic, length: length) else { continue }
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemOrange,
            ], forCharacterRange: range)
        }
    }

    /// Selects and scrolls to a range, e.g. after navigating to a declaration.
    func reveal(_ range: LSPRange) {
        let target = lineIndex.range(of: range)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
    }

    private func goToDefinition(at index: Int) {
        guard let languageServer else { return }
        syncIfNeeded()
        let position = lineIndex.position(of: index)
        Task {
            do {
                let locations = try await languageServer.definition(url, at: position)
                navigate(to: locations, from: index, emptyMessage: "Cannot find declaration to go to")
            } catch {
                Self.logger.error("Go to declaration failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private func navigate(to locations: [LSPLocation], from index: Int, emptyMessage: String) {
        switch locations.count {
        case 0: hover?.show(emptyMessage, at: index)
        case 1: onNavigate?(locations[0])
        default: showLocationChooser(locations, at: index)
        }
    }

    private func showLocationChooser(_ locations: [LSPLocation], at index: Int) {
        guard let window = view.window else { return }
        var sources: [URL: String] = [url: textView.string]
        let rows = locations.map { location -> ListPopupRow in
            let fromDisk = location.url.isFileURL ? try? String(contentsOf: location.url, encoding: .utf8) : nil
            let text = sources[location.url] ?? fromDisk ?? ""
            sources[location.url] = text
            let lines = text.components(separatedBy: "\n")
            let line = location.range.start.line < lines.count ? lines[location.range.start.line] : ""
            return ListPopupRow(title: "\(location.url.lastPathComponent):\(location.range.start.line + 1)",
                                detail: line.trimmingCharacters(in: .whitespaces))
        }
        chooserLocations = locations
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
        locationChooser.show(rows: rows, anchor: anchor, in: window)
    }

    private func hoverText(at index: Int) async -> [HoverPart] {
        let messages = diagnostics
            .filter { NSLocationInRange(index, lineIndex.range(of: $0.range)) }
            .map(\.message)
        if !messages.isEmpty {
            return [.plain(messages.joined(separator: "\n"))]
        }
        guard let languageServer else { return [] }
        syncIfNeeded()
        do {
            return try await languageServer.hover(url, at: lineIndex.position(of: index))
        } catch {
            Self.logger.error("Hover failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The caret, nudged back one character when it sits just after a word.
    private func caretIndexForLookup() -> Int {
        let caret = textView.selectedRange().location
        let text = textView.string as NSString
        let atWord = caret < text.length && UnicodeScalar(text.character(at: caret))
            .map(CompletionController.isIdentifier) == true
        return atWord || caret == 0 ? caret : caret - 1
    }

    private func underlineRange(for diagnostic: LSPDiagnostic, length: Int) -> NSRange? {
        guard length > 0 else { return nil }
        var range = lineIndex.range(of: diagnostic.range)
        if range.length == 0 {
            // Zero-width diagnostics (e.g. "missing ;") still need something visible.
            range = NSRange(location: min(range.location, length - 1), length: 1)
        }
        return range
    }

    @objc private func dismissPopups() {
        completion?.dismiss()
        locationChooser.hide()
        hover?.close()
    }

    // MARK: - Document sync

    /// Sends the latest text before any request, so the server never answers for stale content.
    private func syncIfNeeded() {
        guard isSyncPending, let languageServer else { return }
        isSyncPending = false
        languageServer.didChange(url, text: textView.string, version: version)
    }

    private func scheduleSync() {
        guard languageServer != nil, !isSyncPending else { return }
        isSyncPending = true
        Task { [weak self] in self?.syncIfNeeded() }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        lineIndex = LineIndex(textView.string)
        gutter?.lineIndex = lineIndex
        highlighter?.textDidChange()
        version += 1
        scheduleSync()
        scheduleGitMarkers()
        scheduleCaretChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        completion?.selectionDidChange()
        gutter?.needsDisplay = true
        scheduleCaretChange()
    }
}
