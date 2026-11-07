import AppKit
import ApplicationServices
import Carbon
import CaptureCore

typealias NativeAXReply = (error: AXError, value: CFTypeRef?)

/// Narrow boundary: only explicit public AX selection requests, process state and time.
/// Fixtures replace this boundary without reading another application's UI or clipboard.
protocol NativeSelectionAccess {
    var now: Date { get }
    var trusted: Bool { get }
    var secureInput: Bool { get }
    var frontmostPID: pid_t? { get }
    func isRunning(_ pid: pid_t) -> Bool
    func bundleIdentifier(_ pid: pid_t) -> String?
    func application(_ pid: pid_t) -> AXUIElement
    func attribute(_ name: String, of element: AXUIElement, timeout: Float) -> NativeAXReply
    func string(for range: CFRange, of element: AXUIElement, timeout: Float) -> NativeAXReply
    func string(for marker: AXTextMarkerRange, of element: AXUIElement, timeout: Float) -> NativeAXReply
}

private struct SystemSelectionAccess: NativeSelectionAccess {
    var diagnosticBundle: String? = nil
    private func report(_ name: String, _ reply: NativeAXReply) {
        guard let bundle = diagnosticBundle else { return }
        let kind = reply.value.map { String(CFGetTypeID($0)) } ?? "nil"
        // 属性名、错误与类型足以诊断；仅 role/subrole 是固定系统枚举，可输出值。
        let knownRoles: Set<String> = ["AXApplication", "AXWindow", "AXWebArea", "AXTextField", "AXTextArea", "AXStaticText", "AXGroup", "AXUnknown", "AXMenu", "AXMenuItem", "AXSecureTextField"]
        let rawRole = reply.value as? String
        let role = (name == kAXRoleAttribute || name == kAXSubroleAttribute)
            ? (rawRole.map { knownRoles.contains($0) ? $0 : "other" } ?? "nil") : ""
        print("Selection diagnostic: app=\(bundle) attribute=\(name) error=\(reply.error.rawValue) type=\(kind) role=\(role)")
    }
    var now: Date { Date() }
    var trusted: Bool { AXIsProcessTrusted() }
    var secureInput: Bool { IsSecureEventInputEnabled() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func isRunning(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.isTerminated == false }
    func bundleIdentifier(_ pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func attribute(_ name: String, of element: AXUIElement, timeout: Float) -> NativeAXReply {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        report(name, (error, value))
        return (error, value)
    }
    func string(for range: CFRange, of element: AXUIElement, timeout: Float) -> NativeAXReply {
        AXUIElementSetMessagingTimeout(element, timeout)
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return (.illegalArgument, nil) }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        report(kAXStringForRangeParameterizedAttribute, (error, value))
        return (error, value)
    }
    func string(for marker: AXTextMarkerRange, of element: AXUIElement, timeout: Float) -> NativeAXReply {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, WebSelectionAttributes.stringForMarkerRange as CFString, marker, &value)
        report(WebSelectionAttributes.stringForMarkerRange, (error, value))
        return (error, value)
    }

}

/// 在触发时绑定来源，后台只读公开 AX 选区属性，不遍历无关控件。
final class NativeSelectionSource: SelectionSource {
    let pid: pid_t
    private var element: AXUIElement?
    private var window: AXUIElement?
    private var selectionElement: AXUIElement?
    private var markerIdentity: MarkerIdentity?
    private let access: NativeSelectionAccess
    init(pid: pid_t, access: NativeSelectionAccess = SystemSelectionAccess()) {
        self.pid = pid; self.access = access
    }

    private func timeout(until deadline: Date) throws -> Float {
        let remaining = deadline.timeIntervalSince(access.now)
        guard remaining > 0 else { throw SelectionFailure.timeout }
        return Float(min(remaining, 0.15))
    }

    /// Ordinary and parameterized AX failures have identical process/error semantics.
    private func value(from reply: NativeAXReply) throws -> CFTypeRef? {
        switch reply.error {
        case .success: return reply.value
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue: return nil
        case .apiDisabled: throw SelectionFailure.permissionRequired
        case .invalidUIElement: throw SelectionFailure.sourceExited
        case .cannotComplete:
            guard access.isRunning(pid) else { throw SelectionFailure.sourceExited }
            throw SelectionFailure.timeout
        default: throw SelectionFailure.unsupportedSelection
        }
    }

