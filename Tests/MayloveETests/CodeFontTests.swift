import AppKit
import Testing
@testable import MayloveE

@MainActor
@Suite(.serialized)
struct CodeFontTests {
    @Test func adjustsClampsAndUpdatesOpenEditors() throws {
        _ = NSApplication.shared
        CodeFont.reset()
        defer { CodeFont.reset() }
        #expect(CodeFont.size == CodeFont.defaultSize)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FontProbe-\(UUID()).txt")
        try "text\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = EditorViewController(url: file, languageServer: nil)
        let scrollView = try #require(editor.view as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let gutter = try #require(scrollView.verticalRulerView)
        #expect(textView.font?.pointSize == CodeFont.defaultSize)
        let thickness = gutter.ruleThickness

        CodeFont.increase()
        #expect(CodeFont.size == CodeFont.defaultSize + 1)
        #expect(textView.font?.pointSize == CodeFont.defaultSize + 1)
        #expect(gutter.ruleThickness > thickness)

        CodeFont.decrease()
        CodeFont.decrease()
        #expect(textView.font?.pointSize == CodeFont.defaultSize - 1)

        // One step past the maximum (that step only beeps).
        for _ in 0...Int(CodeFont.sizeRange.upperBound - CodeFont.size) { CodeFont.increase() }
        #expect(CodeFont.size == CodeFont.sizeRange.upperBound)

        CodeFont.reset()
        #expect(textView.font?.pointSize == CodeFont.defaultSize)
    }
}
