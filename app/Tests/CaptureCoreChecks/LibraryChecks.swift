import Foundation
import CaptureCore

func checkLibrary(_ root: URL) throws {
    let folder = root.appendingPathComponent("discovery")
    let store = try MarkdownStore(root: folder)
    var note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "中文合成", excerpt: "连续中文词组 Hello WORLD", notes: "个人备注", sourceApp: "TextEdit", sourceURL: "https://example.invalid/owned-fixture")
    let saved = try store.save(note)
    let index = LibraryIndex(root: folder)
    try index.refresh()
    try require(index.search("中文词").count == 1 && index.search("hello world").count == 1, "中文子串/英文大小写检索")
    try require(index.search("个人备注").count == 1 && index.search("example.invalid").count == 1, "备注与出处检索")
    let before = index.entries[0]
    note.notes = "外部新备注"; note.excerpt = "最新摘录"
    note.extraMetadata = ["custom": "[one, two]", "owner_note": "\"保留字段\""]
    let bytes = try MarkdownFormat.encode(note)
    try bytes.write(to: saved.url, options: .atomic)
    do { try index.requireUnchanged(before); fatalError("版本变化应拒绝旧写入") } catch LibraryIndex.Failure.changed { }
    try index.refresh()
    try require(index.search("外部新备注").count == 1 && index.search("hello").isEmpty, "刷新不得保留旧正文")
    try require(index.entries[0].note?.extraMetadata == note.extraMetadata, "未知字段保留")
    try require(try Data(contentsOf: saved.url) == bytes, "刷新不得改写文件")
    let bad = folder.appendingPathComponent("Notes/bad.md")
    try Data("---\nbroken".utf8).write(to: bad)
    try index.refresh()
    try store.rebuildIndex()
    try require(try String(contentsOf: folder.appendingPathComponent("INDEX.md"), encoding: .utf8).contains("broken-fixture") == false, "只索引实际文件")
    try require(try String(contentsOf: folder.appendingPathComponent("INDEX.md"), encoding: .utf8).contains("bad.md"), "坏文件也提供访问入口")
    try require(index.entries.count == 2 && index.search("外部新备注").count == 1, "坏文件不阻断其他笔记")
    try require(index.entries.contains { $0.url == bad.resolvingSymlinksInPath() && $0.state == .readOnly && $0.rawText == "---\nbroken" }, "损坏文件可只读查看")
    let duplicate = folder.appendingPathComponent("Notes/duplicate.md")
    try bytes.write(to: duplicate)
    try index.refresh()
    try require(index.entries.filter { $0.state == .identityConflict }.count == 2, "同 ID 冲突不能合并")
    try FileManager.default.removeItem(at: duplicate)
    var changedDuringRead = false
    let racing = LibraryIndex(root: folder, afterRead: { url in
        if url.lastPathComponent == saved.url.lastPathComponent && !changedDuringRead {
            changedDuringRead = true
            var changed = note; changed.notes = "原子替换的新版本"
            try MarkdownFormat.encode(changed).write(to: url, options: .atomic)
        }
    })
    try racing.refresh()
    try require(racing.entries.contains { $0.state == .unstable }, "读取期间替换不能展示旧快照为最新")
    try racing.refresh()
    try require(racing.search("原子替换").count == 1, "文件稳定后重新读取")
    let nested = folder.appendingPathComponent("Notes/nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: saved.url, to: nested.appendingPathComponent("moved.md"))
    try index.refresh()
    try require(index.search("原子替换").count == 1, "库内移动后可发现")
    try FileManager.default.removeItem(at: bad)
    let retryMoved = try store.save(note)
    try require(retryMoved.reused && retryMoved.url.lastPathComponent == "moved.md", "重试必须发现已移动的同操作笔记")
    try FileManager.default.removeItem(at: nested.appendingPathComponent("moved.md"))
    try index.refresh()
    try require(index.search("原子替换").isEmpty, "缺失文件不保留旧命中")
    let repeatedRoot = root.appendingPathComponent("search-repeated")
    let repeatedStore = try MarkdownStore(root: repeatedRoot)
    _ = try repeatedStore.save(note)
    var independent = note; independent.id = UUID(); independent.operationID = UUID()
    _ = try repeatedStore.save(independent)
    let rebuilt = LibraryIndex(root: repeatedRoot)
    try rebuilt.refresh()
    try require(rebuilt.search("最新摘录").count == 2, "搜索不得合并同文独立收藏")
    print("PASS: 中文/英文/出处检索、外部编辑刷新、未知字段、坏文件隔离、ID 冲突、原子替换及移动")
}
