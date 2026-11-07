import Foundation
import Darwin
import CryptoKit
import ImageIO

public final class MarkdownStore {
    public enum FaultPoint: String, CaseIterable {
        case beforeDraft, afterDraft, beforeAttachment, afterAttachment
        case beforeCommit, afterCommit, beforeIndex, afterIndex
    }
    public enum Failure: Error {
        case deleted, conflict, unreadableDocuments, unsafePath, inputUnavailable, attachmentIntegrity
        case injected(FaultPoint)
    }
    public struct Saved {
        public let url: URL
        public let note: MarkdownNote
        public let reused: Bool
        public let indexRebuilt: Bool
    }
    private let root: URL
    private let notes: URL
    private let pending: URL
    private let attachments: URL
    private let lockFile: URL
    private let fault: (FaultPoint) throws -> Void
    private let fm = FileManager.default

    public init(root: URL, fault: @escaping (FaultPoint) throws -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.notes = self.root.appendingPathComponent("Notes", isDirectory: true)
        self.pending = self.root.appendingPathComponent(".pending", isDirectory: true)
        self.attachments = self.root.appendingPathComponent("Attachments", isDirectory: true)
        self.lockFile = self.root.appendingPathComponent(".cwsy-write.lock")
        self.fault = fault
        for directory in [notes, pending, attachments] {
            try checkPath(directory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try checkPath(lockFile)
    }

    private func checkPath(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path == url.standardizedFileURL.path,
              (resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")) else { throw Failure.unsafePath }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try checkPath(lockFile)
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func draftURL(_ id: UUID) -> URL { pending.appendingPathComponent(id.uuidString.lowercased() + ".md") }

    /// 原子、不覆盖提交；成功返回前刷新内容与目录项。staging 绝不作为收藏展示。
    private func commit(_ data: Data, to destination: URL, replace: Bool = false) throws {
        try checkPath(destination.deletingLastPathComponent())
        try checkPath(destination)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".staging-" + UUID().uuidString)
        try data.write(to: staging, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        let result = replace ? rename(staging.path, destination.path) : link(staging.path, destination.path)
        guard result == 0 else {
            if errno == EEXIST { throw Failure.conflict }; throw posixError()
        }
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw posixError() }
    }
    private func documents() throws -> [(URL, MarkdownNote)] {
        try checkPath(notes)
        var result: [(URL, MarkdownNote)] = [], ids = Set<UUID>(), operations = Set<UUID>()
        guard let enumeration = fm.enumerator(at: notes, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { throw Failure.unreadableDocuments }
        while let entry = enumeration.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw Failure.unsafePath }
            if values.isDirectory == true || entry.pathExtension.lowercased() != "md" { continue }
            let url = entry.resolvingSymlinksInPath()
            try checkPath(url)
            guard let note = try? MarkdownFormat.decode(Data(contentsOf: url)) else { throw Failure.unreadableDocuments }
            guard ids.insert(note.id).inserted, operations.insert(note.operationID).inserted else { throw Failure.conflict }
            result.append((url, note))
        }
        return result
    }
    private func readDraft(_ operation: UUID) throws -> (MarkdownNote, URL?) {
        let url = draftURL(operation)
        try checkPath(url)
        guard let bytes = try? Data(contentsOf: url), let file = String(data: bytes, encoding: .utf8),
              let firstEnd = file.firstIndex(of: "\n") else { throw Failure.inputUnavailable }
        let remainder = String(file[file.index(after: firstEnd)...])
        guard String(file[..<firstEnd]) == "<!-- cwsy-pending sha256=\(digest(Data(remainder.utf8))) -->",
              let sourceEnd = remainder.firstIndex(of: "\n") else { throw Failure.inputUnavailable }
        let sourceLine = String(remainder[..<sourceEnd])
        guard sourceLine.hasPrefix("<!-- source="), sourceLine.hasSuffix(" -->") else { throw Failure.inputUnavailable }
        let encoded = String(sourceLine.dropFirst(12).dropLast(4))
        guard let sourceBytes = Data(base64Encoded: encoded), let sourcePath = String(data: sourceBytes, encoding: .utf8) else { throw Failure.inputUnavailable }
        let markdown = Data(remainder[remainder.index(after: sourceEnd)...].utf8)
        guard let note = try? MarkdownFormat.decode(markdown), note.operationID == operation else { throw Failure.inputUnavailable }
        return (note, sourcePath.isEmpty ? nil : URL(fileURLWithPath: sourcePath))
    }
    private func writeDraft(_ note: MarkdownNote, source: URL?) throws {
        let sourceLine = "<!-- source=\(Data((source?.path ?? "").utf8).base64EncodedString()) -->\n"
        let markdown = String(decoding: try MarkdownFormat.encode(note), as: UTF8.self)
        let remainder = sourceLine + markdown
        let header = "<!-- cwsy-pending sha256=\(digest(Data(remainder.utf8))) -->\n"
        try commit(Data((header + remainder).utf8), to: draftURL(note.operationID))
    }
    public func save(_ input: MarkdownNote, imageSource: URL? = nil) throws -> Saved {
        try locked {
            let existing = try documents()
            try rejectDeleted(input.operationID)
            if let (url, note) = existing.first(where: { $0.1.operationID == input.operationID }) {
                return try finish(url: url, note: note, reused: true)
            }
            guard !existing.contains(where: { $0.1.id == input.id }) else { throw Failure.conflict }
            if fm.fileExists(atPath: draftURL(input.operationID).path) {
                let (note, source) = try readDraft(input.operationID)
                return try submit(note, source: source)
            }
            try fault(.beforeDraft)
            var note = input
            if let source = imageSource {
                let data = try Data(contentsOf: source)
                // 只识别编码格式，不识别图片文字；同字节采用同一个规范扩展名。
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(image) as String?,
                      let ext = ["public.png": "png", "public.jpeg": "jpg", "com.compuserve.gif": "gif",
                                 "public.tiff": "tiff", "public.heic": "heic", "org.webmproject.webp": "webp",
                                 "com.microsoft.bmp": "bmp"][type] else { throw Failure.attachmentIntegrity }
                note.attachment = "../Attachments/\(digest(data)).\(ext)"
            } else if note.attachment != nil { throw Failure.inputUnavailable }
            _ = try MarkdownFormat.decode(MarkdownFormat.encode(note))
            try writeDraft(note, source: imageSource)
            try fault(.afterDraft)
            return try submit(note, source: imageSource)
        }
    }
    private func submit(_ note: MarkdownNote, source: URL?) throws -> Saved {
        // 先复核身份，防止中断期间另一条笔记占用同 ID。
        let existing = try documents()
        if let (url, prior) = existing.first(where: { $0.1.operationID == note.operationID }) {
            return try finish(url: url, note: prior, reused: true)
        }
        guard !existing.contains(where: { $0.1.id == note.id }) else { throw Failure.conflict }
        try fault(.beforeAttachment)
        if let path = note.attachment {
            guard MarkdownFormat.validAttachment(path) else { throw Failure.attachmentIntegrity }
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let asset = attachments.appendingPathComponent(filename)
            try checkPath(asset)
            let expected = String(filename.prefix(64))
            if fm.fileExists(atPath: asset.path) {
                guard digest(try Data(contentsOf: asset)) == expected else { throw Failure.attachmentIntegrity }
            } else {
                guard let source, let data = try? Data(contentsOf: source) else { throw Failure.inputUnavailable }
                guard digest(data) == expected else { throw Failure.attachmentIntegrity }
                try commit(data, to: asset)
            }
        }
        try fault(.afterAttachment)
        try fault(.beforeCommit)
        let name = String(note.createdAt.prefix(10)) + "_" + note.id.uuidString.lowercased() + ".md"
        let url = notes.appendingPathComponent(name)
        try commit(MarkdownFormat.encode(note), to: url)
        try fault(.afterCommit)
        return try finish(url: url, note: note, reused: false)
    }
    private func finish(url: URL, note: MarkdownNote, reused: Bool) throws -> Saved {
        try fault(.beforeIndex)
        // 目录是派生物，目录失败不把已经落盘的笔记报告为丢失。
        let indexed: Bool
        do { try rebuildIndexLocked(); indexed = true } catch { indexed = false }
        try fault(.afterIndex)
        let draft = draftURL(note.operationID)
        try checkPath(draft)
        if fm.fileExists(atPath: draft.path) { try? fm.removeItem(at: draft) }
        return Saved(url: url, note: note, reused: reused, indexRebuilt: indexed)
    }
    public func resume(operationID: UUID) throws -> Saved {
        try locked {
            try rejectDeleted(operationID)
            if let (url, note) = try documents().first(where: { $0.1.operationID == operationID }) {
                return try finish(url: url, note: note, reused: true)
            }
            let (note, source) = try readDraft(operationID)
            return try submit(note, source: source)
        }
    }
    public func pendingOperations() throws -> [UUID] {
        try locked {
            try checkPath(pending)
            return try fm.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        }
    }
    // 明确删除时，最后一条活动引用的托管附件随 MD 进入回收站；从不自动清空。
    private var trashRoot: URL { root.appendingPathComponent(".trash", isDirectory: true) }
    private func deletedView() throws -> LibraryIndex {
        try checkPath(trashRoot)
        let view = LibraryIndex(root: trashRoot)
        try view.refresh()
        return view
    }
    private func rejectDeleted(_ operation: UUID) throws {
        let entries = try deletedView().entries
        guard !entries.contains(where: { $0.note == nil }) else { throw Failure.unreadableDocuments }
        if entries.contains(where: { $0.note?.operationID == operation }) { throw Failure.deleted }
    }
    public func deletedNotes() throws -> [LibraryIndex.Entry] {
        try locked { try deletedView().entries }
    }
    @discardableResult public func trash(_ entry: LibraryIndex.Entry) throws -> LibraryIndex.Entry {
        try locked {
            try checkPath(entry.url)
            guard entry.url.path.hasPrefix(notes.path + "/"), entry.state == .ready else { throw Failure.conflict }
            let view = LibraryIndex(root: root, includeHidden: true, strictPaths: true)
            try view.refresh()
            guard view.entries.contains(where: { $0.url == entry.url && $0.state == .ready }) else { throw Failure.conflict }
            try view.requireUnchanged(entry)
            try checkPath(trashRoot)
            let folder = trashRoot.appendingPathComponent("Notes", isDirectory: true)
            try checkPath(folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var attachmentMove: (source: URL, target: URL)?
            if let path = entry.note?.attachment {
                // Unknown documents or unfinished writes may still reference this asset.
                guard view.entries.allSatisfy({ $0.state == .ready }) else { throw Failure.unreadableDocuments }
                try checkPath(pending)
                guard try !fm.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "md" }) else { throw Failure.conflict }
                let filename = URL(fileURLWithPath: path).lastPathComponent
                let shared = view.entries.contains { $0.url != entry.url && $0.rawText.contains(filename) }
                if !shared {
                    _ = try AttachmentAccess.read(noteURL: entry.url, relativePath: path)
                    let source = attachments.appendingPathComponent(filename)
                    let recycleAssets = trashRoot.appendingPathComponent("Attachments", isDirectory: true)
                    try checkPath(recycleAssets)
                    try fm.createDirectory(at: recycleAssets, withIntermediateDirectories: true)
                    var destination = recycleAssets.appendingPathComponent(filename)
                    if fm.fileExists(atPath: destination.path) {
                        // A newer independent collection can recreate an already recycled asset.
                        _ = try AttachmentAccess.read(noteURL: trashRoot.appendingPathComponent("Notes/deleted.md"), relativePath: path)
                        let duplicates = trashRoot.appendingPathComponent("DuplicateAttachments", isDirectory: true)
                        try checkPath(duplicates); try fm.createDirectory(at: duplicates, withIntermediateDirectories: true)
                        destination = duplicates.appendingPathComponent(UUID().uuidString + "_" + filename)
                    }
                    attachmentMove = (source, destination)
                }
            }
            let target = folder.appendingPathComponent(UUID().uuidString.lowercased() + ".md")
            try view.requireUnchanged(entry)
            try moveDocument(entry.url, to: target)
            do {
                if let move = attachmentMove { try moveDocument(move.source, to: move.target) }
            } catch {
                // If a move/fsync fails, restore the active note and asset where possible.
                // A crash between moves leaves recoverable bytes, never an erased image.
                if let move = attachmentMove, !fm.fileExists(atPath: move.source.path), fm.fileExists(atPath: move.target.path) {
                    try? moveDocument(move.target, to: move.source)
                }
                try? moveDocument(target, to: entry.url)
                throw error
            }
            try? rebuildIndexLocked()
            guard let moved = try deletedView().entries.first(where: { $0.url == target }) else { throw Failure.unreadableDocuments }
            return moved
        }
    }
    @discardableResult public func restore(_ entry: LibraryIndex.Entry) throws -> URL {
        try locked {
            try checkPath(entry.url)
            guard entry.url.path.hasPrefix(trashRoot.appendingPathComponent("Notes").path + "/"),
                  entry.state == .ready, let note = entry.note else { throw Failure.conflict }
            let view = try deletedView()
            try view.requireUnchanged(entry)
            guard view.entries.contains(where: { $0.url == entry.url && $0.state == .ready }) else { throw Failure.conflict }
            let active = try documents()
            guard !active.contains(where: { $0.1.id == note.id || $0.1.operationID == note.operationID }) else { throw Failure.conflict }
            if let path = note.attachment {
                let asset = attachments.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                if fm.fileExists(atPath: asset.path) {
                    _ = try AttachmentAccess.read(noteURL: notes.appendingPathComponent("restored.md"), relativePath: path)
                } else {
                    _ = try AttachmentAccess.read(noteURL: entry.url, relativePath: path)
                    let recycled = trashRoot.appendingPathComponent("Attachments").appendingPathComponent(asset.lastPathComponent)
                    try moveDocument(recycled, to: asset)
                }
            }
            let target = notes.appendingPathComponent(String(note.createdAt.prefix(10)) + "_" + note.id.uuidString.lowercased() + ".md")
            try moveDocument(entry.url, to: target)
            try? rebuildIndexLocked()
            return target
        }
    }
    private func moveDocument(_ source: URL, to target: URL) throws {
        try checkPath(source); try checkPath(target)
        // 同卷原子移动且不覆盖；崩溃时文档位于源或目标，不存在复制后删除窗口。
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Failure.conflict }; throw posixError()
        }
        for folder in [source.deletingLastPathComponent(), target.deletingLastPathComponent()] {
            let fd = open(folder.path, O_RDONLY)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw posixError() }
        }
    }
    public func rebuildIndex() throws { try locked { try rebuildIndexLocked() } }
    private func rebuildIndexLocked() throws {
        let view = LibraryIndex(root: root)
        try view.refresh()
        let safe = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()<>"))
        let lines = view.entries.map { entry in
            let title = entry.note?.title ?? entry.url.lastPathComponent
            let label = MarkdownFormat.escapeTitle(title) + (entry.state == .ready ? "" : "（待检查）")
            let path = String(entry.url.path.dropFirst(notes.path.count + 1)).addingPercentEncoding(withAllowedCharacters: safe)!
            return "- [\(label)](Notes/\(path))"
        }
        try commit(Data(("# 收藏总目录\n\n" + lines.joined(separator: "\n") + "\n").utf8), to: root.appendingPathComponent("INDEX.md"), replace: true)
    }
}