    private func attribute(_ name: String, of element: AXUIElement, deadline: Date) throws -> CFTypeRef? {
        try value(from: access.attribute(name, of: element, timeout: timeout(until: deadline)))
    }

    private func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func sameElement(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?): return CFEqual(first, second)
        default: return false
        }
    }

    /// Public SDK text-marker bytes are opaque identity only, retained for this
    /// operation; never parsed as document offsets, persisted or logged.
    private struct MarkerIdentity: Equatable {
        let start: Data
        let end: Data
        init(_ range: AXTextMarkerRange) throws {
            func bytes(_ marker: AXTextMarker) throws -> Data {
                let length = AXTextMarkerGetLength(marker)
                guard length > 0, length <= 4096 else { throw SelectionFailure.unsupportedSelection }
                return Data(bytes: AXTextMarkerGetBytePtr(marker), count: length)
            }
            start = try bytes(AXTextMarkerRangeCopyStartMarker(range))
            end = try bytes(AXTextMarkerRangeCopyEndMarker(range))
        }
    }

    private func textMarker(_ raw: CFTypeRef) throws -> AXTextMarkerRange {
        guard CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { throw SelectionFailure.unsupportedSelection }
        return unsafeBitCast(raw, to: AXTextMarkerRange.self)
    }

    private func validateSource() throws {
        guard access.trusted else { throw SelectionFailure.permissionRequired }
        guard !access.secureInput else { throw SelectionFailure.secureInput }
        guard access.isRunning(pid) else { throw SelectionFailure.sourceExited }
        guard access.frontmostPID == pid else { throw SelectionFailure.sourceChanged }
    }

    func read(deadline: Date) throws -> SelectionSnapshot {
        try validateSource()
        let application = access.application(pid)
        guard let focused = uiElement(try attribute(kAXFocusedUIElementAttribute, of: application, deadline: deadline)) else {
            throw SelectionFailure.unsupportedSelection
        }
        let currentWindow = uiElement(try attribute(kAXFocusedWindowAttribute, of: application, deadline: deadline))
        if let previous = element {
            guard CFEqual(previous, focused), sameElement(window, currentWindow) else { throw SelectionFailure.sourceChanged }
        }
        let windowDocument = try currentWindow.flatMap { try attribute(kAXDocumentAttribute, of: $0, deadline: deadline) as? String }
        let windowTitle = try currentWindow.flatMap { try attribute(kAXTitleAttribute, of: $0, deadline: deadline) as? String }
        var candidate = focused
        var candidatePath = [focused]
        var selectedText: String?
        var rangeDescription: String?
        var currentMarker: MarkerIdentity?
        // Only focused element and at most two ancestors; never whole value or page tree.
        for depth in 0..<3 {
            rangeDescription = nil // A range belongs to this candidate, never its child.
            let role = try attribute(kAXRoleAttribute, of: candidate, deadline: deadline) as? String
            let subrole = try attribute(kAXSubroleAttribute, of: candidate, deadline: deadline) as? String
            guard subrole != kAXSecureTextFieldSubrole else { throw SelectionFailure.secureInput }
            guard role != kAXMenuItemRole && role != kAXMenuRole else { throw SelectionFailure.unsupportedSelection }
            let rawRange = try attribute(kAXSelectedTextRangeAttribute, of: candidate, deadline: deadline)
            var selectedRange: CFRange?
            if let rawRange, CFGetTypeID(rawRange) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(unsafeBitCast(rawRange, to: AXValue.self), .cfRange, &range),
                   range.location >= 0, range.length >= 0, range.location <= Int.max - range.length {
                    selectedRange = range; rangeDescription = "\(range.location):\(range.length)"
                }
            }
            selectedText = try attribute(kAXSelectedTextAttribute, of: candidate, deadline: deadline) as? String
            if selectedText == nil, let range = selectedRange {
                guard range.length > 0 else { throw SelectionFailure.emptySelection }
                selectedText = try value(from: access.string(for: range, of: candidate, timeout: timeout(until: deadline))) as? String
            }
            // AXWebConstants.h exposes WebKit's selected text-marker range. This
            // fallback is restricted to the focused web area / bounded ancestors.
            // Never ask for the whole document or manufacture a range.
            if selectedText == nil, role == "AXWebArea",
               let raw = try attribute(WebSelectionAttributes.selectedMarkerRange, of: candidate, deadline: deadline) {
                let marker = try textMarker(raw)
                let identity = try MarkerIdentity(marker)
                guard identity.start != identity.end else { throw SelectionFailure.emptySelection }
                selectedText = try value(from: access.string(for: marker, of: candidate, timeout: timeout(until: deadline))) as? String
                if selectedText != nil {
                    guard let finalRaw = try attribute(WebSelectionAttributes.selectedMarkerRange, of: candidate, deadline: deadline),
                          try MarkerIdentity(textMarker(finalRaw)) == identity else { throw SelectionFailure.sourceChanged }
                    currentMarker = identity
                    rangeDescription = "text-marker" // Opaque marker bytes stay private to this read operation.
                }
            }
            if selectedText != nil { break }
            guard depth < 2,
                  let parent = uiElement(try attribute(kAXParentAttribute, of: candidate, deadline: deadline)) else { break }
            candidate = parent
            candidatePath.append(parent)
        }
        guard let text = selectedText else { throw SelectionFailure.unsupportedSelection }
        if let previous = selectionElement {
            guard CFEqual(previous, candidate), markerIdentity == currentMarker else { throw SelectionFailure.sourceChanged }
        }
        let document = try attribute(kAXDocumentAttribute, of: candidate, deadline: deadline) as? String ?? windowDocument
        let finalTitle = try currentWindow.flatMap { try attribute(kAXTitleAttribute, of: $0, deadline: deadline) as? String }
        let finalDocument = try currentWindow.flatMap { try attribute(kAXDocumentAttribute, of: $0, deadline: deadline) as? String }
        let finalFocus = uiElement(try attribute(kAXFocusedUIElementAttribute, of: application, deadline: deadline))
        let finalWindow = uiElement(try attribute(kAXFocusedWindowAttribute, of: application, deadline: deadline))
        guard windowTitle == finalTitle, windowDocument == finalDocument,
              sameElement(focused, finalFocus), sameElement(currentWindow, finalWindow) else { throw SelectionFailure.sourceChanged }
        // Revalidate only the already traversed path: identical text in a replacement
        // ancestor must not make a stale candidate appear to be the same selection.
        for index in 0..<(candidatePath.count - 1) {
            let parent = uiElement(try attribute(kAXParentAttribute, of: candidatePath[index], deadline: deadline))
            guard sameElement(parent, candidatePath[index + 1]) else { throw SelectionFailure.sourceChanged }
        }
        // Do this after the remaining metadata/path AX reads as well: the second
        // sample must not approve a marker that changed during those requests.
        if let identity = currentMarker {
            guard let finalRaw = try attribute(WebSelectionAttributes.selectedMarkerRange, of: candidate, deadline: deadline),
                  try MarkerIdentity(textMarker(finalRaw)) == identity else { throw SelectionFailure.sourceChanged }
        }
        try validateSource()
        _ = try timeout(until: deadline)
        element = focused; window = currentWindow; selectionElement = candidate; markerIdentity = currentMarker
        return SelectionSnapshot(text: text, sourceID: access.bundleIdentifier(pid) ?? String(pid), document: document, range: rangeDescription,
                                 contextToken: (windowDocument ?? "") + "\n" + (windowTitle ?? ""))
    }
}

@MainActor
enum NativeSelectionReader {
    static func read(allowCopyFallback: Bool = true, completion: @escaping (String, Result<SelectionSnapshot, Error>) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            completion("来源应用", .failure(SelectionFailure.sourceExited)); return
        }
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "来源应用"
        let copyKey = Shortcut.keyCode(typing: "c") ?? kVK_ANSI_C
        let diagnosticBundle = CommandLine.arguments.contains("--diagnose-selection") ? app.bundleIdentifier : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let source = NativeSelectionSource(pid: pid, access: SystemSelectionAccess(diagnosticBundle: diagnosticBundle))
            let result = Result {
                try SelectionCapture(direct: { try SelectionReader(source: source).read() }, copy: {
                    let copy = try NativeCopySelection(pid: pid, copyKeyCode: copyKey)
                    return try CopySelectionTransaction(access: copy).read()
                }).read(allowCopyFallback: allowCopyFallback)
            }
            DispatchQueue.main.async { completion(name, result) }
        }
    }
}
