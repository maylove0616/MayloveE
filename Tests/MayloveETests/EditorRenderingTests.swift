import AppKit
import Testing
@testable import MayloveE

@MainActor
struct EditorRenderingTests {
    /// Regression: the line-number ruler used to paint over the whole editor on macOS 26+.
    @Test func textIsVisibleNextToLineNumbers() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("RenderProbe.java")
        try "public class Probe {\n    int x = 1;\n}\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let area = EditorAreaViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = area
        window.setContentSize(NSSize(width: 800, height: 600))
        area.open(file)
        window.layoutIfNeeded()

        let scrollView = try #require(findView(NSScrollView.self, in: window.contentView!) {
            $0.documentView is NSTextView
        })
        let gutterWidth = try #require(scrollView.verticalRulerView).ruleThickness

        let bitmap = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / scrollView.bounds.width

        // Look for any dark or colored pixel in the first line, right of the gutter.
        var foundText = false
        let xRange = Int((gutterWidth + 2) * scale)..<Int(400 * scale)
        let yRange = 0..<Int(24 * scale)
        search: for y in yRange {
            for x in xRange {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.brightnessComponent < 0.8 || color.saturationComponent > 0.3 {
                    foundText = true
                    break search
                }
            }
        }
        #expect(foundText)
    }

    /// Regression: the breadcrumb bar painted its whole dirty rect, which reached above its
    /// bounds and covered the tab bar.
    @Test func tabBarIsNotPaintedOverByBreadcrumbs() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TabProbe.java")
        try "class TabProbe {}\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let area = EditorAreaViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = area
        window.setContentSize(NSSize(width: 800, height: 600))
        area.open(file)
        window.layoutIfNeeded()

        let tabBar = try #require(findView(TabBarView.self, in: area.view) { _ in true })
        #expect(!tabBar.isHidden)
        let bitmap = try #require(area.view.bitmapImageRepForCachingDisplay(in: area.view.bounds))
        area.view.cacheDisplay(in: area.view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / area.view.bounds.width
        // Bitmap rows run top-down; the view is not flipped.
        let barTop = Int((area.view.bounds.height - tabBar.frame.maxY) * scale)
        let barBottom = Int((area.view.bounds.height - tabBar.frame.minY) * scale)

        // The selected tab is underlined in the accent color.
        var foundAccent = false
        search: for y in barTop..<barBottom {
            for x in 0..<Int(150 * scale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.saturationComponent > 0.4, color.brightnessComponent > 0.3 {
                    foundAccent = true
                    break search
                }
            }
        }
        #expect(foundAccent, "selected tab should be drawn in the tab bar")
    }

    private func findView<T: NSView>(_ type: T.Type, in view: NSView, where predicate: (T) -> Bool) -> T? {
        if let match = view as? T, predicate(match) { return match }
        for subview in view.subviews {
            if let match = findView(type, in: subview, where: predicate) { return match }
        }
        return nil
    }
}
