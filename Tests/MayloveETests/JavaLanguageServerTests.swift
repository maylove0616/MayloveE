import AppKit
import Foundation
import Testing
@testable import MayloveE

/// End-to-end tests against a real jdtls; skipped when no suitable JDK/jdtls is installed.
@MainActor
@Suite(.enabled(if: (try? JavaToolchain.locate()) != nil, "jdtls toolchain not installed"),
       .timeLimit(.minutes(3)))
struct JavaLanguageServerTests {
    private static let appSource = """
    package demo;

    public class App {
        public static void main(String[] args) {
            Greeter greeter = new Greeter();
            System.out.println(greeter.greet("world"));
            undefinedCall();
        }
    }
    """

    @Test func diagnosticsCompletionNavigationAndHover() async throws {
        let project = try TestJavaProject.make(appSource: Self.appSource)
        defer { try? FileManager.default.removeItem(at: project) }
        let greeter = project.appendingPathComponent("src/main/java/demo/Greeter.java")
        let app = project.appendingPathComponent("src/main/java/demo/App.java")

        let server = JavaLanguageServer(rootURL: project)
        var received: [URL: [LSPDiagnostic]] = [:]
        server.onDiagnostics = { url, items in received[url.standardizedFileURL] = items }
        server.start()
        defer { server.terminate() }

        server.didOpen(app, text: Self.appSource, version: 1)
        try await TestJavaProject.waitUntil { server.status == .ready }

        // App.java calls an undefined method, which must produce an error.
        try await TestJavaProject.waitUntil { received[app.standardizedFileURL]?.isEmpty == false }
        let errors = try #require(received[app.standardizedFileURL])
        #expect(errors.contains { $0.severity == .error && $0.message.contains("undefinedCall") })

        let index = LineIndex(Self.appSource)
        let dot = (Self.appSource as NSString).range(of: "greeter.").upperBound
        let completions = try await server.completion(app, at: index.position(of: dot))
        #expect(completions.contains { $0.filterText == "greet" })

        let greetCall = (Self.appSource as NSString).range(of: "greet(").location
        let definitions = try await server.definition(app, at: index.position(of: greetCall + 1))
        #expect(definitions.first?.url.standardizedFileURL == greeter.standardizedFileURL)

        let greeterText = try String(contentsOf: greeter, encoding: .utf8)
        let greetDeclaration = (greeterText as NSString).range(of: "greet(").location
        let references = try await server.references(greeter,
                                                     at: LineIndex(greeterText).position(of: greetDeclaration + 1))
        #expect(references.contains { $0.url.standardizedFileURL == app.standardizedFileURL })

        let hover = try await server.hover(app, at: index.position(of: greetCall + 1))
        #expect(hover.contains { if case .code(let code) = $0 { return code.contains("greet") } else { return false } })
    }

    /// Go to Declaration on a JDK class opens its source read-only, positioned on the symbol.
    @Test func navigatesIntoJdkSource() async throws {
        _ = NSApplication.shared
        let source = """
        package demo;

        import java.time.LocalDate;

        public class App {
            public static void main(String[] args) {
                LocalDate today = LocalDate.now();
            }
        }
        """
        let project = try TestJavaProject.make(appSource: source)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = project.appendingPathComponent("src/main/java/demo/App.java")

        let server = JavaLanguageServer(rootURL: project)
        defer { server.terminate() }
        let area = EditorAreaViewController()
        area.languageServerProvider = { server }
        server.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = area
        area.open(app)
        window.layoutIfNeeded()
        try await TestJavaProject.waitUntil { server.status == .ready }

        let appEditor = try #require(area.selectedEditor)
        let appTextView = try #require(findTextView(in: appEditor.view))
        let nowCall = (source as NSString).range(of: "now()").location
        appTextView.setSelectedRange(NSRange(location: nowCall + 1, length: 0))
        appEditor.goToDefinition()

        try await TestJavaProject.waitUntil { area.selectedEditor?.url.scheme == "jdt" }
        let jdkEditor = try #require(area.selectedEditor)
        let jdkTextView = try #require(findTextView(in: jdkEditor.view))
        #expect(jdkEditor.url.lastPathComponent == "LocalDate.java")
        #expect(jdkTextView.string.contains("public final class LocalDate"))
        #expect(!jdkTextView.isEditable)
        let selected = (jdkTextView.string as NSString).substring(with: jdkTextView.selectedRange())
        #expect(selected == "now")

        // Language features keep working inside the library source.
        let jdkIndex = LineIndex(jdkTextView.string)
        let ofCall = (jdkTextView.string as NSString).range(of: "return now(Clock.systemDefaultZone());").location
        let hover = try await server.hover(jdkEditor.url, at: jdkIndex.position(of: ofCall + 8))
        #expect(!hover.isEmpty)
    }

