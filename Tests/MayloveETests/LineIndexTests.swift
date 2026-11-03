import Testing
@testable import MayloveE

struct LineIndexTests {
    @Test func emptyTextHasOneLine() {
        let index = LineIndex("")
        #expect(index.lineCount == 1)
        #expect(index.line(containing: 0) == 0)
    }

    @Test func trailingNewlineStartsAnEmptyLine() {
        let index = LineIndex("a\nbc\n")
        #expect(index.lineStarts == [0, 2, 5])
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 1) == 0)
        #expect(index.line(containing: 2) == 1)
        #expect(index.line(containing: 4) == 1)
        #expect(index.line(containing: 5) == 2)
    }

    @Test func offsetsAreUTF16() {
        // "😀" is two UTF-16 code units.
        let index = LineIndex("😀\nx")
        #expect(index.lineStarts == [0, 3])
    }
}
