import AppKit
import ApplicationServices
import CaptureCore

/// Deterministic adapter checks. AX elements are identity tokens only: no system AX
/// reads, permission prompts, frontmost-app changes, clipboard or library access.
@MainActor
enum NativeSelectionChecks {
    private enum CheckFailure: Error { case mismatch }

    static func run() throws {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            do {
                guard try body() else { throw CheckFailure.mismatch }
                passed += 1
                print("PASS: native-selection \(name)")
            } catch {
                failed += 1
                print("FAIL: native-selection \(name)")
            }
        }
        func fails(_ expected: SelectionFailure, _ body: () throws -> SelectionSnapshot) -> Bool {
            do { _ = try body(); return false }
            catch let failure as SelectionFailure { return failure == expected }
            catch { return false }
        }
        func read(_ access: Fixture) throws -> SelectionSnapshot {
            try SelectionReader(source: NativeSelectionSource(pid: Fixture.pid, access: access),
                                clock: CaptureClock(now: { access.now })).read()
        }

        check("selected-text preserves Unicode/newlines, unknown metadata remains nil") {
            let access = Fixture()
            let result = try read(access)
            return result.text == Fixture.text && result.document == nil && result.range == nil
                && result.sourceID == "local.synthetic.source" && access.isBounded
        }
        check("bundle unavailable uses bound PID only") {
            let access = Fixture(); access.bundle = nil
            return try read(access).sourceID == String(Fixture.pid)
        }
        check("explicit selected range uses parameterized text only") {
            let access = Fixture(); access.removeText(); access.setRange(2, 8)
            access.parameterReply = (.success, Fixture.text as CFString)
            let result = try read(access)
            return result.text == Fixture.text && result.range == "2:8" && access.parameters.count == 2
                && access.parameters.allSatisfy { $0.location == 2 && $0.length == 8 } && access.isBounded
        }
        check("web text-marker selection reads explicit range only") {
            let access = Fixture(); access.withMarker()
            let result = try read(access)
            return result.text == Fixture.text && access.markerParameters.count == 2 && access.isBounded
        }
        check("changed marker with identical text between samples is rejected") {
            let access = Fixture(); access.withMarker(); var reads = 0
            access.onAttribute = { _, name in
                if name == WebSelectionAttributes.selectedMarkerRange {
                    reads += 1
                    if reads == 4 { access.set(1, name, Fixture.marker(4, 9)) }
                }
            }
            return fails(.sourceChanged) { try read(access) }
        }
        check("marker changes during text fetch rejects single read") {
            let access = Fixture(); access.withMarker()
            access.onMarkerParameter = { access.set(1, WebSelectionAttributes.selectedMarkerRange, Fixture.marker(4, 9)) }
            return fails(.sourceChanged) { try read(access) }
        }
        check("marker change in second sample final metadata read is rejected") {
            let access = Fixture(); access.withMarker(); var reads = 0
            access.onAttribute = { node, name in
                if node == 1 && name == kAXDocumentAttribute {
                    reads += 1
                    if reads == 2 { access.set(1, WebSelectionAttributes.selectedMarkerRange, Fixture.marker(4, 9)) }
                }
            }
            return fails(.sourceChanged) { try read(access) }
        }
        check("collapsed marker is empty without fetching text") {
            let access = Fixture(); access.withMarker(2, 2)
            return fails(.emptySelection) { try read(access) } && access.markerParameters.isEmpty
        }
        check("wrong marker type is not passed to AX") {
            let access = Fixture(); access.withMarker()
            access.set(1, WebSelectionAttributes.selectedMarkerRange, "wrong" as CFString)
            return fails(.unsupportedSelection) { try read(access) } && access.markerParameters.isEmpty
        }
        check("non-web controls never request text markers") {
            let access = Fixture(); access.withMarker(); access.set(1, kAXRoleAttribute, kAXTextAreaRole as CFString)
            return fails(.unsupportedSelection) { try read(access) }
                && !access.requests.contains { $0.name == WebSelectionAttributes.selectedMarkerRange }
        }
        for (error, expected) in [(AXError.apiDisabled, SelectionFailure.permissionRequired),
                                 (.invalidUIElement, .sourceExited), (.cannotComplete, .timeout),
                                 (.parameterizedAttributeUnsupported, .unsupportedSelection)] {
            check("marker parameter error \(error.rawValue) classified") {
                let access = Fixture(); access.withMarker(); access.markerReply = (error, nil)
                return fails(expected) { try read(access) }
            }
        }
        check("marker request exhausted budget cannot make another request") {
            let access = Fixture(); access.withMarker()
            access.onMarkerParameter = { access.now.addTimeInterval(2) }
            return fails(.timeout) { try read(access) }
                && access.requests.last?.name == WebSelectionAttributes.stringForMarkerRange
        }
        check("marker fetch cannot capture after frontmost changes") {
            let access = Fixture(); access.withMarker()
            access.onMarkerParameter = { access.frontmostPID = 999 }
            return fails(.sourceChanged) { try read(access) }
        }
        check("ordinary selected text takes priority over marker fallback") {
            let access = Fixture(); access.withMarker()
            access.set(1, kAXSelectedTextAttribute, Fixture.text as CFString)
            return try read(access).text == Fixture.text && access.markerParameters.isEmpty
        }
        for depth in 1...2 {
            check("ancestor depth \(depth) is supported") {
                let access = Fixture(); access.selectionAtDepth(depth)
                return try read(access).text == Fixture.text && access.isBounded
            }
        }
        check("depth three is never visited") {
            let access = Fixture(); access.selectionAtDepth(3)
            return fails(.unsupportedSelection) { try read(access) }
                && !access.requests.contains(where: { $0.node == 4 })
        }
        for value in ["", " \n\t "] {
            check("empty/whitespace text is distinct from unsupported") {
                let access = Fixture(); access.set(1, kAXSelectedTextAttribute, value as CFString)
                return fails(.emptySelection) { try read(access) }
            }
        }
        check("zero-length fallback is empty without parameter request") {
            let access = Fixture(); access.removeText(); access.setRange(2, 0)
            return fails(.emptySelection) { try read(access) } && access.parameters.isEmpty
        }
        for range in [CFRange(location: -1, length: 2), CFRange(location: 1, length: -2)] {
            check("negative range is never dereferenced") {
                let access = Fixture(); access.removeText(); access.setRange(range.location, range.length)
                return fails(.unsupportedSelection) { try read(access) } && access.parameters.isEmpty
            }
        }
        check("wrong range type is never dereferenced") {
            let access = Fixture(); access.removeText(); access.set(1, kAXSelectedTextRangeAttribute, "bad" as CFString)
            return fails(.unsupportedSelection) { try read(access) } && access.parameters.isEmpty
        }
        check("absent selected attributes are unsupported") {
            let access = Fixture(); access.removeText()
            return fails(.unsupportedSelection) { try read(access) }
        }
        check("no Accessibility permission performs zero AX reads") {
            let access = Fixture(); access.trusted = false
            return fails(.permissionRequired) { try read(access) } && access.requests.isEmpty
        }
        check("secure event input performs zero AX reads") {
            let access = Fixture(); access.secureInput = true
            return fails(.secureInput) { try read(access) } && access.requests.isEmpty
        }
        check("secure field never requests text") {
            let access = Fixture(); access.set(1, kAXSubroleAttribute, kAXSecureTextFieldSubrole as CFString)
            return fails(.secureInput) { try read(access) }
                && !access.requests.contains(where: { $0.name == kAXSelectedTextAttribute })
        }
        for role in [kAXMenuRole, kAXMenuItemRole] {
            check("menu focus does not capture menu text") {
                let access = Fixture(); access.set(1, kAXRoleAttribute, role as CFString)
                return fails(.unsupportedSelection) { try read(access) }
                    && !access.requests.contains(where: { $0.name == kAXSelectedTextAttribute })
            }
        }
        for (error, expected) in [(AXError.apiDisabled, SelectionFailure.permissionRequired),
                                   (.invalidUIElement, .sourceExited), (.cannotComplete, .timeout),
                                   (.failure, .unsupportedSelection)] {
            check("attribute AX error \(error.rawValue) classified") {
                let access = Fixture(); access.replies[1, default: [:]][kAXSelectedTextAttribute] = (error, nil)
                return fails(expected) { try read(access) }
            }
        }
        check("attribute cannotComplete after process exit is sourceExited") {
            let access = Fixture()
            access.onAttribute = { node, name in
                if node == 1 && name == kAXSelectedTextAttribute { access.running = false }
            }
            access.replies[1, default: [:]][kAXSelectedTextAttribute] = (.cannotComplete, nil)
            return fails(.sourceExited) { try read(access) }
        }
        for (error, expected) in [(AXError.apiDisabled, SelectionFailure.permissionRequired),
                                   (.invalidUIElement, .sourceExited), (.cannotComplete, .timeout),
                                   (.parameterizedAttributeUnsupported, .unsupportedSelection)] {
            check("parameterized AX error \(error.rawValue) classified") {
                let access = Fixture(); access.removeText(); access.setRange(0, 2)
                access.parameterReply = (error, nil)
                return fails(expected) { try read(access) }
            }
        }
        check("parameterized cannotComplete after process exit is sourceExited") {
            let access = Fixture(); access.removeText(); access.setRange(0, 2)
            access.parameterReply = (.cannotComplete, nil)
            access.onParameter = { access.running = false }
            return fails(.sourceExited) { try read(access) }
        }
        check("candidate range does not leak into ancestor selection") {
            let access = Fixture(); access.selectionAtDepth(1); access.setRange(4, 7)
            let result = try read(access)
            return result.range == nil && result.text == Fixture.text
        }
        check("same-text ancestor replacement invalidates bound candidate") {
            let access = Fixture(); access.selectionAtDepth(1)
            access.set(3, kAXSelectedTextAttribute, Fixture.text as CFString)
            let source = NativeSelectionSource(pid: Fixture.pid, access: access)
            _ = try source.read(deadline: access.now.addingTimeInterval(1))
            access.set(1, kAXParentAttribute, access.nodes[3])
            return fails(.sourceChanged) { try source.read(deadline: access.now.addingTimeInterval(1)) }
        }
        check("candidate reparenting within one read is rejected") {
            let access = Fixture(); access.selectionAtDepth(1)
            access.onAttribute = { node, name in
                if node == 2 && name == kAXSelectedTextAttribute { access.set(1, kAXParentAttribute, access.nodes[3]) }
            }
            return fails(.sourceChanged) { try read(access) }
        }
        check("source already exited performs zero AX reads") {
            let access = Fixture(); access.running = false
            return fails(.sourceExited) { try read(access) } && access.requests.isEmpty
        }
        check("frontmost app changed before read performs zero AX reads") {
            let access = Fixture(); access.frontmostPID = 999
            return fails(.sourceChanged) { try read(access) } && access.requests.isEmpty
        }
        check("frontmost app changed during read rejects snapshot") {
            let access = Fixture()
            access.onAttribute = { _, name in if name == kAXSelectedTextAttribute { access.frontmostPID = 999 } }
            return fails(.sourceChanged) { try read(access) }
        }
        check("focused element changed during read rejects snapshot") {
            let access = Fixture()
            access.onAttribute = { _, name in if name == kAXSelectedTextAttribute { access.set(0, kAXFocusedUIElementAttribute, access.nodes[3]) } }
            return fails(.sourceChanged) { try read(access) }
        }
        check("same-title different window during one read is rejected") {
            let access = Fixture(); access.withWindow()
            access.onAttribute = { _, name in if name == kAXSelectedTextAttribute { access.set(0, kAXFocusedWindowAttribute, access.nodes[6]) } }
            return fails(.sourceChanged) {
                try NativeSelectionSource(pid: Fixture.pid, access: access).read(deadline: access.now.addingTimeInterval(1))
            }
        }
        for field in [kAXTitleAttribute, kAXDocumentAttribute] {
            check("window metadata \(field) change rejects mixed snapshot") {
                let access = Fixture(); access.withWindow()
                access.onAttribute = { _, name in if name == kAXSelectedTextAttribute { access.set(5, field, "changed" as CFString) } }
                return fails(.sourceChanged) { try read(access) }
            }
        }
        check("window disappearing rejects snapshot") {
            let access = Fixture(); access.withWindow()
            let source = NativeSelectionSource(pid: Fixture.pid, access: access)
            _ = try source.read(deadline: access.now.addingTimeInterval(1))
            access.replies[0]?[kAXFocusedWindowAttribute] = nil
            return fails(.sourceChanged) { try source.read(deadline: access.now.addingTimeInterval(1)) }
        }
        check("window appearing between reads rejects snapshot") {
            let access = Fixture(); let source = NativeSelectionSource(pid: Fixture.pid, access: access)
            _ = try source.read(deadline: access.now.addingTimeInterval(1))
            access.withWindow()
            return fails(.sourceChanged) { try source.read(deadline: access.now.addingTimeInterval(1)) }
        }
        check("selection text change between samples is rejected") {
            let access = Fixture(); var reads = 0
            access.onAttribute = { _, name in
                if name == kAXSelectedTextAttribute { reads += 1; if reads == 2 { access.set(1, name, "changed" as CFString) } }
            }
            return fails(.sourceChanged) { try read(access) }
        }
        check("same text but changed range between samples is rejected") {
            let access = Fixture(); access.setRange(0, 5); var reads = 0
            access.onAttribute = { _, name in
                if name == kAXSelectedTextRangeAttribute { reads += 1; if reads == 2 { access.setRange(8, 5) } }
            }
            return fails(.sourceChanged) { try read(access) }
        }
        for (name, expected) in [("exit", SelectionFailure.sourceExited), ("permission", .permissionRequired), ("secure", .secureInput)] {
            check("source state \(name) change during single read is rejected") {
                let access = Fixture()
                access.onAttribute = { _, attribute in
                    if attribute == kAXSelectedTextAttribute {
                        if name == "exit" { access.running = false }
                        if name == "permission" { access.trusted = false }
                        if name == "secure" { access.secureInput = true }
                    }
                }
                return fails(expected) {
                    try NativeSelectionSource(pid: Fixture.pid, access: access).read(deadline: access.now.addingTimeInterval(1))
                }
            }
        }
        check("completed snapshot survives later frontmost change") {
            let access = Fixture(); let captured = try read(access); access.frontmostPID = 999
            return captured.text == Fixture.text && captured.sourceID == "local.synthetic.source"
        }
        check("expired deadline makes zero AX calls") {
            let access = Fixture()
            return fails(.timeout) { try NativeSelectionSource(pid: Fixture.pid, access: access).read(deadline: access.now) }
                && access.requests.isEmpty
        }
        check("deadline exhausted by AX call makes no subsequent AX call") {
            let access = Fixture()
            access.onAttribute = { _, _ in access.now.addTimeInterval(2) }
            return fails(.timeout) { try read(access) } && access.requests.count == 1
        }
        check("per-request timeout is limited to remaining budget") {
            let access = Fixture(); let source = NativeSelectionSource(pid: Fixture.pid, access: access)
            _ = try source.read(deadline: access.now.addingTimeInterval(0.04))
            return access.requests.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.041 }
        }
        print("NativeSelectionChecks: \(passed) passed, \(failed) failed (synthetic adapter; no real-app certification)")
        guard failed == 0 else { throw CheckFailure.mismatch }
    }

    private final class Fixture: NativeSelectionAccess {
        static let pid: pid_t = 4242
        static let text = "Catch synthetic 选区\n第二行 123"
        // No message is sent to these PIDs. Only CF identity/type checks use these tokens.
        let nodes = (0..<7).map { AXUIElementCreateApplication(pid_t(5000 + $0)) }
        var now = Date(timeIntervalSince1970: 1000)
        var trusted = true
        var secureInput = false
        var frontmostPID: pid_t? = Fixture.pid
        var running = true
        var bundle: String? = "local.synthetic.source"
        var replies: [Int: [String: NativeAXReply]] = [:]
        var requests: [(node: Int, name: String, timeout: Float)] = []
        var parameters: [CFRange] = []
        var parameterReply: NativeAXReply = (.parameterizedAttributeUnsupported, nil)
        var onAttribute: ((Int, String) -> Void)?
        var onParameter: (() -> Void)?
        init() {
            set(0, kAXFocusedUIElementAttribute, nodes[1])
            set(1, kAXSelectedTextAttribute, Self.text as CFString)
        }
        var markerReply: NativeAXReply = (.success, Fixture.text as CFString)
        var markerParameters: [AXTextMarkerRange] = []
        var onMarkerParameter: (() -> Void)?
        static func marker(_ start: UInt8, _ end: UInt8) -> AXTextMarkerRange {
            var start = start; var end = end
            return AXTextMarkerRangeCreate(nil, AXTextMarkerCreate(nil, &start, 1), AXTextMarkerCreate(nil, &end, 1))
        }
        func withMarker(_ start: UInt8 = 1, _ end: UInt8 = 3) {
            removeText(); set(1, kAXRoleAttribute, "AXWebArea" as CFString)
            set(1, WebSelectionAttributes.selectedMarkerRange, Self.marker(start, end))
        }
        func string(for marker: AXTextMarkerRange, of element: AXUIElement, timeout: Float) -> NativeAXReply {
            let index = nodes.firstIndex { CFEqual($0, element) }!
            requests.append((index, WebSelectionAttributes.stringForMarkerRange, timeout))
            markerParameters.append(marker); onMarkerParameter?()
            return markerReply
        }
        func set(_ node: Int, _ name: String, _ value: CFTypeRef) { replies[node, default: [:]][name] = (.success, value) }
        func removeText() { replies[1]?[kAXSelectedTextAttribute] = nil }
        func setRange(_ location: Int, _ length: Int) {
            var range = CFRange(location: location, length: length)
            set(1, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &range)!)
        }
        func selectionAtDepth(_ depth: Int) {
            removeText()
            for index in 1...depth { set(index, kAXParentAttribute, nodes[index + 1]) }
            set(depth + 1, kAXSelectedTextAttribute, Self.text as CFString)
        }
        func withWindow() {
            set(0, kAXFocusedWindowAttribute, nodes[5])
            set(5, kAXTitleAttribute, "synthetic title" as CFString)
            set(5, kAXDocumentAttribute, "https://synthetic.invalid/document" as CFString)
        }
        func isRunning(_ pid: pid_t) -> Bool { pid == Self.pid && running }
        func bundleIdentifier(_ pid: pid_t) -> String? { bundle }
        func application(_ pid: pid_t) -> AXUIElement { nodes[0] }
        func attribute(_ name: String, of element: AXUIElement, timeout: Float) -> NativeAXReply {
            let index = nodes.firstIndex { CFEqual($0, element) }!
            requests.append((index, name, timeout))
            onAttribute?(index, name)
            return replies[index]?[name] ?? (.attributeUnsupported, nil)
        }
        func string(for range: CFRange, of element: AXUIElement, timeout: Float) -> NativeAXReply {
            let index = nodes.firstIndex { CFEqual($0, element) }!
            requests.append((index, kAXStringForRangeParameterizedAttribute, timeout))
            parameters.append(range); onParameter?()
            return parameterReply
        }
        var isBounded: Bool {
            let allowed = [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute, kAXDocumentAttribute,
                           kAXTitleAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXSelectedTextRangeAttribute,
                           kAXSelectedTextAttribute, kAXParentAttribute, kAXStringForRangeParameterizedAttribute,
                           WebSelectionAttributes.selectedMarkerRange, WebSelectionAttributes.stringForMarkerRange]
            return requests.allSatisfy { allowed.contains($0.name) && $0.timeout > 0 && $0.timeout <= 0.151 }
        }
    }
}
