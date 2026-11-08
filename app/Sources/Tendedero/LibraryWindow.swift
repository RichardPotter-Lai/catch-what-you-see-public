import AppKit
import SwiftUI
import CaptureCore

@MainActor
final class LibraryController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var entries: [LibraryIndex.Entry] = []
    @Published var temporaryItems: [TemporaryStore.Item] = []
    @Published var showingTemporary = false { didSet {
        guard oldValue != showingTemporary else { return }
        if showingTemporary && showingTrash { showingTrash = false }
        selected = nil; refresh()
    } }
    @Published var query = ""
    @Published var showingTrash = false { didSet {
        guard oldValue != showingTrash else { return }
        if showingTrash && showingTemporary { showingTemporary = false }
        selected = nil; refresh()
    } }
    @Published var selected: String?
    @Published var message = ""
    @Published var pendingCount = 0
    @Published private(set) var screenshotCaptureEnabled = false
    @Published private(set) var showOverFullScreen = false
    @Published private(set) var root: URL
    private var index: LibraryIndex
    private var window: NSWindow?
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    private var timer: Timer?
    var onCollectedTemporary: ((UUID, URL) -> Void)?
    var onRemovedNote: ((UUID, URL) -> Void)?
    var onCleanedTemporary: ((UUID, URL) -> Void)?
    var onRefresh: (() -> Void)?
    var onTemporary: ((TemporaryStore.Item, URL) -> Void)?
    var onSaved: ((MarkdownStore.Saved) -> Void)?
    var onHang: ((LibraryIndex.Entry) -> Void)?
    var onRevealLine: (() -> Void)?
    var onToggleScreenshotCapture: ((Bool) -> Void)?
    var onToggleFullScreen: ((Bool) -> Void)?

    init(root: URL) {
        self.root = root
        self.index = LibraryIndex(root: root)
        super.init()
    }
    var isVisible: Bool { window?.isVisible == true }
    var filtered: [LibraryIndex.Entry] {
        if showingTrash { return entries.filter { query.isEmpty || $0.rawText.localizedCaseInsensitiveContains(query) } }
        return index.search(query)
    }
    var selection: LibraryIndex.Entry? { entries.first { $0.id == selected } }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Catch what you see · 资料库"
            window.contentView = NSHostingView(rootView: LibraryView(model: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        refresh()
        startWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        if screenshotCaptureEnabled != Inbox.isEnabled { screenshotCaptureEnabled = Inbox.isEnabled }
        if showOverFullScreen != FullScreen.showLineOver { showOverFullScreen = FullScreen.showLineOver }
        do {
            try index.refresh()
            // 临时记录损坏不阻断长期 MD 的刷新，也不继续显示旧临时缓存。
            do {
                let next = try TemporaryStore(root: root).items()
                if next != temporaryItems { temporaryItems = next }
            }
            catch {
                if !temporaryItems.isEmpty { temporaryItems = [] }
                let failure = "部分临时记录无法读取，原文件已保留；长期笔记仍可访问。"
                if message != failure { message = failure }
            }
            onRefresh?()
            let nextEntries = showingTrash ? try MarkdownStore(root: root).deletedNotes() : index.entries
            if entries != nextEntries { entries = nextEntries }
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("INDEX.md").path) {
                do { try MarkdownStore(root: root).rebuildIndex() }
                catch { message = "笔记可查看，但总目录暂时无法重建。" }
            }
            if let selected {
                let exists = showingTemporary
                    ? temporaryItems.contains(where: { $0.id.uuidString == selected })
                    : entries.contains(where: { $0.id == selected })
                if !exists { self.selected = nil }
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".pending").path) {
                let next = try MarkdownStore(root: root).pendingOperations().count
                if pendingCount != next { pendingCount = next }
            } else if pendingCount != 0 { pendingCount = 0 }
        } catch { message = "无法读取资料库，请检查文件夹是否仍可访问。" }
    }
    @discardableResult func capture(_ text: String, sourceApp: String = "", sourceURL: String = "") throws -> MarkdownStore.Saved {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SelectionFailure.emptySelection }
        let title = String(text.components(separatedBy: .newlines).first?.prefix(70) ?? "文字笔记".prefix(70))
        let note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: ISO8601DateFormatter().string(from: Date()), title: title, excerpt: text, sourceApp: sourceApp, sourceURL: sourceURL)
        do {
            let result = try MarkdownStore(root: root).save(note)
            message = result.indexRebuilt ? "已保存" : "笔记已保存，总目录暂未更新。"
            refresh()
            onSaved?(result)
            return result
        } catch {
            message = "未保存成功，原输入没有被替换。可检查资料库或恢复草稿。"
            refresh()
            throw error
        }
    }
    func recover() {
        do {
            let store = try MarkdownStore(root: root)
            var recovered = 0, failed = 0
            for operation in try store.pendingOperations() {
                do { let result = try store.resume(operationID: operation); recovered += 1; onSaved?(result) }
                catch { failed += 1 }
            }
            message = "已恢复 \(recovered) 条" + (failed > 0 ? "；\(failed) 条缺少完整输入或存在冲突，原文件已保留。" : "。")
            refresh()
        } catch { message = "无法读取待恢复草稿。" }
    }
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择资料库文件夹。不会搬动或删除原资料库。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        index = LibraryIndex(root: url)
        selected = nil
        AppEnvironment.preferences.set(url.path, forKey: "libraryPath")
        refresh(); startWatching()
    }
    func addTemporary(_ url: URL) {
        do {
            let store = try TemporaryStore(root: root)
            let item = try store.ingest(url)
            refresh(); hangTemporary(item)
        } catch { message = "图片未完整写入或不可读取，原文件已保留。" }
    }
    func receiveEditedImage(_ url: URL) {
        do {
            let store = try TemporaryStore(root: root)
            let item = try store.ingest(url)
            refresh(); hangTemporary(item)
            message = "编辑后的图片已挂上，可收藏或删除。"
        } catch { message = "编辑结果未能挂上，副本仍保留；可用添加图片重新导入。" }
    }
    func importTemporary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "选择要临时挂上的图片；原文件不会移动或删除。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addTemporary(url) }
    }
    func collectTemporary(_ id: UUID, expectedURL: URL? = nil) {
        do {
            let store = try TemporaryStore(root: root)
            guard let item = try store.items().first(where: { $0.id == id }) else { throw TemporaryStore.Failure.unsafePath }
            let url = try store.url(for: item)
            guard expectedURL == nil || expectedURL?.standardizedFileURL == url.standardizedFileURL else {
                message = "未收藏：卡片不属于当前资料库，请切回原资料库。"; return
            }
            let saved = try store.collect(id)
            onCollectedTemporary?(id, url); onSaved?(saved); message = "截图已收藏为 Markdown。"; refresh()
        } catch { message = "未完成收藏，临时原图保留，可重试同次操作。"; refresh() }
    }
    func cleanTemporary(_ id: UUID, expectedURL: URL? = nil, trash: ((URL) throws -> Void)? = nil) {
        do {
            let store = try TemporaryStore(root: root)
            guard let item = try store.items().first(where: { $0.id == id }) else { throw TemporaryStore.Failure.unsafePath }
            let assetURL = try store.url(for: item)
            if let expectedURL {
                guard assetURL.standardizedFileURL == expectedURL.standardizedFileURL else {
                    message = "未删除：卡片不属于当前资料库，请切回原资料库。"; return
                }
            }
            try store.clean(id, managedSourceDirectory: AppEnvironment.isDevelopment ? nil : Inbox.folder,
                                                   deleteScreenshotOriginals: !AppEnvironment.isDevelopment) { url in
                if let trash { try trash(url) }
                else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            onCleanedTemporary?(id, assetURL)
            message = "截图已删除（原件已移到废纸篓）。"; selected = nil; refresh()
        } catch { message = "未删除：截图已被收藏为笔记或文件发生变化，请在资料库中处理。" }
    }
    func hangTemporary(_ item: TemporaryStore.Item) {
        if item.saved {
            if let entry = index.entries.first(where: { $0.note?.id == item.noteID && $0.state == .ready }) { onHang?(entry) }
            else { message = "关联笔记已移动或删除，请检查资料库或回收站。" }
            return
        }
        if let store = try? TemporaryStore(root: root), let url = try? store.url(for: item) { onTemporary?(item, url) }
    }
    func temporaryURL(_ item: TemporaryStore.Item) -> URL? { try? TemporaryStore(root: root).url(for: item) }
    func openSelected() { if let entry = selection { NSWorkspace.shared.open(entry.url) } }
    func copySelected() {
        guard let entry = selection, entry.state == .ready, let note = entry.note else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.excerpt, forType: .string)
        message = "已复制摘录"
    }
    func deleteSelected() {
        guard let entry = selection else { return }
        delete(entry, confirm: nil)
    }
    /// 使用当前库内的路径和身份定位，不能借用资料库窗口的另一个选区。
    func deleteNote(at url: URL, expectedID: UUID, expectedFingerprint: String? = nil, confirm: (() -> Bool)? = nil) {
        do { try index.refresh() }
        catch { message = "未删除：无法读取资料库。"; return }
        guard let entry = index.entries.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && $0.note?.id == expectedID && $0.state == .ready
        }) else { message = "未删除：笔记已变化或不属于当前资料库，请刷新后检查。"; return }
        guard expectedFingerprint == nil || expectedFingerprint == entry.fingerprint else {
            message = "未删除：笔记内容已变化，请查看刷新后的卡片再删除。"; return
        }
        delete(entry, confirm: confirm)
    }
    private func delete(_ entry: LibraryIndex.Entry, confirm: (() -> Bool)?) {
        guard entry.state == .ready, let id = entry.note?.id,
              (confirm?() ?? true) else { return }
        do {
            _ = try MarkdownStore(root: root).trash(entry)
            onRemovedNote?(id, entry.url)
            var cleanupFailed = false
            if entry.note?.attachment != nil {
                do {
                    let temporaryStore = try TemporaryStore(root: root)
                    for item in try temporaryStore.items() where item.noteID == id {
                        let url = try temporaryStore.url(for: item)
                        try temporaryStore.clean(item.id, managedSourceDirectory: AppEnvironment.isDevelopment ? nil : Inbox.folder,
                                                   deleteScreenshotOriginals: !AppEnvironment.isDevelopment) {
                            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                        }
                        onCleanedTemporary?(item.id, url)
                    }
                } catch { cleanupFailed = true }
            }
            message = cleanupFailed ? "笔记已移入回收站；关联截图未删完，请在“未收藏截图”列表重试。" : "已移入回收站。"
            selected = nil; refresh()
        } catch { message = "未删除：文件已变化或存在冲突，请刷新后检查。"; refresh() }
    }
    func restoreSelected() {
        guard let entry = selection else { return }
        do {
            _ = try MarkdownStore(root: root).restore(entry)
            message = "已恢复笔记。"; selected = nil; refresh()
        } catch { message = "未恢复：存在文件变化、身份冲突或目录不可写，原文件已保留。"; refresh() }
    }
    func addSample() {
        guard AppEnvironment.isDevelopment else { return }
        do { _ = try capture("合成示例：把值得留下的文字保存为 Markdown。\n第二行可以包含中文、English 和 🌱。") }
        catch { }
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) {
        watcher?.cancel(); watcher = nil
        timer?.invalidate(); timer = nil
        refreshWork?.cancel()
    }
    private func startWatching() {
        watcher?.cancel(); watcher = nil
        timer?.invalidate()
        // 目录事件去抖；周期复核同时覆盖原位修改、子目录与编辑器原子替换。
        let fd = open(root.appendingPathComponent("Notes").path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.refreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                self.refreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            source.setCancelHandler { close(fd) }
            source.resume(); watcher = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var model: LibraryController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索标题、摘录、备注或出处", text: $model.query).textFieldStyle(.roundedBorder)
                Toggle("未收藏截图", isOn: $model.showingTemporary).toggleStyle(.button)
                Button("添加图片…") { model.importTemporary() }
                Toggle("回收站", isOn: $model.showingTrash).toggleStyle(.button)
                Button("刷新") { model.refresh() }
                Button("显示晾衣绳") { model.onRevealLine?() }.disabled(model.onRevealLine == nil)
                Button("选择资料库…") { model.chooseLibrary() }
                if AppEnvironment.isDevelopment { Button("生成示例") { model.addSample() } }
            }.padding()
            HStack {
                Toggle("系统截图自动挂上晾衣绳", isOn: Binding(get: { model.screenshotCaptureEnabled }, set: { model.onToggleScreenshotCapture?($0) }))
                    .disabled(AppEnvironment.isDevelopment)
                Text(AppEnvironment.isDevelopment ? "隔离开发模式：系统截图监听已关闭" : (model.screenshotCaptureEnabled ? "截图接管已开启" : "截图接管未开启"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("全屏应用中显示晾衣绳", isOn: Binding(get: { model.showOverFullScreen }, set: { model.onToggleFullScreen?($0) }))
            }.padding(.horizontal).padding(.bottom, 8)
            HSplitView {
                List(selection: $model.selected) {
                    if model.showingTemporary {
                        ForEach(model.temporaryItems) { item in
                            Text((item.saved ? "已收藏 · " : "未收藏 · ") + item.createdAt).tag(item.id.uuidString)
                        }
                    }
                    ForEach(model.showingTemporary ? [] : model.filtered) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.note?.title ?? entry.url.lastPathComponent).lineLimit(2)
                            Text(model.showingTrash && entry.state == .ready ? "已移入回收站" : label(entry.state)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).tag(entry.id)
                    }
                }.frame(minWidth: 240, idealWidth: 290)
                VStack(alignment: .leading, spacing: 12) {
                    if model.showingTemporary, let item = model.temporaryItems.first(where: { $0.id.uuidString == model.selected }) {
                        if let url = model.temporaryURL(item), let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                        Text(item.saved ? "已收藏为笔记" : "尚未收藏；不会自动过期")
                        HStack {
                            Button("收藏为 Markdown") { model.collectTemporary(item.id) }.disabled(item.saved)
                            Button("重新挂上") { model.hangTemporary(item) }
                            Button("删除截图") { model.cleanTemporary(item.id) }
                        }
                    } else if let entry = model.selection {
                        Text(entry.note?.title ?? entry.url.lastPathComponent).font(.title2)
                        if entry.state != .ready { Text(label(entry.state)).foregroundStyle(.orange) }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let note = entry.note {
                                    if let path = note.attachment {
                                        let data = model.showingTrash
                                            ? try? AttachmentAccess.readDeleted(library: model.root, relativePath: path)
                                            : try? AttachmentAccess.read(noteURL: entry.url, relativePath: path)
                                        if let bytes = data, let image = NSImage(data: bytes) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                                        } else { Text("附件缺失、已变化或引用不安全；原文件保留。").foregroundStyle(.orange) }
                                    }
                                    Text(note.excerpt).textSelection(.enabled)
                                    Divider()
                                    Text("我的笔记").font(.headline)
                                    Text(note.notes.isEmpty ? "可打开 Markdown 添加备注。" : note.notes).textSelection(.enabled)
                                    Text([note.sourceApp, note.sourceTitle, note.sourceURL].filter { !$0.isEmpty }.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                } else { Text(entry.rawText).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Button("打开 Markdown") { model.openSelected() }.disabled(model.showingTrash)
                            Button("复制摘录") { model.copySelected() }.disabled(entry.state != .ready || entry.note?.attachment != nil)
                            if model.showingTrash {
                                Button("恢复笔记") { model.restoreSelected() }.disabled(entry.state != .ready)
                            } else {
                                Button("重新挂上") { model.onHang?(entry) }.disabled(entry.state != .ready || model.onHang == nil)
                                Button("移入回收站") { model.deleteSelected() }.disabled(entry.state != .ready)
                            }
                        }
                    } else {
                        Spacer()
                        Text("选择一条笔记查看内容").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.padding().frame(minWidth: 360)
            }
            Divider()
            HStack {
                Text(model.message).lineLimit(2)
                Spacer()
                if model.pendingCount > 0 { Button("恢复 \(model.pendingCount) 条草稿") { model.recover() } }
                Text("\(model.showingTemporary ? model.temporaryItems.count : model.entries.count) 条记录").foregroundStyle(.secondary)
            }.padding(10)
        }.frame(minWidth: 720, minHeight: 420)
    }
    private func label(_ state: LibraryIndex.State) -> String {
        switch state {
        case .ready: return "已保存"
        case .readOnly: return "格式无法解析 · 保留原文件"
        case .unstable: return "文件正在变化 · 稍后刷新"
        case .identityConflict: return "记录身份冲突 · 保留全部文件"
        case .missing: return "文件暂时不可读"
        }
    }
}
