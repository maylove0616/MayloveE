// Draws the app icon and writes Support/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Draws on a 1024-point canvas, following the macOS icon grid (an 824-point rounded tile).
/// `scale` is pixels per point; shadows are specified in pixels, so they are scaled by hand.
func drawIcon(scale: CGFloat) {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    rgb(0x16191E).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x343A44), ending: rgb(0x16191E))!.draw(in: tilePath, angle: -90)

    // Code lines in the editor's GitHub colors: keyword, plain, string, comment.
    let keyword: UInt32 = 0xFF7B72, plain: UInt32 = 0xE6EDF3, number: UInt32 = 0x79C0FF
    let string: UInt32 = 0xA5D6FF, comment: UInt32 = 0x8B949E
    let segments: [(row: Int, x: CGFloat, width: CGFloat, color: UInt32)] = [
        (0, 0, 220, keyword), (0, 240, 160, plain),
        (1, 60, 140, keyword), (1, 220, 300, number),
        (2, 60, 380, comment),
        (3, 60, 120, keyword), (3, 200, 250, string),
        (4, 0, 60, plain),
    ]
    // The block spans 520 points; center it horizontally.
    let left: CGFloat = 512 - 520 / 2
    for segment in segments {
        let y = 700 - CGFloat(segment.row) * 95
        rgb(segment.color).setFill()
        NSBezierPath(roundedRect: NSRect(x: left + segment.x, y: y, width: segment.width, height: 44),
                     xRadius: 22, yRadius: 22).fill()
    }
    // The caret on the last line.
    rgb(0x4C8DFF).setFill()
    NSBezierPath(roundedRect: NSRect(x: left + 90, y: 275, width: 18, height: 120), xRadius: 9, yRadius: 9).fill()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(scale: scale)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote Support/AppIcon.icns")
