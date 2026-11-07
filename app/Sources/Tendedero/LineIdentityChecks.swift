import Foundation
import CaptureCore

/// 使用独立开发偏好及合成资料，不创建窗口、不修改运行中会话。
@MainActor
enum LineIdentityChecks {
    static func run(root: URL) throws {
        precondition(AppEnvironment.isDevelopment && AppEnvironment.development.session == nil)
        let temporary = try TemporaryStore(root: root.appendingPathComponent("Temporary"))
        let source = root.appendingPathComponent("source.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        try bytes.write(to: source)
        let item = try temporary.ingest(source)
        let line = Line(); line.soundOn = false
        line.hangTemporary(item, url: try temporary.url(for: item))
        line.pin(item.id)
        line.discard(item.id, quietly: true)
        line.putBack()
        guard let recovered = line.items.first(where: { !$0.falling }) else { fatalError("临时卡片必须放回") }
        precondition(recovered.id == item.id && recovered.temporaryID == item.id && recovered.kept, "撤销收起须恢复临时身份、类型与固定状态")
        var cleaned: UUID?
        line.onCleanTemporary = { id, url in
            precondition(url == recovered.url); cleaned = id
        }
        line.requestDeletion(item.id)
        precondition(cleaned == item.id, "恢复后仍路由到安全临时清理入口")
        var collected: UUID?
        line.onCollectTemporary = { id, url in precondition(url == recovered.url); collected = id }
        line.onCollectTemporary?(recovered.temporaryID!, recovered.url)
        precondition(collected == item.id, "恢复后收藏使用原临时身份")
        let note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "同身份库副本", excerpt: "A 库合成正文")
        let a = try MarkdownStore(root: root.appendingPathComponent("A")).save(note)
        var changedCopy = note; changedCopy.excerpt = "B 库合成正文"
        let b = try MarkdownStore(root: root.appendingPathComponent("B")).save(changedCopy)
        let copied = Line(); copied.soundOn = false
        precondition(copied.hang(a.url, quietly: true) == note.id)
        precondition(copied.hang(b.url, quietly: true) == nil, "同身份不同路径不可创建第二卡片")
        precondition(copied.liveCount == 1 && copied.items.first?.url == a.url)
        copied.discard(note.id, matching: b.url)
        precondition(copied.liveCount == 1, "同 UUID 的其他库删除回调不可收起原卡")
        var deletionURL: URL?
        copied.onDeleteNote = { url, _, _ in deletionURL = url }
        copied.requestDeletion(note.id)
        precondition(deletionURL == a.url, "拒绝 B 卡后原卡仍绑定 A 路径")
        copied.discard(note.id, quietly: true)
        precondition(copied.hang(b.url, quietly: true) == note.id, "明确收起 A 后可挂 B 副本")
        copied.requestDeletion(note.id)
        precondition(deletionURL == b.url && copied.items.filter { !$0.falling }.first?.note?.excerpt == changedCopy.excerpt, "新卡只能访问 B 的内容与删除目标")
        copied.putBack()
        precondition(copied.liveCount == 1 && copied.items.filter { !$0.falling }.first?.url == b.url, "撤销历史 A 不得与当前 B 制造身份碰撞")
        // 升级前偏好可能已经保存两条重复 ID，恢复时也必须拒绝第二条。
        AppEnvironment.preferences.set([a.url.path, b.url.path], forKey: "pegged")
        let restarted = Line(restoreSaved: true)
        precondition(restarted.liveCount == 1 && restarted.items.first?.url == a.url, "历史重复 ID 偏好只恢复一个明确目标")
        let aUnchanged = try Data(contentsOf: a.url) == MarkdownFormat.encode(note)
        let bUnchanged = try Data(contentsOf: b.url) == MarkdownFormat.encode(changedCopy)
        precondition(aUnchanged && bUnchanged, "两个库的原文件保持不变")
        print("PASS: 临时撤销保持类型/身份/固定/动作路由；跨库同 UUID 去重、收起后换目标、撤销及重启去重；源文件不变")
    }
}
