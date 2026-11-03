import AppKit
import Testing
@testable import MayloveE

@MainActor
struct CommandClickTests {
    /// A ⌘-click dispatched through the window reaches the text view and reports the clicked character.
    @Test func commandClickReportsCharacterUnderPointer() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CommandClick.java")
        try "public class Probe {\n    String name = \"x\";\n}\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let area = EditorAreaViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = area
        window.setContentSize(NSSize(width: 800, height: 600))
        area.open(file)
        window.layoutIfNeeded()
        // Mouse events are only delivered to windows that are on screen.
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let textView = try #require(findTextView(in: window.contentView!))
        var clicked: Int?
        textView.onCommandClick = { clicked = $0 }

        let target = (textView.string as NSString).range(of: "String").location + 2
        let rect = textView.rect(forCharacterAt: target)
        let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        #expect(clicked == target)
    }

    private func findTextView(in view: NSView) -> CodeTextView? {
        if let textView = view as? CodeTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}
