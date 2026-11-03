import AppKit
import Testing
@testable import MayloveE

@MainActor
struct HoverControllerTests {
    /// A hover that fires after its text view left the window must not try to show a popover
    /// (NSPopover raises for views outside a window).
    @Test func pendingHoverIsDroppedWhenViewLeavesWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.string = "String name;"
        window.contentView = textView

        let hover = HoverController(textView: textView) { _ in [.plain("doc")] }
        hover.mouseMoved(to: 2)
        textView.removeFromSuperview()

        try await Task.sleep(for: .milliseconds(800))
        #expect(!hover.isShowing)
    }
}
