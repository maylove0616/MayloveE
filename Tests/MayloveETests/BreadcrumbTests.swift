import Foundation
import Testing
@testable import MayloveE

@MainActor
struct BreadcrumbTests {
    private static let source = """
    package com.example;

    public class Outer {
        private int field;

        public Outer() {
            int inConstructor = 0;
        }

        interface Listener {
            void changed(String value);
        }

        void run() {
            int marker = 1;
        }
    }
    """

    private func crumbs(at token: String) -> [String] {
        let caret = (Self.source as NSString).range(of: token).location
        return BreadcrumbResolver.resolve(text: Self.source, caret: caret).map(\.title)
    }

    @Test func methodInsideClass() {
        #expect(crumbs(at: "marker") == ["Outer", "run()"])
    }

    @Test func nestedInterfaceMethod() {
        #expect(crumbs(at: "String value") == ["Outer", "Listener", "changed()"])
    }

    @Test func constructor() {
        #expect(crumbs(at: "inConstructor") == ["Outer", "Outer()"])
    }

    @Test func fieldIsOnlyInsideItsClass() {
        #expect(crumbs(at: "field") == ["Outer"])
    }

    @Test func outsideAnyClass() {
        #expect(crumbs(at: "package").isEmpty)
    }

    @Test func nameRangePointsAtDeclarationName() {
        let caret = (Self.source as NSString).range(of: "marker").location
        let method = BreadcrumbResolver.resolve(text: Self.source, caret: caret).last
        #expect(method.map { (Self.source as NSString).substring(with: $0.nameRange) } == "run")
    }
}