    /// Drives the real editor UI: error underline, auto-popup completion, and auto-import.
    @Test func editorShowsErrorsAndCompletesWithImport() async throws {
        _ = NSApplication.shared
        let project = try TestJavaProject.make(appSource: Self.appSource)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = project.appendingPathComponent("src/main/java/demo/App.java")

        let server = JavaLanguageServer(rootURL: project)
        defer { server.terminate() }
        let area = EditorAreaViewController()
        area.languageServerProvider = { server }
        server.onDiagnostics = { url, items in area.applyDiagnostics(items, for: url) }
        server.start()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = area
        area.open(app)
        window.layoutIfNeeded()
        let textView = try #require(findTextView(in: window.contentView!))
        let layoutManager = try #require(textView.layoutManager)

        // The undefined call gets a red underline.
        let errorRange = (textView.string as NSString).range(of: "undefinedCall")
        try await TestJavaProject.waitUntil {
            layoutManager.temporaryAttribute(.underlineColor, atCharacterIndex: errorRange.location,
                                             effectiveRange: nil) as? NSColor == .systemRed
        }

        // Type a class name that needs an import; completion should pop up by itself.
        let insertion = (textView.string as NSString).range(of: "        undefinedCall();").location
        textView.setSelectedRange(NSRange(location: insertion, length: 0))
        textView.insertText("ArrayLis", replacementRange: textView.selectedRange())
        try await TestJavaProject.waitUntil { window.childWindows?.contains { $0.isVisible } == true }

        // Accept the first suggestion with Return.
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r",
                                                      isARepeat: false, keyCode: 36))
        textView.keyDown(with: returnKey)

        try await TestJavaProject.waitUntil { textView.string.contains("import java.util.ArrayList;") }
        // Typed at the start of the line, before its indentation.
        #expect(textView.string.contains("\nArrayList        undefinedCall();"))
        #expect(textView.string.hasPrefix("package demo;\n\nimport java.util.ArrayList;\n"))
        #expect(window.childWindows?.contains { $0.isVisible } != true)
    }

    /// ⌘-click through real window event dispatch opens the declaring file.
    @Test func commandClickOpensDeclaration() async throws {
        _ = NSApplication.shared
        let project = try TestJavaProject.make(appSource: Self.appSource)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = project.appendingPathComponent("src/main/java/demo/App.java")

        let server = JavaLanguageServer(rootURL: project)
        defer { server.terminate() }
        let area = EditorAreaViewController()
        area.languageServerProvider = { server }
        server.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = area
        window.setContentSize(NSSize(width: 900, height: 700))
        area.open(app)
        window.layoutIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await TestJavaProject.waitUntil { server.status == .ready }

        let textView = try #require(findTextView(in: window.contentView!))
        let target = (textView.string as NSString).range(of: "Greeter greeter").location + 2
        let rect = textView.rect(forCharacterAt: target)
        let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func send(_ type: NSEvent.EventType) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }

        // The mouse rests on the symbol first, which starts the hover delay. The tab switch below
        // must cancel it: a popover anchored to the hidden editor raised NSInvalidArgumentException
        // inside a Task, which later crashed the app.
        textView.onHover?(target)

        // As in a real click, jdtls answers while the button is still down.
        try send(.leftMouseDown)
        try await TestJavaProject.waitUntil(timeout: .seconds(20)) {
            area.selectedEditor?.url.lastPathComponent == "Greeter.java"
        }
        try send(.leftMouseUp)

        // Moving the mouse afterwards makes AppKit re-hit-test tracking areas over the new editor.
        for step in 0..<20 {
            let moved = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: point.x + CGFloat(step * 5), y: point.y - CGFloat(step * 3)),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            window.sendEvent(moved)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(1))
        #expect(area.selectedEditor?.url.lastPathComponent == "Greeter.java")
        #expect(!NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") })
    }

    private func findTextView(in view: NSView) -> CodeTextView? {
        if let textView = view as? CodeTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}
