import Foundation
import Testing
@testable import MayloveE

@MainActor
struct JavaSyntaxTests {
    @Test func highlightsCommonTokens() throws {
        let syntax = try #require(JavaSyntax.shared)
        let text = """
        @Override
        public class Foo {
            String name = "hi"; // note
            int count = 42;
        }
        """
        let tree = try #require(syntax.parse(text))
        let nsText = text as NSString
        let highlights = syntax.highlights(in: tree, text: text, range: NSRange(location: 0, length: nsText.length))

        func names(of token: String) -> [String] {
            let range = nsText.range(of: token)
            return highlights.filter { $0.range == range }.map(\.name)
        }

        #expect(names(of: "class").contains("keyword"))
        #expect(names(of: "String").contains("type"))
        #expect(names(of: "\"hi\"").contains("string"))
        #expect(names(of: "// note").contains("comment"))
        #expect(names(of: "42").contains("number"))
        #expect(names(of: "Override").contains("attribute"))
    }

    @Test func themeFallsBackToParentCapture() {
        #expect(SyntaxTheme.color(for: ["function", "method"]) == SyntaxTheme.color(for: ["function"]))
        #expect(SyntaxTheme.color(for: ["variable"]) == nil)
    }
}
