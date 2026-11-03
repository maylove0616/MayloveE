import Foundation
import Testing
@testable import MayloveE

@MainActor
struct RunTargetTests {
    private static let testSource = """
    package com.example.demo.service;

    import org.junit.Test;

    public class TaskServiceTest {
        @Before
        public void setUp() {
        }

        @Test
        public void pendingIsSorted() {
            int marker = 1;
        }

        @org.junit.jupiter.api.Test
        void jupiterStyle() {
        }
    }
    """

    private func caret(in text: String, at token: String) -> Int {
        (text as NSString).range(of: token).location
    }

    @Test func caretInTestMethodRunsThatMethod() {
        let target = RunTargetResolver.resolve(text: Self.testSource, caret: caret(in: Self.testSource, at: "marker"))
        #expect(target == .testMethod("com.example.demo.service.TaskServiceTest", method: "pendingIsSorted"))
    }

    @Test func fullyQualifiedTestAnnotationCounts() {
        let target = RunTargetResolver.resolve(text: Self.testSource, caret: caret(in: Self.testSource, at: "jupiterStyle"))
        #expect(target == .testMethod("com.example.demo.service.TaskServiceTest", method: "jupiterStyle"))
    }

    @Test func caretOutsideTestMethodRunsWholeClass() {
        for token in ["setUp", "import org", "public class"] {
            let target = RunTargetResolver.resolve(text: Self.testSource, caret: caret(in: Self.testSource, at: token))
            #expect(target == .testClass("com.example.demo.service.TaskServiceTest"), "caret at \(token)")
        }
    }

    @Test func mainClassAnywhereInFile() {
        let source = """
        package com.example.demo;

        public class App {
            private int helper() { return 1; }

            public static void main(String[] args) {
                System.out.println("hi");
            }
        }
        """
        #expect(RunTargetResolver.resolve(text: source, caret: caret(in: source, at: "helper"))
                == .mainClass("com.example.demo.App"))
    }

    @Test func defaultPackageAndNothingToRun() {
        #expect(RunTargetResolver.resolve(text: "class A { public static void main(String[] a) {} }", caret: 0)
                == .mainClass("A"))
        #expect(RunTargetResolver.resolve(text: "class B { void run() {} }", caret: 0) == nil)
    }

    @Test func titles() {
        #expect(RunTarget.mainClass("a.b.App").title == "App.main()")
        #expect(RunTarget.testMethod("a.FooTest", method: "bar").title == "FooTest.bar")
    }
}
