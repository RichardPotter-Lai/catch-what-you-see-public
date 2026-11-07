import Foundation

public enum CopySelectionFailure: Error, Equatable {
    case unavailable, clipboardChanged, protectedClipboard, unsupportedClipboard
    case noFreshText, keysStillHeld
}

public enum ClipboardRestoration: Equatable {
    case restored, newerContentPreserved, failed
}

/// A short-lived in-memory snapshot, never a clipboard history or a log payload.
public struct CopyClipboardSnapshot: Equatable {
    public let changeCount: Int
    public let items: [[String: Data]]
    public let text: String?
    public let protected: Bool
    public init(changeCount: Int, items: [[String: Data]], text: String?, protected: Bool = false) {
        self.changeCount = changeCount; self.items = items; self.text = text; self.protected = protected
    }
}

public protocol CopySelectionAccess {
    var now: Date { get }
    var changeCount: Int { get }
    var triggeringKeysReleased: Bool { get }
    var sourceID: String { get }
    func validateSource() throws
    func snapshot() throws -> CopyClipboardSnapshot
    func copiedText() throws -> CopyClipboardSnapshot
    func requestCopy() throws
    func restore(_ original: CopyClipboardSnapshot, ifUnchanged version: Int) -> ClipboardRestoration
    func waitBriefly()
}

public extension CopySelectionAccess {
    func copiedText() throws -> CopyClipboardSnapshot { try snapshot() }
}

public struct SelectionCapture {
    private let direct: () throws -> SelectionSnapshot
    private let copy: () throws -> SelectionSnapshot
    public init(direct: @escaping () throws -> SelectionSnapshot, copy: @escaping () throws -> SelectionSnapshot) {
        self.direct = direct; self.copy = copy
    }
    public func read(allowCopyFallback: Bool = true) throws -> SelectionSnapshot {
        do { return try direct() }
        catch {
            guard allowCopyFallback, let failure = error as? SelectionFailure,
                  [.unsupportedSelection, .emptySelection, .timeout].contains(failure) else { throw error }
            return try copy()
        }
    }
}

/// One explicitly requested copy transaction. It never reads an unchanged old
/// clipboard as a selection, and never rolls back a later clipboard version.
public struct CopySelectionTransaction {
    private let access: CopySelectionAccess
    public init(access: CopySelectionAccess) { self.access = access }

    public func read(timeout: TimeInterval = 1.2, releaseTimeout: TimeInterval = 1.5) throws -> SelectionSnapshot {
        guard timeout.isFinite, timeout > 0, releaseTimeout.isFinite, releaseTimeout > 0 else {
            throw CopySelectionFailure.unavailable
        }
        try access.validateSource()
        let releaseDeadline = access.now.addingTimeInterval(releaseTimeout)
        while !access.triggeringKeysReleased {
            try access.validateSource()
            guard access.now < releaseDeadline else { throw CopySelectionFailure.keysStillHeld }
            access.waitBriefly()
        }
        try access.validateSource()
        let original = try access.snapshot()
        guard !original.protected else { throw CopySelectionFailure.protectedClipboard }
        guard access.changeCount == original.changeCount else { throw CopySelectionFailure.clipboardChanged }
        try access.validateSource()
        try access.requestCopy()
        let deadline = access.now.addingTimeInterval(timeout)
        var copiedVersion: Int?
        var restorationAttempted = false
        defer {
            if !restorationAttempted, let copiedVersion {
                _ = access.restore(original, ifUnchanged: copiedVersion)
            }
        }
        while access.now < deadline {
            try access.validateSource()
            guard access.now < deadline else { throw CopySelectionFailure.noFreshText }
            let version = access.changeCount
            if version != original.changeCount {
                copiedVersion = version
                let fresh = try access.copiedText()
                guard fresh.changeCount == version, access.changeCount == version else {
                    throw CopySelectionFailure.clipboardChanged
                }
                guard !fresh.protected else { throw CopySelectionFailure.protectedClipboard }
                guard let text = fresh.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CopySelectionFailure.noFreshText
                }
                // A short stable window detects a second write or a delayed focus
                // change before accepting the copied payload.
                access.waitBriefly()
                try access.validateSource()
                guard access.now < deadline else { throw CopySelectionFailure.noFreshText }
                guard access.changeCount == version else { throw CopySelectionFailure.clipboardChanged }
                let restoration = access.restore(original, ifUnchanged: version)
                restorationAttempted = true
                return SelectionSnapshot(text: text, sourceID: access.sourceID,
                                         clipboardRestoration: restoration)
            }
            access.waitBriefly()
        }
        throw CopySelectionFailure.noFreshText
    }
}
