import AppKit
import CaptureCore
import ApplicationServices
import Carbon

do {
    AppEnvironment.development = try DevelopmentConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("开发模式必须指定 --development --library /绝对/测试库路径\n", stderr)
    exit(2)
}
if CommandLine.arguments.contains("--check-accessibility") {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "Accessibility: authorized" : "Accessibility: permissionRequired")
    exit(trusted ? 0 : 3)
}
if CommandLine.arguments.contains("--probe-copy-fixture") {
    guard AppEnvironment.isDevelopment,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "local.catchwhatyousee.copyfixture" else {
        print("Copy fixture: sourceChanged"); exit(4)
    }
    var finished = false
    var resultCode: Int32 = 4
    let previousClipboard: CopyClipboardSnapshot
    do { previousClipboard = try NativeCopySelection.snapshot(.general) }
    catch {
        let board = NSPasteboard.general
        print("Copy fixture: clipboard backup unavailable: \(error); items=\(board.pasteboardItems?.count ?? -1); types=\((board.types ?? []).map(\.rawValue))")
        exit(4)
    }
    MainActor.assumeIsolated {
        NativeSelectionReader.read(allowCopyFallback: !CommandLine.arguments.contains("--direct-only")) { _, result in
            switch result {
            case .success(let snapshot):
                let restoredBytes = (try? NativeCopySelection.snapshot(.general).items) == previousClipboard.items
                let matched = snapshot.text == "Catch synthetic 选区\n第二行 123"
                    && snapshot.sourceID == "local.catchwhatyousee.copyfixture"
                    && snapshot.clipboardRestoration == .restored && restoredBytes
                print(matched ? "PASS: actual native copy fixture, exact text, original clipboard restored" : "FAIL: copy fixture mismatch")
                resultCode = matched ? 0 : 4
            case .failure(let error): print("Copy fixture: \(error)")
            }
            finished = true
        }
    }
    let stop = Date().addingTimeInterval(8)
    while !finished && Date() < stop {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    exit(resultCode)
}
if let index = CommandLine.arguments.firstIndex(of: "--probe-synthetic-selection"), index + 1 < CommandLine.arguments.count {
    let bundle = CommandLine.arguments[index + 1]
    guard ["com.apple.TextEdit", "com.apple.Safari", "com.google.Chrome"].contains(bundle),
          let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundle else {
        print("Probe: sourceChanged"); exit(4)
    }
    do {
        let snapshot = try SelectionReader(source: NativeSelectionSource(pid: front.processIdentifier)).read()
        let matches = snapshot.text == "Catch synthetic 选区\n第二行 123"
        print(matches ? "Probe: syntheticSelectionMatched" : "Probe: syntheticSelectionMismatch")
        exit(matches ? 0 : 4)
    } catch { print("Probe: \(error)"); exit(4) }
}
if CommandLine.arguments.contains("--check-watcher") {
    guard AppEnvironment.isDevelopment, let root = AppEnvironment.development.library else { exit(2) }
    do {
        let folder = root.appendingPathComponent("WatchFixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        try bytes.write(to: folder.appendingPathComponent("old.png"))
        var reported: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, anyImage: true, onNew: { reported.append($0.lastPathComponent) }, onChange: {})
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard reported.isEmpty else { fatalError("旧图片不能导入") }
        let new = folder.appendingPathComponent("new.png")
        try Data(bytes.prefix(25)).write(to: new)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard reported.isEmpty else { fatalError("半写入不得报告") }
        try bytes.write(to: new)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        guard reported == ["new.png"] else { fatalError("完整图片必须只报告一次") }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: new.path)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard reported.count == 1 else { fatalError("重复事件不得重复报告") }
        watcher.stop()
        print("PASS: 真实目录监听忽略旧图、半写入等待、完整图一次报告、重复事件去重")
    } catch { print("Watcher fixture failed"); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--check-hotkey") || CommandLine.arguments.contains("--check-capture-shortcut") {
    guard AppEnvironment.isDevelopment else { exit(2) }
    let shortcut = CommandLine.arguments.contains("--check-capture-shortcut") ? Shortcut.captureStandard
        : Shortcut(keyCode: kVK_F20, modifiers: [.control, .option, .shift], key: "F20")
    var original = HotKey(shortcut) {}
    guard original != nil else { print("HotKey test: fixtureCombinationUnavailable"); exit(3) }
    guard HotKey(shortcut, action: {}) == nil else { fatalError("冲突注册不应抢占") }
    guard HotKey(shortcut, action: {}) == nil else { fatalError("原注册应继续有效") }
    original = nil
    guard let replacement = HotKey(shortcut, action: {}) else { fatalError("原注册释放后应可注册") }
    withExtendedLifetime(replacement) { print("PASS: \(shortcut.display) Carbon 独占注册冲突不抢占旧配置，释放后可重新注册") }
    exit(0)
}
if CommandLine.arguments.contains("--check-native-selection") {
    guard AppEnvironment.isDevelopment, AppEnvironment.development.session == nil else { exit(2) }
    MainActor.assumeIsolated {
        do { try NativeSelectionChecks.run() }
        catch { fputs("Native selection checks failed\n", stderr); exit(1) }
    }
    exit(0)
}
if CommandLine.arguments.contains("--check-line-identity") {
    guard AppEnvironment.isDevelopment, AppEnvironment.development.session == nil,
          let root = AppEnvironment.development.library else { exit(2) }
    MainActor.assumeIsolated {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try LineIdentityChecks.run(root: root)
        } catch { fputs("Line identity checks failed\n", stderr); exit(1) }
    }
    exit(0)
}
if CommandLine.arguments.contains("--check-library-controller") {
    guard AppEnvironment.isDevelopment, let root = AppEnvironment.development.library else { exit(2) }
    MainActor.assumeIsolated {
        do { try LibraryControllerChecks.run(root: root) }
        catch { fputs("Library controller checks failed\n", stderr); exit(1) }
    }
    exit(0)
}
if CommandLine.arguments.contains("--check-screenshot-handoff") {
    guard !AppEnvironment.isDevelopment else { exit(2) }
    MainActor.assumeIsolated {
        Inbox.restore()
        guard Inbox.lastError.isEmpty else { print("Handoff: competingOwnerOrRecoveryRequired"); exit(3) }
        Inbox.apply()
        guard Inbox.isApplied, Inbox.isEnabled else { print("Handoff: acquisitionFailed"); exit(3) }
        let domain = "com.apple.screencapture" as CFString
        let applied = CFPreferencesCopyAppValue("location" as CFString, domain) as? String == Inbox.folder.path
        Inbox.restore()
        guard applied, !Inbox.isApplied, Inbox.lastError.isEmpty else { print("Handoff: verificationOrRestoreFailed"); exit(4) }
        print("PASS: 经授权的真实截图设置接管、系统值核验与收据还原；未替代实际截图链路验收")
    }
    exit(0)
}
if CommandLine.arguments.contains("--check-line") {
    guard AppEnvironment.isDevelopment, let root = AppEnvironment.development.library else { exit(2) }
    MainActor.assumeIsolated {
        do {
            let store = try MarkdownStore(root: root)
            var note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "合成便笺", excerpt: String(repeating: "长文本🌱", count: 200))
            let first = try store.save(note)
            let line = Line(); line.soundOn = false
            guard let id = line.hang(first.url), line.items.last?.thumb == nil, line.items.last?.note?.excerpt == note.excerpt else { fatalError("文字不依赖图片") }
            line.pin(id)
            let restored = Line(restoreSaved: true)
            guard restored.items.first?.id == id, restored.items.first?.kept == true else { fatalError("身份和固定状态恢复") }
            line.unpin(id); line.maxItems = 1
            note.id = UUID(); note.operationID = UUID()
            let second = try store.save(note); _ = line.hang(second.url)
            guard FileManager.default.fileExists(atPath: first.url.path), line.liveCount == 1 else { fatalError("满绳不删除文件") }
            line.discard(note.id, quietly: true)
            guard FileManager.default.fileExists(atPath: second.url.path) else { fatalError("收起不删除文件") }
            let hidden = Line(restoreSaved: true)
            guard hidden.items.isEmpty else { fatalError("重启保持收起") }
            _ = hidden.hang(first.url)
            guard hidden.items.first?.id == id else { fatalError("重新挂回保持身份") }
            var edited = first.note; edited.excerpt = "外部更新"
            try MarkdownFormat.encode(edited).write(to: first.url, options: .atomic)
            hidden.refreshDocuments()
            guard hidden.items.first?.note?.excerpt == "外部更新" else { fatalError("便笺刷新外部编辑") }
            try Data("damaged markdown".utf8).write(to: first.url)
            hidden.refreshDocuments()
            guard hidden.items.first?.readOnly == true, hidden.exportURL(id) == nil else { fatalError("坏文件不能继续显示/导出旧缓存") }
            try MarkdownFormat.encode(edited).write(to: first.url)
            hidden.refreshDocuments()
            guard hidden.items.first?.readOnly == false else { fatalError("修复文件后恢复读取") }
            let image = root.appendingPathComponent("line-image.png")
            try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!.write(to: image)
            let temporaries = try TemporaryStore(root: root)
            let temporary = try temporaries.ingest(image)
            hidden.hangTemporary(temporary, url: try temporaries.url(for: temporary))
            let restoredImages = Line(restoreSaved: true)
            guard restoredImages.items.contains(where: { $0.id == temporary.id && $0.temporaryID == temporary.id }) else { fatalError("临时身份恢复") }
            restoredImages.clear()
            guard FileManager.default.fileExists(atPath: try temporaries.url(for: temporary).path) else { fatalError("清空绳不删临时图") }
            print("PASS: 原生 Line 文字无缩略图、稳定身份/固定/收起恢复、满绳不删、重新挂回和外部刷新")
        } catch { fputs("Line checks failed: \(error)\n", stderr); exit(1) }
    }
    exit(0)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
