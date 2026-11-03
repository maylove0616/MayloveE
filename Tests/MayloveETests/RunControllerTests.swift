import AppKit
import Foundation
import Testing
@testable import MayloveE

/// Runs real programs and Maven test runs; skipped without jdtls.
@MainActor
@Suite(.enabled(if: (try? JavaToolchain.locate()) != nil, "jdtls toolchain not installed"),
       .timeLimit(.minutes(5)))
struct RunControllerTests {
    private static let app = """
    package demo;

    public class App {
        public static void main(String[] args) {
            System.out.println("Hello, 你好");
            fail();
        }

        private static void fail() {
            throw new IllegalStateException("boom");
        }
    }
    """

    private static let calculatorTest = """
    package demo;

    import static org.junit.Assert.assertEquals;

    import org.junit.Test;

    public class CalculatorTest {
        @Test
        public void adds() {
            assertEquals(4, 2 + 2);
        }

        @Test
        public void broken() {
            assertEquals(5, 2 + 2);
        }
    }
    """

    private func makeController(project: URL, server: JavaLanguageServer) -> RunController {
        _ = NSApplication.shared
        let controller = RunController(rootURL: project) { server }
        controller.console.loadViewIfNeeded()
        return controller
    }

    private func waitForExit(_ controller: RunController, timeout: Duration = .seconds(120)) async throws {
        try await TestJavaProject.waitUntil(timeout: timeout) {
            controller.console.text.contains("Process finished with exit code")
        }
    }

    @Test func runsMainWithProjectJDKAndShowsStackTrace() async throws {
        let project = try TestJavaProject.make(files: ["src/main/java/demo/App.java": Self.app])
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("src/main/java/demo/App.java")
        let server = JavaLanguageServer(rootURL: project)
        server.start()
        defer { server.terminate() }

        let controller = makeController(project: project, server: server)
        controller.run(.mainClass("demo.App"), from: file)
        try await waitForExit(controller)

        let output = controller.console.text
        #expect(output.contains("Hello, 你好"))
        #expect(output.contains("java.lang.IllegalStateException: boom"))
        #expect(output.contains("at demo.App.fail(App.java:10)"))
        #expect(output.contains("Process finished with exit code 1"))
        // Launched with the JDK jdtls picked for the Java 8 project, not the JDK running jdtls.
        let jdk = try #require(try await server.projectJDK(for: file))
        #expect(output.contains(jdk.appendingPathComponent("bin/java").path))
    }

    @Test func refusesToRunWhenBuildFails() async throws {
        let broken = Self.app.replacingOccurrences(of: "fail();", with: "undefinedCall();")
        let project = try TestJavaProject.make(files: ["src/main/java/demo/App.java": broken])
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("src/main/java/demo/App.java")
        let server = JavaLanguageServer(rootURL: project)
        server.start()
        defer { server.terminate() }

        let controller = makeController(project: project, server: server)
        controller.run(.mainClass("demo.App"), from: file)
        try await TestJavaProject.waitUntil { controller.console.text.contains("Build failed") }

        let output = controller.console.text
        #expect(output.contains("[ERROR] \(file.path):[6,9]"))
        #expect(!output.contains("Hello"))
        #expect(!controller.isRunning)
    }

    @Test func runsSingleTestMethodWithMaven() async throws {
        let project = try TestJavaProject.make(files: ["src/test/java/demo/CalculatorTest.java": Self.calculatorTest])
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("src/test/java/demo/CalculatorTest.java")
        let server = JavaLanguageServer(rootURL: project)
        defer { server.terminate() }

        let controller = makeController(project: project, server: server)
        controller.run(.testMethod("demo.CalculatorTest", method: "adds"), from: file)
        try await waitForExit(controller)
        #expect(TestSummary.last(in: controller.console.text) == TestSummary(run: 1, failures: 0, errors: 0, skipped: 0))
        #expect(controller.console.text.contains("Process finished with exit code 0"))

        controller.run(.testClass("demo.CalculatorTest"), from: file)
        try await waitForExit(controller)
        #expect(TestSummary.last(in: controller.console.text) == TestSummary(run: 2, failures: 1, errors: 0, skipped: 0))
        #expect(controller.console.text.contains("CalculatorTest.java:"))
    }
}

struct TestSummaryTests {
    @Test func picksTotalsLineNotPerClassLine() {
        let output = """
        [INFO] Tests run: 2, Failures: 1, Errors: 0, Skipped: 0, Time elapsed: 0.01 s <<< FAILURE! -- in demo.CalculatorTest
        [ERROR] Tests run: 2, Failures: 1, Errors: 0, Skipped: 0
        """
        let summary = TestSummary.last(in: output)
        #expect(summary == TestSummary(run: 2, failures: 1, errors: 0, skipped: 0))
        #expect(summary?.description == "1 of 2 failed")
    }

    @Test func surefireSelectorUsesSimpleName() {
        #expect(RunController.surefireSelector(for: .testMethod("a.b.FooTest", method: "bar")) == "FooTest#bar")
        #expect(RunController.surefireSelector(for: .testClass("a.b.FooTest")) == "FooTest")
    }
}
