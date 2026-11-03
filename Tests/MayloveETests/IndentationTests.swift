import Testing
@testable import MayloveE

struct IndentationTests {
    @Test func keepsLeadingWhitespace() {
        #expect(Indentation.newline(after: "        int x = 1;") == "\n        ")
        #expect(Indentation.newline(after: "\tfoo();") == "\n\t")
    }

    @Test func indentsAfterOpeningBrace() {
        #expect(Indentation.newline(after: "    public void run() {") == "\n        ")
        #expect(Indentation.newline(after: "class A {  ") == "\n    ")
    }

    @Test func noIndentForEmptyLine() {
        #expect(Indentation.newline(after: "") == "\n")
    }
}
