import Foundation
import CryptoKit

/// 所有预览、复制、打开、导出均校验同一个不可变附件边界。
public enum AttachmentAccess {
    public enum Failure: Error { case invalidReference, unsafePath, integrity }
    /// Recycled notes can share an asset with an active note. Prefer their
    /// recycled asset when present; never fall back past a corrupt existing file.
    public static func readDeleted(library: URL, relativePath: String) throws -> Data {
        guard MarkdownFormat.validAttachment(relativePath) else { throw Failure.invalidReference }
        let recycled = library.appendingPathComponent(".trash/Attachments").appendingPathComponent(URL(fileURLWithPath: relativePath).lastPathComponent)
        let noteURL = FileManager.default.fileExists(atPath: recycled.path)
            ? library.appendingPathComponent(".trash/Notes/deleted.md")
            : library.appendingPathComponent("Notes/restored.md")
        return try read(noteURL: noteURL, relativePath: relativePath)
    }
    public static func read(noteURL: URL, relativePath: String) throws -> Data {
        guard MarkdownFormat.validAttachment(relativePath) else { throw Failure.invalidReference }
        var notes = noteURL.standardizedFileURL.deletingLastPathComponent()
        while notes.lastPathComponent != "Notes" && notes.path != "/" { notes.deleteLastPathComponent() }
        guard notes.lastPathComponent == "Notes" else { throw Failure.unsafePath }
        let library = notes.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = noteURL.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL
        let expected = library.appendingPathComponent("Attachments").appendingPathComponent(target.lastPathComponent)
        guard target.resolvingSymlinksInPath().path == expected.path,
              expected.resolvingSymlinksInPath().path == expected.path,
              try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isRegularFile == true,
              try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.unsafePath }
        let bytes = try Data(contentsOf: target)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == String(target.lastPathComponent.prefix(64)) else { throw Failure.integrity }
        return bytes
    }
}
