import AppKit

// Render the same macOS llama glyph as the player header and supplied reference.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("OmaGAWD.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func render(pixels: Int, appIcon: Bool) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    if appIcon {
        NSColor(calibratedRed: 0.118, green: 0.122, blue: 0.169, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()
    }
    let text = NSAttributedString(string: "🦙", attributes: [.font: NSFont(name: "AppleColorEmoji", size: appIcon ? 740 : 900)!])
    let size = text.size()
    text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16,32,128,256,512] {
    try render(pixels: size, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(pixels: 20, appIcon: false).write(to: output.appendingPathComponent("MenuBarIcon.png"))
try render(pixels: 40, appIcon: false).write(to: output.appendingPathComponent("MenuBarIcon@2x.png"))
