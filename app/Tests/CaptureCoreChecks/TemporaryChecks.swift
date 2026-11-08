import Foundation
import CaptureCore

func checkTemporary(_ root: URL) throws {
    let library = root.appendingPathComponent("temporary-library")
    let source = root.appendingPathComponent("temporary-source.png")
    let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
    try Data(data.prefix(25)).write(to: source)
    let store = try TemporaryStore(root: library)
    do { _ = try store.ingest(source); fatalError("半写入图片不可接收") } catch TemporaryStore.Failure.incompleteImage { }
    try data.write(to: source)
    let item = try store.ingest(source)
    try require(try store.ingest(source).id == item.id, "重复目录事件不重复")
    try require(!FileManager.default.fileExists(atPath: library.appendingPathComponent("Notes").path), "未收藏不创建 MD")
    let restarted = try TemporaryStore(root: library)
    try require(try restarted.items().count == 1, "退出重启保持临时记录")
    let record = library.appendingPathComponent(".temporary/" + item.id.uuidString + ".json")
    var old = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
    old["createdAt"] = "2000-01-01T00:00:00Z"
    try JSONSerialization.data(withJSONObject: old).write(to: record)
    try require(try TemporaryStore(root: library).items().count == 1, "超过七天无自动删除")
    enum Interrupted: Error { case afterMarkdown }
    let interrupted = try TemporaryStore(root: library, afterSave: { throw Interrupted.afterMarkdown })
    do { _ = try interrupted.collect(item.id); fatalError("中断注入") } catch Interrupted.afterMarkdown { }
    try require(try Data(contentsOf: source) == data, "状态更新中断保留输入")
    let saved = try restarted.collect(item.id)
    try require(try restarted.collect(item.id).url == saved.url, "收藏重试幂等")
    try require(try Data(contentsOf: source) == data && Data(contentsOf: restarted.url(for: item)) == data, "收藏保留原输入")
    let permanent = saved.url.deletingLastPathComponent().appendingPathComponent(saved.note.attachment!)
    try restarted.clean(item.id) { try FileManager.default.moveItem(at: $0, to: root.appendingPathComponent("saved-copy-trash.png")) }
    try require(try Data(contentsOf: permanent) == data && Data(contentsOf: saved.url).count > 0, "清理已收藏临时副本不损坏永久附件或 MD")
    let other = root.appendingPathComponent("temporary-other.png"); try data.write(to: other)
    let pending = try restarted.ingest(other)
    try Data("tampered".utf8).write(to: permanent)
    do { try restarted.clean(pending.id, trash: { _ in fatalError("损坏永久附件不得清理来源") }); fatalError("永久附件完整性应检查") } catch AttachmentAccess.Failure.integrity { }
    try data.write(to: permanent)
    let fresh = try TemporaryStore(root: root.appendingPathComponent("temporary-clean"))
    let disposable = try fresh.ingest(source)
    let badNotes = fresh.root.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: badNotes, withIntermediateDirectories: true)
    let bad = badNotes.appendingPathComponent("unknown.md"); try Data("无法解析的引用".utf8).write(to: bad)
    do { try fresh.clean(disposable.id, trash: { _ in fatalError("未知引用不得清理") }); fatalError("未知引用应拒绝") } catch TemporaryStore.Failure.unknownReferences { }
    try FileManager.default.removeItem(at: bad)
    let fakeTrash = root.appendingPathComponent("test-trash.png")
    try fresh.clean(disposable.id) { try FileManager.default.moveItem(at: $0, to: fakeTrash) }
    try require(try fresh.items().isEmpty && Data(contentsOf: source) == data, "仅清理托管副本，外部原件不变")
    let ownedInbox = root.appendingPathComponent("owned-screenshots")
    try FileManager.default.createDirectory(at: ownedInbox, withIntermediateDirectories: true)
    let ownedSource = ownedInbox.appendingPathComponent("owned.png")
    try data.write(to: ownedSource)
    let ownedStore = try TemporaryStore(root: root.appendingPathComponent("owned-clean-library"))
    let ownedItem = try ownedStore.ingest(ownedSource)
    let ownedAsset = try ownedStore.url(for: ownedItem)
    var recycled: [URL] = []
    let syntheticTrash = root.appendingPathComponent("owned-trash")
    try FileManager.default.createDirectory(at: syntheticTrash, withIntermediateDirectories: true)
    try ownedStore.clean(ownedItem.id, managedSourceDirectory: ownedInbox) { file in
        recycled.append(file)
        try FileManager.default.moveItem(at: file, to: syntheticTrash.appendingPathComponent(file.lastPathComponent))
    }
    try require(recycled.count == 2 && !FileManager.default.fileExists(atPath: ownedSource.path) && !FileManager.default.fileExists(atPath: ownedAsset.path), "明确删除时，受管截图原件与临时副本均进废纸篓")
    try require(try ownedStore.items().isEmpty, "删除后活动临时记录消失")
    // 图片笔记与附件已进回收站时，仍可完成其对应临时副本清理。
    let linkedStore = try TemporaryStore(root: root.appendingPathComponent("linked-clean-library"))
    let linkedItem = try linkedStore.ingest(source)
    let linkedSaved = try linkedStore.collect(linkedItem.id)
    let linkedMD = try MarkdownStore(root: linkedStore.root)
    let linkedIndex = LibraryIndex(root: linkedStore.root); try linkedIndex.refresh()
    let linkedDeleted = try linkedMD.trash(linkedIndex.entries[0])
    try linkedStore.clean(linkedItem.id, managedSourceDirectory: ownedInbox) {
        try FileManager.default.moveItem(at: $0, to: syntheticTrash.appendingPathComponent($0.lastPathComponent))
    }
    try require(try linkedStore.items().isEmpty && Data(contentsOf: source) == data, "笔记删除后临时副本可清理，外部导入原件不动")
    _ = try linkedMD.restore(linkedDeleted)
    try require(try AttachmentAccess.read(noteURL: linkedSaved.url, relativePath: linkedSaved.note.attachment!) == data, "清理关联临时项后仍可恢复笔记与图片")
    let external = root.appendingPathComponent("external-owned-test")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let externalSource = external.appendingPathComponent("outside.png")
    try data.write(to: externalSource)
    let linkedInbox = root.appendingPathComponent("linked-inbox")
    try FileManager.default.createSymbolicLink(at: linkedInbox, withDestinationURL: external)
    let guardedStore = try TemporaryStore(root: root.appendingPathComponent("guarded-source-library"))
    let guardedItem = try guardedStore.ingest(externalSource)
    do {
        try guardedStore.clean(guardedItem.id, managedSourceDirectory: linkedInbox) { _ in fatalError("不能通过托管目录符号链接删除外部来源") }
        fatalError("托管目录链接必须拒绝")
    } catch TemporaryStore.Failure.unsafePath { }
    try require(try Data(contentsOf: externalSource) == data && guardedStore.items().count == 1, "拒绝链接保留外部原件及临时记录")
    // 未开启“接管截图”时收件箱目录不存在，删除不能因此失败；
    // 带系统截图标记的原件（如桌面截图）一并移入废纸篓，普通外部图片保留。
    let desktop = root.appendingPathComponent("fake-desktop")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let shot = desktop.appendingPathComponent("截屏 test.png")
    try data.write(to: shot)
    let flag: [UInt8] = [1]
    try require(setxattr(shot.path, "com.apple.metadata:kMDItemIsScreenCapture", flag, flag.count, 0, 0) == 0, "测试截图标记写入")
    let plain = desktop.appendingPathComponent("photo.png")
    try data.write(to: plain)
    let missingInbox = root.appendingPathComponent("never-created-inbox")
    let shotStore = try TemporaryStore(root: root.appendingPathComponent("shot-clean-library"))
    let shotItem = try shotStore.ingest(shot)
    let plainItem = try shotStore.ingest(plain)
    var shotTrashed: [String] = []
    let shotTrash = root.appendingPathComponent("shot-trash")
    try FileManager.default.createDirectory(at: shotTrash, withIntermediateDirectories: true)
    for id in [shotItem.id, plainItem.id] {
        try shotStore.clean(id, managedSourceDirectory: missingInbox, deleteScreenshotOriginals: true) {
            shotTrashed.append($0.lastPathComponent)
            try FileManager.default.moveItem(at: $0, to: shotTrash.appendingPathComponent(UUID().uuidString + $0.lastPathComponent))
        }
    }
    try require(try shotStore.items().isEmpty && shotTrashed.count == 3, "收件箱不存在时仍可删除")
    try require(!FileManager.default.fileExists(atPath: shot.path), "系统截图原件随删除进废纸篓")
    try require(Data(contentsOf: plain) == data, "非截图的外部图片原件保留")
    print("PASS: 未开启接管截图也能删除；桌面截图原件一并删除；普通图片原件保留")
    print("PASS: 明确删除包含应用截图原件/临时副本；图文回收后关联清理与恢复；外部原件保留")
    print("PASS: 临时图完整性/重复事件、无主动收藏无 MD、重启/幂等收藏、引用保护与手动清理")
}
