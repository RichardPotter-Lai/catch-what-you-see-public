import Foundation

public enum SelectionFailure: Error, Equatable {
    case permissionRequired, emptySelection, secureInput, unsupportedSelection
    case sourceChanged, timeout, sourceExited
}

public struct SelectionSnapshot: Equatable {
    public let text: String
    public let sourceID: String
    public let document: String?
    public let range: String?
    public let contextToken: String?
    public let clipboardRestoration: ClipboardRestoration?
    public init(text: String, sourceID: String, document: String? = nil, range: String? = nil, contextToken: String? = nil,
                clipboardRestoration: ClipboardRestoration? = nil) {
        self.text = text; self.sourceID = sourceID; self.document = document; self.range = range; self.contextToken = contextToken
        self.clipboardRestoration = clipboardRestoration
    }
}

/// 每次适配器调用必须遵守传入的截止时间；原生实现为每个 AX 请求设置剩余超时。
public protocol SelectionSource {
    func read(deadline: Date) throws -> SelectionSnapshot
}

public struct SelectionReader {
    private let source: SelectionSource
    private let clock: CaptureClock
    public init(source: SelectionSource, clock: CaptureClock = CaptureClock()) {
        self.source = source; self.clock = clock
    }
    public func read(timeout: TimeInterval = 1) throws -> SelectionSnapshot {
        let deadline = clock.now().addingTimeInterval(timeout)
        guard timeout.isFinite, timeout > 0, clock.now() < deadline else { throw SelectionFailure.timeout }
        let first = try source.read(deadline: deadline)
        guard clock.now() < deadline else { throw SelectionFailure.timeout }
        guard !first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionFailure.emptySelection
        }
        let second = try source.read(deadline: deadline)
        guard clock.now() < deadline else { throw SelectionFailure.timeout }
        guard first == second else { throw SelectionFailure.sourceChanged }
        return first
    }
}
