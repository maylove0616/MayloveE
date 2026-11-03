import AppKit
import os

/// Drives code completion for one editor: requests items, filters them as the user types,
/// and applies the chosen item (plus any import it needs).
@MainActor
final class CompletionController {
    private static let logger = Logger(subsystem: "MayloveE", category: "Completion")
    /// Identifier characters typed before completion pops up automatically.
    private static let autoTriggerPrefixLength = 2

    struct Dependencies {
        let complete: (LSPPosition) async throws -> [LSPCompletionItem]
        let resolve: (LSPCompletionItem) async throws -> LSPCompletionItem
        let lineIndex: () -> LineIndex
        let documentVersion: () -> Int
    }

    private unowned let textView: CodeTextView
    private let dependencies: Dependencies
    private let popup = ListPopup()

    /// Non-nil while a completion session is active (request pending or items available).
    private var wordStart: Int?
    private var items: [LSPCompletionItem] = []
    private var filtered: [LSPCompletionItem] = []
    private var generation = 0

    init(textView: CodeTextView, dependencies: Dependencies) {
        self.textView = textView
        self.dependencies = dependencies
        popup.onAccept = { [weak self] index in self?.accept(index) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, wordStart != nil, !popup.isVisible {
            dismiss()
            return true
        }
        let consumed = popup.handleKey(event)
        if consumed, !popup.isVisible {
            endSession()
        }
        return consumed
    }

    /// Explicit invocation (⌃Space / ⌥Esc).
    func trigger() {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        let start = Self.wordStart(in: text, before: cursor)
        wordStart = start
        items = []
        generation += 1
        let requestGeneration = generation
        let position = dependencies.lineIndex().position(of: cursor)

        Task { [weak self, dependencies] in
            let items: [LSPCompletionItem]
            do {
                items = try await dependencies.complete(position)
            } catch {
                Self.logger.error("Completion failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let self, requestGeneration == self.generation else { return }
            self.items = items.sorted { $0.sortText < $1.sortText }
            self.refilter()
        }
    }

    /// Called after the user typed `string` at the caret.
    func didType(_ string: String) {
        if string == "." {
            trigger()
            return
        }
        if wordStart != nil {
            refilter()
            return
        }
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        if string.unicodeScalars.allSatisfy(Self.isIdentifier),
           cursor - Self.wordStart(in: text, before: cursor) >= Self.autoTriggerPrefixLength {
            trigger()
        }
    }

    /// Ends the session when the caret leaves the word being completed.
    func selectionDidChange() {
        guard wordStart != nil else { return }
        if currentPrefix() == nil { dismiss() }
    }

    func dismiss() {
        popup.hide()
        endSession()
    }

    private func endSession() {
        wordStart = nil
        items = []
        filtered = []
        generation += 1
    }

    private func refilter() {
        guard let wordStart, let prefix = currentPrefix(), let window = textView.window else {
            dismiss()
            return
        }
        // Items not yet received; keep the session open.
        guard !items.isEmpty else { return }

        let lowered = prefix.lowercased()
        let prefixMatches = items.filter { $0.filterText.lowercased().hasPrefix(lowered) }
        let substringMatches = lowered.isEmpty ? [] : items.filter {
            let filter = $0.filterText.lowercased()
            return !filter.hasPrefix(lowered) && filter.contains(lowered)
        }
        filtered = prefixMatches + substringMatches
        guard !filtered.isEmpty else {
            popup.hide()
            return
        }

        let anchor = textView.firstRect(forCharacterRange: NSRange(location: wordStart, length: 0), actualRange: nil)
        popup.show(rows: filtered.map { ListPopupRow(title: $0.label, detail: $0.detail) },
                   anchor: anchor, in: window)
    }

    /// The identifier text between the session's word start and the caret, or nil if the caret left it.
    private func currentPrefix() -> String? {
        guard let wordStart else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location >= wordStart else { return nil }
        let prefix = (textView.string as NSString)
            .substring(with: NSRange(location: wordStart, length: selection.location - wordStart))
        return prefix.unicodeScalars.allSatisfy(Self.isIdentifier) ? prefix : nil
    }

    private func accept(_ index: Int) {
        guard index < filtered.count, let wordStart else { return }
        let item = filtered[index]
        let cursor = textView.selectedRange().location
        let lineIndex = dependencies.lineIndex()
        let start = item.textEdit.map { min(lineIndex.offset(of: $0.range.start), cursor) } ?? wordStart
        endSession()

        var edits = [(NSRange(location: start, length: cursor - start), item.insertText)]
        edits += item.additionalTextEdits.map { (lineIndex.range(of: $0.range), $0.newText) }
        textView.apply(edits)

        // jdtls computes required imports lazily; add them once resolved, unless the user kept typing.
        guard item.additionalTextEdits.isEmpty, item.raw["data"] != nil else { return }
        let version = dependencies.documentVersion()
        Task { [weak self, dependencies] in
            let resolved: LSPCompletionItem
            do {
                resolved = try await dependencies.resolve(item)
            } catch {
                Self.logger.error("Resolve failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let self, !resolved.additionalTextEdits.isEmpty,
                  dependencies.documentVersion() == version else { return }
            let lineIndex = dependencies.lineIndex()
            self.textView.apply(resolved.additionalTextEdits.map { (lineIndex.range(of: $0.range), $0.newText) })
        }
    }

    static func wordStart(in text: NSString, before offset: Int) -> Int {
        var start = offset
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), isIdentifier(scalar) {
            start -= 1
        }
        return start
    }

    static func isIdentifier(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
}
