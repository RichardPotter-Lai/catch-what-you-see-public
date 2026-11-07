import AppKit
import ApplicationServices
import Carbon
import CaptureCore

/// A deliberate Cmd+C addressed to the original PID, never a global clipboard
/// listener. Previous clipboard bytes live only for this short transaction.
final class NativeCopySelection: CopySelectionAccess {
    let pid: pid_t
    let sourceID: String
    private let copyKeyCode: CGKeyCode
    private let app: AXUIElement
    private let originalFocus: AXUIElement?
    private let originalWindow: AXUIElement?
    private let pasteboard: NSPasteboard
    private static let protectedTypes = Set(["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
    private static let maxSnapshotBytes = 32 * 1024 * 1024

    init(pid: pid_t, copyKeyCode: Int, pasteboard: NSPasteboard = .general) throws {
        guard AXIsProcessTrusted() else { throw SelectionFailure.permissionRequired }
        guard !IsSecureEventInputEnabled() else { throw SelectionFailure.secureInput }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw SelectionFailure.sourceChanged }
        self.pid = pid
        self.sourceID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? String(pid)
        self.copyKeyCode = CGKeyCode(copyKeyCode)
        self.pasteboard = pasteboard
        app = AXUIElementCreateApplication(pid)
        originalFocus = try Self.element(kAXFocusedUIElementAttribute, in: app)
        originalWindow = try Self.element(kAXFocusedWindowAttribute, in: app)
        try validateSource()
    }

    var now: Date { Date() }
    var changeCount: Int { pasteboard.changeCount }
    var triggeringKeysReleased: Bool {
        let modifiers = CGEventSource.flagsState(.hidSystemState)
        return modifiers.intersection([.maskAlternate, .maskControl, .maskCommand, .maskShift]).isEmpty
            && !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_C))
    }
    func waitBriefly() { Thread.sleep(forTimeInterval: 0.02) }

    private static func value(_ name: CFString, in element: AXUIElement) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.12)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        switch error {
        case .success: return value
        case .noValue, .attributeUnsupported, .notImplemented: return nil
        case .apiDisabled: throw SelectionFailure.permissionRequired
        case .invalidUIElement: throw SelectionFailure.sourceExited
        case .cannotComplete: throw SelectionFailure.timeout
        default: throw SelectionFailure.unsupportedSelection
        }
    }
    private static func element(_ name: String, in parent: AXUIElement) throws -> AXUIElement? {
        guard let value = try value(name as CFString, in: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case let (a?,b?): return CFEqual(a,b)
        default: return false
        }
    }
    func validateSource() throws {
        guard AXIsProcessTrusted() else { throw SelectionFailure.permissionRequired }
        guard !IsSecureEventInputEnabled() else { throw SelectionFailure.secureInput }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { throw SelectionFailure.sourceExited }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw SelectionFailure.sourceChanged }
        let focus = try Self.element(kAXFocusedUIElementAttribute, in: app)
        let window = try Self.element(kAXFocusedWindowAttribute, in: app)
        guard Self.same(focus,originalFocus), Self.same(window,originalWindow) else { throw SelectionFailure.sourceChanged }
        if let focus {
            let role = try Self.value(kAXRoleAttribute as CFString, in: focus) as? String
            let subrole = try Self.value(kAXSubroleAttribute as CFString, in: focus) as? String
            guard subrole != kAXSecureTextFieldSubrole else { throw SelectionFailure.secureInput }
            guard role != kAXMenuRole && role != kAXMenuItemRole else { throw SelectionFailure.sourceChanged }
        }
    }

    func snapshot() throws -> CopyClipboardSnapshot { try Self.snapshot(pasteboard) }
    func copiedText() throws -> CopyClipboardSnapshot { try Self.textSnapshot(pasteboard) }
    static func clipboardText(_ board: NSPasteboard = .general) throws -> String {
        let snapshot = try textSnapshot(board)
        guard !snapshot.protected else { throw CopySelectionFailure.protectedClipboard }
        guard let text = snapshot.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CopySelectionFailure.noFreshText
        }
        return text
    }
    private static func textSnapshot(_ board: NSPasteboard) throws -> CopyClipboardSnapshot {
        let version = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
            .union((board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        guard protectedTypes.isDisjoint(with: types) else {
            return CopyClipboardSnapshot(changeCount: version, items: [], text: nil, protected: true)
        }
        let text = board.string(forType: .string)
        guard board.changeCount == version else { throw CopySelectionFailure.clipboardChanged }
        // New clipboard payloads may also contain large images or lazy file
        // representations. Only the original clipboard needs a full backup.
        return CopyClipboardSnapshot(changeCount: version, items: [], text: text)
    }
    static func snapshot(_ board: NSPasteboard) throws -> CopyClipboardSnapshot {
        let version = board.changeCount
        let entries = board.pasteboardItems ?? []
        let allTypes = Set(entries.flatMap { $0.types.map(\.rawValue) })
            .union((board.types ?? []).map(\.rawValue))
        if !protectedTypes.isDisjoint(with: allTypes) {
            return CopyClipboardSnapshot(changeCount: version, items: [], text: nil, protected: true)
        }
        guard entries.count <= 32, !(entries.isEmpty && !allTypes.isEmpty) else { throw CopySelectionFailure.unsupportedClipboard }
        var bytes = 0
        var saved: [[String:Data]] = []
        for entry in entries {
            guard entry.types.count <= 64 else { throw CopySelectionFailure.unsupportedClipboard }
            var item: [String:Data] = [:]
            for type in entry.types {
                guard let data = entry.data(forType: type), data.count <= maxSnapshotBytes - bytes else {
                    throw CopySelectionFailure.unsupportedClipboard
                }
                bytes += data.count
                item[type.rawValue] = data
            }
            saved.append(item)
        }
        let text = board.string(forType: .string)
        guard board.changeCount == version else { throw CopySelectionFailure.clipboardChanged }
        return CopyClipboardSnapshot(changeCount: version, items: saved, text: text)
    }

    func requestCopy() throws {
        try validateSource()
        guard triggeringKeysReleased else { throw CopySelectionFailure.keysStillHeld }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: false) else {
            throw CopySelectionFailure.unavailable
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }

    func restore(_ original: CopyClipboardSnapshot, ifUnchanged version: Int) -> ClipboardRestoration {
        guard pasteboard.changeCount == version else { return .newerContentPreserved }
        let items = original.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type,data) in values { item.setData(data, forType: .init(type)) }
            return item
        }
        // NSPasteboard has no cross-process compare-and-swap: this is best effort.
        // Check again after preparing the items and never restore a known newer copy.
        guard pasteboard.changeCount == version else { return .newerContentPreserved }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared else { return .newerContentPreserved }
        if items.isEmpty { return .restored }
        return pasteboard.writeObjects(items) ? .restored : .failed
    }
}
