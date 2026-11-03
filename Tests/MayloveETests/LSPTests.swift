import AppKit
import Testing
@testable import MayloveE

struct MessageFramerTests {
    @Test func reassemblesMessagesSplitAcrossReads() {
        let first = Data(#"{"id":1}"#.utf8)
        let second = Data(#"{"id":2,"text":"中文"}"#.utf8)
        let stream = MessageFramer.frame(first) + MessageFramer.frame(second)

        var framer = MessageFramer()
        var bodies: [Data] = []
        // Feed one byte at a time to exercise every split point, including inside multi-byte UTF-8.
        for byte in stream {
            bodies += framer.append(Data([byte]))
        }
        #expect(bodies == [first, second])
    }

    @Test func skipsNonLSPOutput() {
        var framer = MessageFramer()
        let body = Data(#"{"ok":true}"#.utf8)
        let bodies = framer.append(Data("An error has occurred\r\n\r\n".utf8) + MessageFramer.frame(body))
        #expect(bodies == [body])
    }
}

struct LSPTypesTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func parsesJdtlsCompletionItem() throws {
        // Shape taken from a real jdtls 1.63 response.
        let list = try json("""
        {"isIncomplete":false,"items":[{"label":"complete(long id) : Task","kind":2,
         "detail":"TaskService.complete(long id) : Task","sortText":"999999035","filterText":"complete",
         "insertText":"complete","textEdit":{"range":{"start":{"line":22,"character":16},
         "end":{"line":22,"character":24}},"newText":"complete"},"data":{"pid":"0","rid":"0"}}]}
        """)
        let item = try #require(LSPCompletionItem.list(from: list).first)
        #expect(item.label == "complete(long id) : Task")
        #expect(item.filterText == "complete")
        #expect(item.insertText == "complete")
        #expect(item.textEdit?.range.start == LSPPosition(line: 22, character: 16))
        #expect(item.raw["data"] != nil)
    }

    @Test func parsesLocationsAndLocationLinks() throws {
        let single = try json(#"{"uri":"file:///a/B.java","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}"#)
        #expect(LSPLocation.list(from: single).first?.url.path == "/a/B.java")

        let links = try json(#"[{"targetUri":"file:///a/C.java","targetRange":{"start":{"line":0,"character":0},"end":{"line":9,"character":1}},"targetSelectionRange":{"start":{"line":3,"character":4},"end":{"line":3,"character":8}}}]"#)
        let link = try #require(LSPLocation.list(from: links).first)
        #expect(link.range.start == LSPPosition(line: 3, character: 4))

        #expect(LSPLocation.list(from: .null).isEmpty)
    }

    @Test func parsesHoverParts() throws {
        let marked = try json(#"{"contents":[{"language":"java","value":"Task complete(long id)"},"Marks the task done.",""]}"#)
        #expect(LSPHover.parts(from: marked) == [.code("Task complete(long id)"), .markdown("Marks the task done.")])

        let markup = try json(#"{"contents":{"kind":"markdown","value":"**doc**"}}"#)
        #expect(LSPHover.parts(from: markup) == [.markdown("**doc**")])
    }
}

struct HoverRendererTests {
    /// Javadoc for java.lang.System exactly as jdtls 1.63 returns it.
    private static let systemDoc = """
    The `System` class contains several useful class fields and methods. It cannot be instantiated.

    Among the facilities provided by the `System` class
    are standard input, standard output, and error output streams;
    access to externally defined properties.

    * **Since:**
      * JDK1.0
    * **See Also:**
      * [Runtime](jdt://contents/rt.jar/java.lang/Runtime.class)
    """

    @Test func reflowsJavadocMarkdown() {
        let normalized = HoverRenderer.normalizeMarkdown(Self.systemDoc + "\n\nSource: *Java 1.8.0*")
        #expect(normalized == """
        The `System` class contains several useful class fields and methods. It cannot be instantiated.

        Among the facilities provided by the `System` class are standard input, standard output, \
        and error output streams; access to externally defined properties.

        • **Since:**
            • JDK1.0
        • **See Also:**
            • Runtime
        """)
    }

    @Test func rendersWithoutMarkdownSyntax() {
        let rendered = HoverRenderer.render([.code("java.lang.System"), .markdown(Self.systemDoc)])
        let text = rendered.string
        #expect(text.hasPrefix("java.lang.System\n\nThe System class"))
        #expect(!text.contains("`") && !text.contains("**") && !text.contains("]("))

        let codeSpan = (text as NSString).range(of: "System class").location
        let font = rendered.attribute(.font, at: codeSpan, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
        let bold = (text as NSString).range(of: "Since:").location
        let boldFont = rendered.attribute(.font, at: bold, effectiveRange: nil) as? NSFont
        #expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }
}

struct LineIndexPositionTests {
    @Test func convertsBetweenOffsetsAndPositions() {
        let index = LineIndex("ab\ncde\n")
        #expect(index.position(of: 4) == LSPPosition(line: 1, character: 1))
        #expect(index.offset(of: LSPPosition(line: 1, character: 1)) == 4)
    }

    @Test func clampsOutOfRangePositions() {
        let index = LineIndex("ab\ncde")
        #expect(index.offset(of: LSPPosition(line: 0, character: 99)) == 2)
        #expect(index.offset(of: LSPPosition(line: 9, character: 0)) == 6)
    }
}

@MainActor
struct CodeTextViewEditTests {
    @Test func appliesEditsAndKeepsCaretAfterInsertion() {
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        textView.string = "package a;\n\nclass A { Lis }"
        let caret = (textView.string as NSString).range(of: "Lis").upperBound
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        // Complete "Lis" → "List" and add an import above, as jdtls does.
        textView.apply([
            (NSRange(location: caret - 3, length: 3), "List"),
            (NSRange(location: 11, length: 0), "import java.util.List;\n"),
        ])

        #expect(textView.string == "package a;\nimport java.util.List;\n\nclass A { List }")
        let expectedCaret = (textView.string as NSString).range(of: "List }").location + 4
        #expect(textView.selectedRange().location == expectedCaret)
    }

    @Test func wordStartStopsAtNonIdentifier() {
        let text = "foo.barBaz" as NSString
        #expect(CompletionController.wordStart(in: text, before: text.length) == 4)
        #expect(CompletionController.wordStart(in: text, before: 4) == 4)
    }
}
