import Foundation
import CaptureCore

func checkRecovery(_ root: URL) throws {
    let note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "恢复合成", excerpt: "原输入\n保留")
    for point in MarkdownStore.FaultPoint.allCases {
        let folder = root.appendingPathComponent("fault-" + point.rawValue)
        let store = try MarkdownStore(root: folder, fault: { stage in
            if stage == point { throw MarkdownStore.Failure.injected(stage) }
        })
        do { _ = try store.save(note); fatalError("故障点应中断") }
        catch MarkdownStore.Failure.injected { }
        let fresh = try MarkdownStore(root: folder)
        if point == .beforeDraft {
            do { _ = try fresh.resume(operationID: note.operationID); fatalError("无完整输入应需重新采集") }
            catch MarkdownStore.Failure.inputUnavailable { }
        } else {
            let resumed = try fresh.resume(operationID: note.operationID)
            try require(resumed.note == note, "恢复必须使用原输入")
            _ = try fresh.resume(operationID: note.operationID)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Notes").path)
            try require(files.filter { $0.hasSuffix(".md") }.count == 1, "恢复不得重复")
        }
    }
    let folder = root.appendingPathComponent("tampered-draft")
    let interrupted = try MarkdownStore(root: folder, fault: { if $0 == .afterDraft { throw MarkdownStore.Failure.injected($0) } })
    do { _ = try interrupted.save(note) } catch MarkdownStore.Failure.injected { }
    let draft = folder.appendingPathComponent(".pending/" + note.operationID.uuidString.lowercased() + ".md")
    try Data("partial".utf8).write(to: draft)
    do { _ = try MarkdownStore(root: folder).resume(operationID: note.operationID); fatalError("残缺草稿不得恢复") }
    catch MarkdownStore.Failure.inputUnavailable { }
    try require(try Data(contentsOf: draft) == Data("partial".utf8), "不覆盖损坏草稿")
    let readonly = root.appendingPathComponent("readonly-store")
    let store = try MarkdownStore(root: readonly)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.appendingPathComponent("Notes").path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.appendingPathComponent("Notes").path) }
    do { _ = try store.save(note); fatalError("不可写目录应失败") } catch { }
    let indexRoot = root.appendingPathComponent("index-unwritable")
    let indexStore = try MarkdownStore(root: indexRoot)
    try FileManager.default.createDirectory(at: indexRoot.appendingPathComponent("INDEX.md"), withIntermediateDirectories: true)
    let saved = try indexStore.save(note)
    try require(!saved.indexRebuilt && FileManager.default.fileExists(atPath: saved.url.path), "索引失败不丢已提交笔记")
    print("PASS: 提交阶段故障恢复、无输入重新采集、残缺草稿保留、不可写目录失败")
}

func checkAttachments(_ root: URL) throws {
    let source = root.appendingPathComponent("synthetic.png")
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
    try bytes.write(to: source)
    let folder = root.appendingPathComponent("images")
    let store = try MarkdownStore(root: folder)
    let first = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "图", excerpt: "")
    var second = first; second.id = UUID(); second.operationID = UUID()
    let a = try store.save(first, imageSource: source)
    let b = try store.save(second, imageSource: source)
    try require(a.url != b.url && a.note.attachment == b.note.attachment, "同图收藏独立，附件可复用")
    let renamedSource = root.appendingPathComponent("same-bytes.jpeg")
    try bytes.write(to: renamedSource)
    var renamedNote = first; renamedNote.id = UUID(); renamedNote.operationID = UUID()
    let renamed = try store.save(renamedNote, imageSource: renamedSource)
    try require(renamed.note.attachment == a.note.attachment, "相同字节不因原文件扩展名不同而分裂")
    let path = try requireAttachment(a.note)
    let asset = a.url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    try require(try Data(contentsOf: asset) == bytes, "保留原始字节")
    try require(try Data(contentsOf: source) == bytes, "不删除外部原图")
    try Data("tampered".utf8).write(to: asset)
    var third = first; third.id = UUID(); third.operationID = UUID()
    do { _ = try store.save(third, imageSource: source); fatalError("附件损坏应拒绝复用") }
    catch MarkdownStore.Failure.attachmentIntegrity { }
    try require(try Data(contentsOf: asset) == Data("tampered".utf8), "不覆盖损坏附件")
    try bytes.write(to: asset)
    let moved = root.appendingPathComponent("moved-images")
    try FileManager.default.moveItem(at: folder, to: moved)
    try? FileManager.default.removeItem(at: moved.appendingPathComponent("INDEX.md"))
    let reopened = try MarkdownStore(root: moved)
    try reopened.rebuildIndex()
    let existing = try reopened.resume(operationID: first.operationID)
    let movedAsset = existing.url.deletingLastPathComponent().appendingPathComponent(try requireAttachment(existing.note)).standardizedFileURL
    try require(try Data(contentsOf: movedAsset) == bytes, "整库移动后相对链接仍可用")
    try require(FileManager.default.fileExists(atPath: moved.appendingPathComponent("INDEX.md").path), "目录可重建")
    // 各阶段的图片恢复同时检查原图仍在、恢复后附件有效。
    for point in MarkdownStore.FaultPoint.allCases where point != .beforeDraft {
        let dir = root.appendingPathComponent("image-fault-" + point.rawValue)
        let broken = try MarkdownStore(root: dir, fault: { if $0 == point { throw MarkdownStore.Failure.injected($0) } })
        do { _ = try broken.save(first, imageSource: source) } catch MarkdownStore.Failure.injected { }
        let result = try MarkdownStore(root: dir).resume(operationID: first.operationID)
        let url = result.url.deletingLastPathComponent().appendingPathComponent(try requireAttachment(result.note)).standardizedFileURL
        try require(try Data(contentsOf: url) == bytes, "图片中断恢复附件错误")
        try require(try Data(contentsOf: source) == bytes, "失败恢复不删除临时原图")
    }
    print("PASS: 附件字节复用/损坏拒绝、独立笔记、移动与索引重建、图片各阶段恢复")
}
private func requireAttachment(_ note: MarkdownNote) throws -> String {
    guard let path = note.attachment else { throw NSError(domain: "Checks", code: 1) }
    return path
}
