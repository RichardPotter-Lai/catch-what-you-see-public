import AppKit
import Carbon
import CaptureCore

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission. It lasts as long as the
/// object.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: (Bool) -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private var latch = HotKeyLatch()
    private var releaseTimer: Timer?
    var suspended = false

    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        if !HotKey.handlerInstalled {
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                HotKey.actions[key.id]?(pressed)
                return noErr
            }, 2, &specs, nil, nil)
            guard status == noErr else { return nil }
            HotKey.handlerInstalled = true
        }
        id = HotKey.nextID; HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4357_5359), id: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), hotKeyID,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, ref != nil else { return nil }
        HotKey.actions[id] = { [weak self] pressed in
            guard let self else { return }
            if pressed {
                if self.latch.press(), !self.suspended { action() }
            } else { self.latch.observeRelease(Self.keyReleased(shortcut.keyCode)) }
        }
        // Carbon 释放通知可能因失活而丢失；仅查询该物理键，不记录键盘输入。
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.latch.observeRelease(Self.keyReleased(shortcut.keyCode))
        }
    }
    private static func keyReleased(_ code: Int) -> Bool? {
        guard (0..<128).contains(code) else { return nil }
        return !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }
    deinit {
        releaseTimer?.invalidate()
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

}

/// The shortcut that shows and hides the line: ⌃⌥T unless changed, or none.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// The key as typed, for the menu: "t", " ", "1".
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option], key: "t")
    static let captureStandard = Shortcut(keyCode: kVK_ANSI_C, modifiers: [.option], key: "c")

    /// ⌘Z, for Put back while the pointer is on the line. A hot key is a key
    /// on the keyboard, not a letter, so it is the key that types Z with
    /// Command held in the layout in use: on AZERTY, where QWERTY has W.
    static var putBack: Shortcut {
        Shortcut(keyCode: keyCode(typing: "z") ?? kVK_ANSI_Z, modifiers: .command, key: "z")
    }

    /// The key that types this letter with Command held, in a keyboard
    /// layout, by default the one in use.
    static func keyCode(typing letter: String,
                        in source: TISInputSource? = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) -> Int? {
        guard let source, let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        return layout.withUnsafeBytes { bytes -> Int? in
            guard let keys = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let command = UInt32((cmdKey >> 8) & 0xFF)
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(keys, UInt16(code), UInt16(kUCKeyActionDown), command,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length).lowercased() == letter { return code }
            }
            return nil
        }
    }

    private static let defaultsKey = "shortcut"

    /// The user's choice. Nil means no shortcut at all.
    static var current: Shortcut? {
        get {
            guard let saved = AppEnvironment.preferences.dictionary(forKey: defaultsKey) else { return standard }
            guard let code = saved["keyCode"] as? Int, let flags = saved["modifiers"] as? UInt,
                  let key = saved["key"] as? String else { return nil }
            return Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: flags), key: key)
        }
        set {
            AppEnvironment.preferences.set(newValue.map {
                ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any]
            } ?? [:], forKey: defaultsKey)
        }
    }

    /// From a key press, if it makes a usable global shortcut: it needs
    /// Command, Control or Option, so typing alone never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: flags, key: key)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// As macOS writes it in menus: ⌃⌥⇧⌘ and the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key == " " ? L("Space") : key.uppercased())
    }
}

/// Asks for a new shortcut in a small window: the next key press with
/// Command, Control or Option becomes it. Escape cancels and Delete leaves
/// the line without a shortcut.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ShortcutRecorder()

    private var window: NSWindow?
    private var monitor: Any?
    private var done: ((Shortcut??) -> Void)?

    /// Calls back with the new shortcut, `.some(nil)` for none, or nil if
    /// cancelled.
    func record(_ done: @escaping (Shortcut??) -> Void) {
        finish(nil)
        self.done = done

        let title = NSTextField(labelWithString: L("Press the new shortcut"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: L("Escape cancels. Delete removes the shortcut."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Change Shortcut")
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if event.keyCode == UInt16(kVK_Escape) && plain {
                self.finish(nil)
            } else if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && plain {
                self.finish(.some(nil))
            } else if let shortcut = Shortcut(event: event) {
                self.finish(.some(shortcut))
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        finish(nil)
    }

    private func finish(_ result: Shortcut??) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = self.done
        self.done = nil
        window?.close()
        window = nil
        done?(result)
    }
}
