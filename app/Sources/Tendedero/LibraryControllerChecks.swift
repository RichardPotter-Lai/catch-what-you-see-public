import Foundation
import Combine
import CaptureCore

/// 维护者合成检查，不创建窗口，不接触系统截图设置或用户资料。
@MainActor
enum LibraryControllerChecks {
    static func run(root: URL) throws {
        func require(_ value: Bool, _ message: String) {
            precondition(value, message)
        }
        let support = root.appendingPathComponent("OtherMac/Application Support")
        require(AppEnvironment.resolveLibrary(developmentLibrary: nil, selectedPath: nil, applicationSupport: support) == support.appendingPathComponent("CatchWhatYouSee/Library", isDirectory: true), "新 Mac 默认资料库必须属于当前用户，不能引用编译机路径")
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        require(AppEnvironment.resolveLibrary(developmentLibrary: nil, selectedPath: chosen.path, applicationSupport: support) == chosen, "已有自选资料库保持不变")
        require(AppEnvironment.resolveLibrary(developmentLibrary: root, selectedPath: chosen.path, applicationSupport: support) == root, "开发库仍保持隔离")
        let store = try MarkdownStore(root: root)
        // 卡片删除与列表选区解耦；取消、确认期间外部编辑均不能移除卡片。
        let deletionRoot = root.appendingPathComponent("CardDeletion")
        let deletionStore = try MarkdownStore(root: deletionRoot)
        let deletionNote = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "卡片删除", excerpt: "保留正文")
        let deletionSaved = try deletionStore.save(deletionNote)
        let deletionController = LibraryController(root: deletionRoot)
        var removed: [UUID] = []
        deletionController.onRemovedNote = { id, url in precondition(url == deletionSaved.url); removed.append(id) }
        deletionController.deleteNote(at: deletionSaved.url, expectedID: deletionNote.id, confirm: { false })
        require(FileManager.default.fileExists(atPath: deletionSaved.url.path) && removed.isEmpty, "取消删除必须保留文件和卡片")
        var editedNote = deletionNote; editedNote.excerpt = "确认期间外部修改"
        deletionController.deleteNote(at: deletionSaved.url, expectedID: deletionNote.id, confirm: {
            try! MarkdownFormat.encode(editedNote).write(to: deletionSaved.url, options: .atomic)
            return true
        })
        require(FileManager.default.fileExists(atPath: deletionSaved.url.path) && removed.isEmpty, "确认期间文件变化必须拒绝删除")
        var asked = false
        deletionController.deleteNote(at: deletionSaved.url, expectedID: UUID(), confirm: { asked = true; return true })
        require(!asked && removed.isEmpty, "卡片身份过期不得删除另一个笔记")
        let deletionLine = Line()
        deletionLine.soundOn = false
        let cardID = deletionLine.hang(deletionSaved.url, quietly: true)!
        deletionLine.onDeleteNote = { url, id, fingerprint in deletionController.deleteNote(at: url, expectedID: id, expectedFingerprint: fingerprint) }
        var latestNote = editedNote; latestNote.excerpt = "卡片未刷新时的新正文"
        try MarkdownFormat.encode(latestNote).write(to: deletionSaved.url, options: .atomic)
        deletionLine.requestDeletion(cardID)
        require(FileManager.default.fileExists(atPath: deletionSaved.url.path) && removed.isEmpty, "过期卡片不得删除尚未显示的新版正文")
        deletionLine.refreshDocuments()
        deletionLine.requestDeletion(cardID)
        require(!FileManager.default.fileExists(atPath: deletionSaved.url.path) && removed == [deletionNote.id], "成功删除后才通知移除对应卡片")
        let deleted = try deletionStore.deletedNotes()
        require(deleted.count == 1 && deleted[0].note?.excerpt == latestNote.excerpt, "回收站保留最新内容")
        _ = try deletionStore.restore(deleted[0])
        require(FileManager.default.fileExists(atPath: deletionSaved.url.path), "卡片删除后笔记可恢复")
        print("PASS: 卡片删除取消/竞态/身份核对、成功回调和恢复")
        let animationRoot = root.appendingPathComponent("TextDeletionAnimation")
        let animationStore = try MarkdownStore(root: animationRoot)
        let animationSaved = try animationStore.save(MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "落下的便笺", excerpt: "中文 English 🌱\n第二行"))
        let animationLine = Line(); animationLine.soundOn = true
        let animationController = LibraryController(root: animationRoot)
        let animationID = animationLine.hang(animationSaved.url, quietly: true)!
        var falls = 0
        var deletionSounds = 0
        animationLine.onDeletionSound = { deletionSounds += 1 }
        animationLine.onFall = { item in
            require(!FileManager.default.fileExists(atPath: item.url.path), "只有删除成功后才播放下落")
            require(item.thumb == nil && item.note?.excerpt == animationSaved.note.excerpt, "文字卡片保留原始正文而非图片")
            let frame = PeggedView.animationImage(for: item, scale: 2)
            require(frame != nil && frame!.width > 100 && frame!.height > 100, "文件移走后仍可从已显示正文绘制下落便笺")
            falls += 1
        }
        animationController.onRemovedNote = { id, url in animationLine.discard(id, matching: url, deletion: true) }
        animationLine.onDeleteNote = { url, id, fingerprint in animationController.deleteNote(at: url, expectedID: id, expectedFingerprint: fingerprint) }
        animationController.deleteNote(at: animationSaved.url, expectedID: animationID, expectedFingerprint: "stale")
        require(falls == 0 && deletionSounds == 0 && animationLine.liveCount == 1, "删除失败不下落、不播放声音")
        animationLine.requestDeletion(animationID)
        animationLine.requestDeletion(animationID)
        require(falls == 1 && animationLine.liveCount == 0, "成功删除与重复点击只播放一次下落")
        require(deletionSounds == 1, "成功删除与下落必须只播放一次废纸篓音效")
        require(try animationStore.deletedNotes().first?.note?.excerpt == animationSaved.note.excerpt, "动画不改变回收站内的 Markdown")
        animationLine.soundOn = false
        let mutedSaved = try animationStore.save(MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-07T00:00:00Z", title: "静音删除", excerpt: animationSaved.note.excerpt))
        let mutedID = animationLine.hang(mutedSaved.url, quietly: true)!
        animationLine.requestDeletion(mutedID)
        require(falls == 2 && deletionSounds == 1, "声音关闭时继续下落，但不播放删除音效")
        print("PASS: 删除成功音效与下落同步一次；失败、重复点击及静音不误播")
        print("PASS: 文字删除后可绘制同款下落便笺，失败不掉落、重复点击一次、正文仍为 Markdown")
        // 一键临时删除走同一安全存储路径；以隔离目录模拟废纸篓，不碰用户废纸篓。
        let temporaryRoot = root.appendingPathComponent("DirectTemporaryDeletion")
        let temporarySource = root.appendingPathComponent("direct-source.png")
        let temporaryBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        try temporaryBytes.write(to: temporarySource)
        let temporaryStore = try TemporaryStore(root: temporaryRoot)
        let directItem = try temporaryStore.ingest(temporarySource)
        let directURL = try temporaryStore.url(for: directItem)
        let directController = LibraryController(root: temporaryRoot)
        var cleaned: [UUID] = []
        directController.onCleanedTemporary = { id, url in precondition(url == directURL); cleaned.append(id) }
        let otherRoot = root.appendingPathComponent("OtherTemporaryLibrary")
        try FileManager.default.copyItem(at: temporaryRoot, to: otherRoot)
        let otherController = LibraryController(root: otherRoot)
        var wrongCleaned = false
        otherController.onCleanedTemporary = { _, _ in wrongCleaned = true }
        otherController.cleanTemporary(directItem.id, expectedURL: directURL, trash: { _ in preconditionFailure("跨库同 UUID 不能删除错误副本") })
        require(!wrongCleaned && FileManager.default.fileExists(atPath: directURL.path), "跨库卡片删除被拒绝，原件保留")
        directController.cleanTemporary(directItem.id, expectedURL: directURL, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        require(cleaned.isEmpty && FileManager.default.fileExists(atPath: directURL.path), "清理失败必须保留卡片与文件")
        let trashURL = root.appendingPathComponent("synthetic-trash.png")
        directController.cleanTemporary(directItem.id, trash: { try FileManager.default.moveItem(at: $0, to: trashURL) })
        require(cleaned == [directItem.id] && !FileManager.default.fileExists(atPath: directURL.path), "一键删除成功后移除临时卡片")
        require(try Data(contentsOf: temporarySource) == temporaryBytes, "原件保留")
        require(try Data(contentsOf: trashURL) == temporaryBytes, "废纸篓副本保持原字节")
        directController.cleanTemporary(directItem.id, trash: { _ in preconditionFailure("重复删除不可再次移文件") })
        require(cleaned.count == 1, "重复点击不得再次删除其他对象")
        print("PASS: 一键笔记删除与恢复、临时删除失败保留/成功移除/原件保留/重复点击")
        var note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "合成刷新测试", excerpt: "旧内容")
        let saved = try store.save(note)
        let source = root.appendingPathComponent("source.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        try bytes.write(to: source)
        let temporary = try TemporaryStore(root: root).ingest(source)
        let controller = LibraryController(root: root)
        controller.showingTemporary = true
        controller.selected = temporary.id.uuidString
        for _ in 0..<3 { controller.refresh() }
        require(controller.selected == temporary.id.uuidString, "周期刷新必须保留临时 UUID 选区")
        controller.showingTemporary = false
        controller.refresh()
        controller.selected = controller.entries.first?.id
        controller.refresh()
        require(controller.selected != nil, "长期笔记选区仍有效")
        var idlePublications = 0
        let idleSubscription = controller.objectWillChange.sink { idlePublications += 1 }
        for _ in 0..<3 { controller.refresh() }
        require(idlePublications == 0, "未变化的轮询不能重建界面或打断键盘/辅助功能操作")
        idleSubscription.cancel()
        controller.showingTemporary = true
        controller.showingTrash = true
        require(controller.showingTrash && !controller.showingTemporary, "回收站不能同时显示临时列表")
        controller.showingTemporary = true
        require(controller.showingTemporary && !controller.showingTrash, "临时列表不能与回收站混合")
        controller.showingTemporary = false
        var editedImageReceived: URL?
        controller.onTemporary = { _, url in editedImageReceived = url }
        let editedImage = root.appendingPathComponent("edited-result.png")
        try bytes.write(to: editedImage)
        controller.receiveEditedImage(editedImage)
        require(editedImageReceived != nil && editedImageReceived != editedImage, "编辑结果须接入持久临时项并挂卡")
        require(try Data(contentsOf: editedImageReceived!) == bytes && Data(contentsOf: source) == bytes, "编辑结果保存且原图保持不变")
        print("PASS: 列表模式互斥、无变化轮询不发布、编辑图片接回持久临时列表与挂卡")
        let malformed = root.appendingPathComponent(".temporary/broken.json")
        try Data("broken fixture".utf8).write(to: malformed)
        note.excerpt = "外部更新内容"
        try MarkdownFormat.encode(note).write(to: saved.url, options: .atomic)
        controller.refresh()
        require(controller.entries.first?.note?.excerpt == note.excerpt, "临时坏记录不阻断正常 MD 更新")
        var values: [String: PreferenceLease.Value] = ["location": .string("before")]
        var receipt: Data?
        let preferenceLease = PreferenceLease(read: { values[$0] }, write: { values[$0] = $1 }, load: { receipt }, persist: { receipt = $0 })
        try preferenceLease.acquire(["location": .string("ours")], otherOwnerRunning: false)
        var acquiredHere = true
        let released = try Inbox.restoreOwnedLease(acquiredHere: &acquiredHere, competitor: true, release: { try preferenceLease.release() })
        require(released && values["location"] == .string("before") && receipt == nil, "第二实例存在不得阻止第一所有者正常 CAS 还原")
        try preferenceLease.acquire(["location": .string("ours")], otherOwnerRunning: false)
        acquiredHere = false
        let deferred = try Inbox.restoreOwnedLease(acquiredHere: &acquiredHere, competitor: true, release: { try preferenceLease.release() })
        require(!deferred && values["location"] == .string("ours") && receipt != nil, "旧收据在其他所有者运行时保持不动")
        let recovered = try Inbox.restoreOwnedLease(acquiredHere: &acquiredHere, competitor: false, release: { try preferenceLease.release() })
        require(recovered && values["location"] == .string("before") && receipt == nil, "竞争消失后可恢复旧收据")
        print("PASS: 本进程退出还原与遗留收据恢复分别处理，竞争实例不阻断自身 CAS 还原")
        print("PASS: 临时选区跨刷新保持、长期选区保持、坏临时记录不阻断 MD 更新")
    }
}
