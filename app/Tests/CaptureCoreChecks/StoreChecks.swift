import Foundation
import CaptureCore

func checkStore(_ root: URL) throws {
    let folder = root.appendingPathComponent("store")
    let store = try MarkdownStore(root: folder)
    let first = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "合成", excerpt: "同内容")
    let second = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: first.createdAt, title: first.title, excerpt: first.excerpt)
    let a = try store.save(first)
    let b = try store.save(second)
    try require(a.url != b.url && !a.reused && !b.reused, "新的主动操作必须独立")
    var edited = first; edited.notes = "外部备注"; edited.excerpt = "外部修改的摘录"
    try MarkdownFormat.encode(edited).write(to: a.url, options: .atomic)
    var retry = first; retry.id = UUID(); retry.excerpt = "不得覆盖"
    let reopened = try MarkdownStore(root: folder)
    let same = try reopened.save(retry)
    try require(same.reused && same.url == a.url, "重启同操作应定位已有文件")
    try require(try MarkdownFormat.decode(Data(contentsOf: a.url)) == edited, "重试不能覆盖外部编辑")
    let entries = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Notes"), includingPropertiesForKeys: nil)
    try require(entries.count == 2, "重试不得重复生成文件")
    var collision = second; collision.id = first.id; collision.operationID = UUID()
    do { _ = try store.save(collision); fatalError("同 ID 冲突应拒绝") } catch MarkdownStore.Failure.conflict { }
    let concurrentRoot = root.appendingPathComponent("concurrent-store")
    let results = ConcurrentResults()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        do {
            let result = try MarkdownStore(root: concurrentRoot).save(first)
            results.record(reused: result.reused)
        } catch { results.record(error: error) }
    }
    try require(results.failures == 0 && results.created == 1 && results.reused == 7, "并发重试应只提交一次")
    print("PASS: 主动操作独立、重启重试幂等、保留外部编辑、ID 冲突拒绝")
}

// 测试线程只通过锁保护的入口记录结果；在 concurrentPerform 返回后读取。
private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var failures = 0
    private(set) var created = 0
    private(set) var reused = 0
    func record(reused: Bool) {
        lock.lock(); defer { lock.unlock() }
        if reused { self.reused += 1 } else { created += 1 }
    }
    func record(error: Error) {
        lock.lock(); defer { lock.unlock() }; failures += 1
    }
}
