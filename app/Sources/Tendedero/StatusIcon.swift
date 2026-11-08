import AppKit

/// 菜单栏图标：与应用图标同款的便笺（纸张 + 三行文字 + 右下角圆点）。
/// 画成模板图，系统会按菜单栏的浅色/深色自动着色。
enum StatusIcon {
    static func image(filled: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            // 纸张
            let paper = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 2.5, width: 10.5, height: 13), xRadius: 1.8, yRadius: 1.8)
            paper.lineWidth = 1.5
            if filled {
                // 绳上有东西：实心纸张，文字行镂空。
                paper.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            } else {
                paper.stroke()
            }
            for (y, length) in [(12.0, 5.5), (9.5, 5.5), (7.0, 3.5)] {
                let line = NSBezierPath()
                line.lineWidth = 1.4
                line.lineCapStyle = .round
                line.move(to: NSPoint(x: 6, y: y))
                line.line(to: NSPoint(x: 6 + length, y: y))
                line.stroke()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // 右下角圆点（应用图标中的橙色圆）
            NSBezierPath(ovalIn: NSRect(x: 11.2, y: 1, width: 5.6, height: 5.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
