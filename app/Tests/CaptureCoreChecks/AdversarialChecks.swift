import Foundation
import CaptureCore

func checkAdversarial(_ root: URL) throws {
    let fm = FileManager.default
    let library = root.appendingPathComponent("attack-temporary")
    let store = try TemporaryStore(root: library)
    let external = root.appendingPathComponent("outside-sentinel")
    try fm.createDirectory(at: external, withIntermediateDirectories: true)
    let temp = library.appendingPathComponent(".temporary")
    try fm.moveItem(at: temp, to: library.appendingPathComponent("original-temporary"))
    try fm.createSymbolicLink(at: temp, withDestinationURL: external)
    do { _ = try store.items(); fatalError("缓存目录被换成符号链接后应拒绝") } catch { }
    try require(try fm.contentsOfDirectory(atPath: external.path).isEmpty, "攻击不应在库外创建锁或其他文件")
    let images = root.appendingPathComponent("attack-images")
    let imageStore = try MarkdownStore(root: images)
    let original = root.appendingPathComponent("owned-pixel.png")
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
    try bytes.write(to: original)
    let saved = try imageStore.save(MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "攻击样例", excerpt: ""), imageSource: original)
    let path = saved.note.attachment!
    let asset = saved.url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    try require(try AttachmentAccess.read(noteURL: saved.url, relativePath: path) == bytes, "真实附件可访问")
    try fm.removeItem(at: asset)
    try fm.createSymbolicLink(at: asset, withDestinationURL: original)
    do { _ = try AttachmentAccess.read(noteURL: saved.url, relativePath: path); fatalError("附件符号链接应拒绝") } catch { }
    try fm.removeItem(at: asset)
    try Data("tampered".utf8).write(to: asset)
    do { _ = try AttachmentAccess.read(noteURL: saved.url, relativePath: path); fatalError("替换附件应拒绝") } catch { }
    do { _ = try AttachmentAccess.read(noteURL: saved.url, relativePath: "../../outside-sentinel"); fatalError("路径穿越应拒绝") } catch { }
    try require(try Data(contentsOf: original) == bytes, "库外原件不变")
    let linkedNote = images.appendingPathComponent("Notes/linked.md")
    try fm.createSymbolicLink(at: linkedNote, withDestinationURL: saved.url)
    do { _ = try DocumentAccess.read(linkedNote); fatalError("MD 链接应拒绝") } catch { }
    try require(try DocumentAccess.read(saved.url) == Data(contentsOf: saved.url), "正常 MD 可访问")
    print("PASS: 对抗测试—缓存目录链接替换、附件链接/篡改/路径穿越拒绝，库外哨兵不变")
}
