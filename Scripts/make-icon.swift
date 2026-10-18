import AppKit
import Foundation
let fm = FileManager.default
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
func draw(_ size: Int, _ filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210)
    NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.92, alpha: 1).setFill(); tile.fill()
    let back = NSBezierPath(roundedRect: NSRect(x: 280, y: 310, width: 450, height: 470), xRadius: 54, yRadius: 54)
    NSColor.white.withAlphaComponent(0.24).setFill(); back.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 216, y: 248, width: 450, height: 470), xRadius: 54, yRadius: 54)
    NSColor.white.setFill(); front.fill()
    NSColor(calibratedRed: 0.16, green: 0.4, blue: 0.92, alpha: 1).setStroke()
    for (y, width) in [(610.0, 255.0), (530.0, 190.0)] {
        let line = NSBezierPath(); line.lineWidth = 25; line.lineCapStyle = .round
        line.move(to: NSPoint(x: 295, y: y)); line.line(to: NSPoint(x: 295 + width, y: y)); line.stroke()
    }
    let badge = NSBezierPath(roundedRect: NSRect(x: 440, y: 185, width: 370, height: 200), xRadius: 65, yRadius: 65)
    NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.6, alpha: 1).setFill(); badge.fill()
    let arrow = NSBezierPath(); arrow.lineWidth = 24; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 510, y: 285)); arrow.line(to: NSPoint(x: 735, y: 285))
    arrow.move(to: NSPoint(x: 675, y: 340)); arrow.line(to: NSPoint(x: 735, y: 285)); arrow.line(to: NSPoint(x: 675, y: 230))
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
}
for n in [16, 32, 128, 256, 512] {
    try draw(n, "icon_\(n)x\(n).png")
    try draw(n * 2, "icon_\(n)x\(n)@2x.png")
}
