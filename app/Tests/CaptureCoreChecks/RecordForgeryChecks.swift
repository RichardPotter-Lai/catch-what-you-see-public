import Foundation
import CaptureCore

/// 红队复现：A 元数据伪造指向 B 资产，不能把 B 清掉并留下悬空记录。
func checkRecordForgery(_ root: URL) throws {
    let folder = root.appendingPathComponent("record-forgery")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
    let firstSource = folder.appendingPathComponent("first.png")
    let secondSource = folder.appendingPathComponent("second.png")
    try png.write(to: firstSource); try png.write(to: secondSource)
    let store = try TemporaryStore(root: folder.appendingPathComponent("Library"))
    let first = try store.ingest(firstSource), second = try store.ingest(secondSource)
    let record = store.root.appendingPathComponent(".temporary/" + first.id.uuidString + ".json")
    let originalRecord = try Data(contentsOf: record)
    var forged = try JSONSerialization.jsonObject(with: originalRecord) as! [String: Any]
    forged["filename"] = second.filename
    forged["hash"] = second.hash
    try JSONSerialization.data(withJSONObject: forged).write(to: record)
    var reachedTrash = false
    var rejected = false
    do {
        try store.clean(first.id) { url in
            reachedTrash = true
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("test-trash.png"))
        }
    } catch { rejected = true }
    try require(rejected && !reachedTrash, "伪造记录必须在任何清理回调前被拒绝")
    try require(try Data(contentsOf: store.url(for: second)) == png, "其他临时记录的图片必须保留")
    try require(try Data(contentsOf: secondSource) == png, "外部原件不得变化")

    // 文件名身份与 JSON 身份不一致也不能成为覆盖另一记录的入口。
    forged = try JSONSerialization.jsonObject(with: originalRecord) as! [String: Any]
    forged["id"] = second.id.uuidString
    try JSONSerialization.data(withJSONObject: forged).write(to: record)
    var listingRejected = false
    do { _ = try store.items() } catch { listingRejected = true }
    try require(listingRejected, "记录文件名与内部 UUID 不一致必须拒绝")
    // 第二轮：篡改 operationID 不得使 B 的收藏复用 A 的 MD 并谎报成功。
    let collisionRoot = root.appendingPathComponent("operation-forgery")
    try FileManager.default.createDirectory(at: collisionRoot, withIntermediateDirectories: true)
    let sourceA = collisionRoot.appendingPathComponent("a.png")
    let sourceB = collisionRoot.appendingPathComponent("b.png")
    try png.write(to: sourceA)
    try (png + Data("different-bytes".utf8)).write(to: sourceB)
    let collisionStore = try TemporaryStore(root: collisionRoot.appendingPathComponent("Library"))
    let a = try collisionStore.ingest(sourceA), b = try collisionStore.ingest(sourceB)
    try require(a.hash != b.hash && a.noteID != b.noteID, "对抗夹具必须是不同字节及独立笔记身份")
    let aRecord = collisionStore.root.appendingPathComponent(".temporary/" + a.id.uuidString + ".json")
    let aOriginal = try Data(contentsOf: aRecord)
    var collision = try JSONSerialization.jsonObject(with: aOriginal) as! [String: Any]
    collision["operationID"] = b.operationID.uuidString
    try JSONSerialization.data(withJSONObject: collision).write(to: aRecord)
    var operationRejected = false
    do { _ = try collisionStore.collect(a.id) } catch { operationRejected = true }
    try require(operationRejected, "跨临时记录的操作 ID 冲突必须拒绝")
    let bRecord = collisionStore.root.appendingPathComponent(".temporary/" + b.id.uuidString + ".json")
    let unchangedB = try JSONSerialization.jsonObject(with: Data(contentsOf: bRecord)) as! [String: Any]
    try require(unchangedB["saved"] as? Bool == false, "冲突不得让另一条记录被标为已收藏")
    try require(try Data(contentsOf: collisionStore.url(for: a)) == png, "冲突保留 A 输入")
    try require(try Data(contentsOf: collisionStore.url(for: b)) == png + Data("different-bytes".utf8), "冲突保留 B 输入")

    collision = try JSONSerialization.jsonObject(with: aOriginal) as! [String: Any]
    collision["noteID"] = b.noteID.uuidString
    try JSONSerialization.data(withJSONObject: collision).write(to: aRecord)
    var noteRejected = false
    do { _ = try collisionStore.items() } catch { noteRejected = true }
    try require(noteRejected, "跨记录复用笔记 ID 必须拒绝")
    print("PASS: 对抗伪造临时记录，拒绝跨记录资产清理及 JSON 身份替换")
}
