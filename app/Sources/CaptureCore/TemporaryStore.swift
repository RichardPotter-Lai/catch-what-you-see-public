import Foundation
import CryptoKit
import ImageIO
import Darwin

/// 临时图片保留至显式清理；容量、时间、退出不参与删除策略。
public final class TemporaryStore {
    public struct Item: Codable, Identifiable, Equatable {
        public let id: UUID
        public let operationID: UUID
        public let noteID: UUID
        public let createdAt: String
        public let sourceKey: String
        public let filename: String
        public let hash: String
        public var saved: Bool
    }
    public enum Failure: Error { case incompleteImage, unsafePath, referenced, unknownReferences, missing }
    public let root: URL
    private let folder: URL
    private let fm = FileManager.default
    private let afterSave: () throws -> Void
    public init(root: URL, afterSave: @escaping () throws -> Void = {}) throws {
        self.afterSave = afterSave
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        folder = self.root.appendingPathComponent(".temporary")
        guard folder.resolvingSymlinksInPath().path == folder.path else { throw Failure.unsafePath }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard folder.resolvingSymlinksInPath().path == folder.path else { throw Failure.unsafePath }
        let fd = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafePath }; defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.unsafePath }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func records() throws -> [Item] {
        let result = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
            guard try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  $0.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path else { throw Failure.unsafePath }
            let item = try JSONDecoder().decode(Item.self, from: Data(contentsOf: $0))
            guard $0.lastPathComponent == item.id.uuidString + ".json",
                  item.filename.hasPrefix(item.id.uuidString + "."),
                  item.filename == URL(fileURLWithPath: item.filename).lastPathComponent,
                  item.hash.count == 64, item.hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure.unsafePath }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
        guard Set(result.map(\.id)).count == result.count,
              Set(result.map(\.operationID)).count == result.count,
              Set(result.map(\.noteID)).count == result.count else { throw Failure.unsafePath }
        return result
    }
    public func items() throws -> [Item] { try locked { try records() } }
    private func record(_ item: Item) throws {
        let target = folder.appendingPathComponent(item.id.uuidString + ".json")
        guard target.resolvingSymlinksInPath().path == target.path else { throw Failure.unsafePath }
        try JSONEncoder().encode(item).write(to: target, options: .atomic)
        let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
        try handle.synchronize()
        let fd = open(folder.path, O_RDONLY); guard fd >= 0 else { throw Failure.unsafePath }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.unsafePath }
    }
    public func url(for item: Item) throws -> URL {
        guard item.filename.hasPrefix(item.id.uuidString + "."), item.filename == URL(fileURLWithPath: item.filename).lastPathComponent else { throw Failure.unsafePath }
        let url = folder.appendingPathComponent(item.filename)
        guard url.resolvingSymlinksInPath().path == url.path else { throw Failure.unsafePath }
        return url
    }
    public func ingest(_ source: URL) throws -> Item {
        try locked {
            let data = try Data(contentsOf: source)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(image) == .statusComplete,
                  CGImageSourceGetCount(image) > 0,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
                  data == (try Data(contentsOf: source)) else { throw Failure.incompleteImage }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sourceKey = source.standardizedFileURL.resolvingSymlinksInPath().path + ":" + hash
            if let prior = try records().first(where: { $0.sourceKey == sourceKey }) { return prior }
            let id = UUID()
            let item = Item(id: id, operationID: UUID(), noteID: UUID(), createdAt: ISO8601DateFormatter().string(from: Date()), sourceKey: sourceKey, filename: id.uuidString + "." + source.pathExtension.lowercased(), hash: hash, saved: false)
            let destination = try url(for: item)
            try data.write(to: destination, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: destination)
            do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
            // 图片先落盘；中断时至多留下无主副本，绝不删除外部来源。
            try record(item)
            return item
        }
    }
    public func collect(_ id: UUID) throws -> MarkdownStore.Saved {
        try locked {
            guard var item = try records().first(where: { $0.id == id }) else { throw Failure.missing }
            let source = try url(for: item)
            guard SHA256.hash(data: try Data(contentsOf: source)).map({ String(format: "%02x", $0) }).joined() == item.hash else { throw Failure.incompleteImage }
            let note = MarkdownNote(id: item.noteID, operationID: item.operationID, createdAt: item.createdAt, title: "截图收藏", excerpt: "")
            let result = try MarkdownStore(root: root).save(note, imageSource: url(for: item))
            guard result.note.id == item.noteID, result.note.operationID == item.operationID,
                  result.note.attachment?.contains(item.hash) == true else { throw Failure.unknownReferences }
            _ = try AttachmentAccess.read(noteURL: result.url, relativePath: result.note.attachment!)
            try afterSave()
            item.saved = true
            try record(item)
            return result
        }
    }
    public func clean(_ id: UUID, managedSourceDirectory: URL? = nil, deleteScreenshotOriginals: Bool = false, trash: (URL) throws -> Void) throws {
        try locked {
            guard let item = try records().first(where: { $0.id == id }) else { throw Failure.missing }
            var verifiedPermanentCopy = false
            for library in [root, root.appendingPathComponent(".trash")] {
                let index = LibraryIndex(root: library); try index.refresh()
                guard index.entries.allSatisfy({ $0.state == .ready }) else { throw Failure.unknownReferences }
                for entry in index.entries where entry.note?.attachment?.contains(item.hash) == true || entry.note?.operationID == item.operationID {
                    guard let note = entry.note, let path = note.attachment else { throw Failure.unknownReferences }
                    let bytes = try library == root
                        ? AttachmentAccess.read(noteURL: entry.url, relativePath: path)
                        : AttachmentAccess.readDeleted(library: root, relativePath: path)
                    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.hash else { throw Failure.unknownReferences }
                    verifiedPermanentCopy = true
                }
            }
            guard !item.saved || verifiedPermanentCopy else { throw Failure.unknownReferences }
            guard try MarkdownStore(root: root).pendingOperations().isEmpty else { throw Failure.unknownReferences }
            let asset = try url(for: item)
            guard SHA256.hash(data: try Data(contentsOf: asset)).map({ String(format: "%02x", $0) }).joined() == item.hash else { throw Failure.unknownReferences }
            // 明确删除截图时，截图原件一并移入废纸篓，而不只是删除库内副本：
            // - 应用自己的截图收件箱（“接管截图”开启时）中的原件；
            // - 带有 macOS 截图标记（kMDItemIsScreenCapture）的原件，例如桌面上的“截屏…png”。
            // 手动挂上的外部图片、已被修改的原件、符号链接和其他记录引用的原件保持不动。
            if item.sourceKey.hasSuffix(":" + item.hash) {
                let source = URL(fileURLWithPath: String(item.sourceKey.dropLast(item.hash.count + 1)))
                var inInbox = false
                // 收件箱目录只在开启“接管截图”后才存在；不存在时不能阻止删除。
                if let directory = managedSourceDirectory, fm.fileExists(atPath: directory.path) {
                    var component = directory.standardizedFileURL
                    while component.path != "/" {
                        let link = try component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
                        guard !link || ["/var", "/tmp", "/etc"].contains(component.path) else { throw Failure.unsafePath }
                        component.deleteLastPathComponent()
                    }
                    inInbox = source.deletingLastPathComponent() == directory.standardizedFileURL.resolvingSymlinksInPath()
                }
                let isSystemScreenshot = deleteScreenshotOriginals
                    && getxattr(source.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) >= 0
                if inInbox || isSystemScreenshot,
                   source.resolvingSymlinksInPath() == source,
                   source != asset, fm.fileExists(atPath: source.path),
                   !(try records()).contains(where: { $0.id != id && $0.sourceKey == item.sourceKey }) {
                    let unchanged = SHA256.hash(data: try Data(contentsOf: source)).map({ String(format: "%02x", $0) }).joined() == item.hash
                    if unchanged { try trash(source) }
                    else if inInbox { throw Failure.unknownReferences }
                    // 桌面截图原件被改过：保留原件，只删除库内副本。
                }
            }
            try trash(asset)
            try fm.removeItem(at: folder.appendingPathComponent(item.id.uuidString + ".json"))
        }
    }
}
