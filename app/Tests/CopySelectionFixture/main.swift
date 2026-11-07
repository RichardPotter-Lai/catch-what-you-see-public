import AppKit

/// Owned test surface: intentionally supports Copy but exposes no AX selection.
/// It never sends messages, opens a web connection, or loads user documents.
final class CopySurface: NSView {
    static let text = "Catch synthetic 选区\n第二行 123"
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        ("兼容采集测试：本窗口只含合成文字\n\n" + Self.text as NSString).draw(
            in: bounds.insetBy(dx: 24, dy: 24),
            withAttributes: [.font:NSFont.systemFont(ofSize: 18), .foregroundColor:NSColor.labelColor])
    }
    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text, forType: .string)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationMenu = NSMenuItem()
applicationMenu.submenu = NSMenu()
applicationMenu.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(applicationMenu)
let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
edit.submenu = NSMenu(title: "Edit")
edit.submenu?.addItem(withTitle: "Copy", action: #selector(CopySurface.copy(_:)), keyEquivalent: "c")
menu.addItem(edit)
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(x: 200, y: 250, width: 560, height: 200),
                      styleMask: [.titled,.closable], backing: .buffered, defer: false)
window.title = "Catch · 合成复制测试"
let surface = CopySurface(frame: window.contentView!.bounds)
surface.setAccessibilityElement(true)
surface.setAccessibilityRole(.group)
window.contentView = surface
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(surface)
app.activate(ignoringOtherApps: true)
app.run()
