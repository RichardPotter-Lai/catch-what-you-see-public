import Foundation

/// 每项只还原本次写入且当前仍保持的值；收据在第一次写入前持久化。
public final class PreferenceLease {
    public enum Value: Codable, Equatable { case string(String), bool(Bool) }
    public struct Change: Codable { let key: String; let before: Value?; let after: Value }
    public enum Failure: Error { case ownerRunning, writeFailed, receiptExists }
    private let read: (String) -> Value?
    private let write: (String, Value?) throws -> Void
    private let load: () throws -> Data?
    private let persist: (Data?) throws -> Void
    public init(read: @escaping (String) -> Value?, write: @escaping (String, Value?) throws -> Void,
                load: @escaping () throws -> Data?, persist: @escaping (Data?) throws -> Void) {
        self.read = read; self.write = write; self.load = load; self.persist = persist
    }
    public func acquire(_ desired: [String: Value], otherOwnerRunning: Bool) throws {
        guard !otherOwnerRunning else { throw Failure.ownerRunning }
        guard try load() == nil else { throw Failure.receiptExists }
        let changes = desired.keys.sorted().map { Change(key: $0, before: read($0), after: desired[$0]!) }
        try persist(JSONEncoder().encode(changes))
        do {
            for change in changes {
                try write(change.key, change.after)
                guard read(change.key) == change.after else { throw Failure.writeFailed }
            }
        } catch { try? release(); throw error }
    }
    public func release() throws {
        guard let data = try load() else { return }
        let changes = try JSONDecoder().decode([Change].self, from: data)
        for change in changes where read(change.key) == change.after {
            try write(change.key, change.before)
            guard read(change.key) == change.before else { throw Failure.writeFailed }
        }
        try persist(nil)
    }
}
