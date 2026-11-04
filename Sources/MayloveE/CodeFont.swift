import AppKit

/// The monospaced font for code (editor, console, diff), adjustable with ⌘= / ⌘- and remembered.
@MainActor
enum CodeFont {
    static let defaultSize: CGFloat = 16
    static let sizeRange: ClosedRange<CGFloat> = 9...32
    /// Posted after the size changes; views showing code re-apply their fonts.
    static let didChange = Notification.Name("MayloveE.CodeFontDidChange")

    private static let defaultsKey = "codeFontSize"

    static var size: CGFloat {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return stored > 0 ? min(max(CGFloat(stored), sizeRange.lowerBound), sizeRange.upperBound) : defaultSize
    }

    /// The code font, optionally a few points smaller (the console and diff use one point less).
    static func font(offset: CGFloat = 0) -> NSFont {
        .monospacedSystemFont(ofSize: max(size + offset, sizeRange.lowerBound), weight: .regular)
    }

    /// Line numbers: a little smaller than the code they label.
    static func gutterFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(size - 2, sizeRange.lowerBound), weight: .regular)
    }

    static func increase() { setSize(size + 1) }
    static func decrease() { setSize(size - 1) }
    static func reset() { setSize(defaultSize) }

    private static func setSize(_ newSize: CGFloat) {
        let clamped = min(max(newSize, sizeRange.lowerBound), sizeRange.upperBound)
        guard clamped != size else { return NSSound.beep() }
        if clamped == defaultSize {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(Double(clamped), forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
