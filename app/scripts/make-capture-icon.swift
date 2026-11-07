// 原创便笺图标，不复用上游衣夹或品牌图形。
import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.30, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
NSColor(calibratedRed: 1, green: 0.96, blue: 0.84, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 235, y: 190, width: 554, height: 640), xRadius: 42, yRadius: 42).fill()
NSColor(calibratedRed: 0.25, green: 0.46, blue: 0.42, alpha: 1).setStroke()
for (y, length) in [(650, 360), (535, 360), (420, 245)] {
    let line = NSBezierPath()
    line.lineWidth = 28
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: 330, y: y)); line.line(to: NSPoint(x: 330 + length, y: y))
    line.stroke()
}
NSColor(calibratedRed: 0.95, green: 0.61, blue: 0.30, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 715, y: 155, width: 160, height: 160)).fill()
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("无法生成图标") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
