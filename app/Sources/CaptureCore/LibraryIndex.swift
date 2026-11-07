import Foundation
import CryptoKit

/// 文件的可重建只读视图；不向 MD 回写任何缓存或修复结果。
public final class LibraryIndex {
    public enum State: String { case ready, readOnly, unstable, identityConflict, missing }
    public enum Failure: Error { case changed, unsafeRoot }
    public struct Entry: Identifiable, Equatable {
        public var id: String { url.path }
        public let url: URL
        public let note: MarkdownNote?
        public let rawText: String
        public let fingerprint: String
        public var state: State
    }
    public private(set) var entries: [Entry] = []
    public let root: URL
    private let includeHidden: Bool
    private let strictPaths: Bool
    private let afterRead: (URL) throws -> Void
    private let fm = FileManager.default
    public init(root: URL, includeHidden: Bool = false, strictPaths: Bool = false, afterRead: @escaping (URL) throws -> Void = { _ in }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.afterRead = afterRead
        self.includeHidden = includeHidden; self.strictPaths = strictPaths
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func refresh() throws {
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        guard folder.resolvingSymlinksInPath().path == folder.path else { throw Failure.unsafeRoot }
        guard fm.fileExists(atPath: folder.path) else { entries = []; return }
        var enumerationFailed = false
        guard let enumeration = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: includeHidden ? [] : [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.unsafeRoot }
        var result: [Entry] = []
        while let entry = enumeration.nextObject() as? URL {
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if strictPaths && (values == nil || values?.isSymbolicLink == true) { throw Failure.unsafeRoot }
            if values?.isSymbolicLink == true { enumeration.skipDescendants(); continue }
            if values?.isDirectory == true || entry.pathExtension.lowercased() != "md" { continue }
            let url = entry.resolvingSymlinksInPath()
            guard url.path.hasPrefix(folder.path + "/") else { continue }
            guard let before = try? Data(contentsOf: url) else {
                result.append(Entry(url: url, note: nil, rawText: "", fingerprint: "", state: .missing)); continue
            }
            try afterRead(url)
            guard let after = try? Data(contentsOf: url), before == after else {
                result.append(Entry(url: url, note: nil, rawText: "", fingerprint: "", state: .unstable)); continue
            }
            let raw = String(data: before, encoding: .utf8) ?? "无法读取为 UTF-8，请打开原文件查看。"
            let note = try? MarkdownFormat.decode(before)
            result.append(Entry(url: url, note: note, rawText: raw, fingerprint: hash(before), state: note == nil ? .readOnly : .ready))
        }
        if strictPaths && enumerationFailed { throw Failure.unsafeRoot }
        let ids = Dictionary(grouping: result.compactMap(\.note), by: \.id).mapValues(\.count)
        let operations = Dictionary(grouping: result.compactMap(\.note), by: \.operationID).mapValues(\.count)
        for i in result.indices {
            if let note = result[i].note, (ids[note.id] ?? 0) > 1 || (operations[note.operationID] ?? 0) > 1 { result[i].state = .identityConflict }
        }
        entries = result.sorted { lhs, rhs in
            let left = lhs.note?.createdAt ?? "", right = rhs.note?.createdAt ?? ""
            return left == right ? lhs.url.path < rhs.url.path : left > right
        }
    }
    public func search(_ query: String) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            let text: String
            if let note = entry.note {
                text = [note.title, note.excerpt, note.notes, note.sourceApp, note.sourceTitle, note.sourceURL].joined(separator: "\n")
            } else { text = entry.rawText }
            return text.range(of: query, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }
    /// 修改/删除等后续显式动作必须先检查版本；缓存本身没有文档写入口。
    public func requireUnchanged(_ entry: Entry) throws {
        guard !entry.fingerprint.isEmpty,
              (try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: entry.url), hash(data) == entry.fingerprint else { throw Failure.changed }
    }
}
