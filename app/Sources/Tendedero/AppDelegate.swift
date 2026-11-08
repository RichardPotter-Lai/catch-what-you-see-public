import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI
import CaptureCore
import CaptureNative

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private lazy var libraryController = LibraryController(root: AppEnvironment.library)
    private var textService: TextCaptureService?
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var captureKey: HotKey?
    private var captureBusy = false
    private var documentTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !AppEnvironment.preferences.bool(forKey: "menuBarRevealOff") }
        set { AppEnvironment.preferences.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !AppEnvironment.preferences.bool(forKey: "quietHang") }
        set { AppEnvironment.preferences.set(!newValue, forKey: "quietHang") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        libraryController.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if !AppEnvironment.isDevelopment {
            Inbox.restore()
            if Inbox.lastError.isEmpty && Inbox.captureRequested { Inbox.apply() }
            libraryController.message = Inbox.lastError
        }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        // 不启动被动剪贴板历史。

        if !AppEnvironment.isDevelopment { registerShortcut(); registerCaptureShortcut() }
        else if CommandLine.arguments.contains("--enable-capture-hotkey") { registerCaptureShortcut() }

        documentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.libraryController.isVisible else { return }
                self.line.refreshDocuments()
            }
        }
        line.onOpenLibrary = { [weak self] in self?.libraryController.show() }
        libraryController.onRefresh = { [weak self] in self?.line.refreshDocuments() }
        libraryController.onToggleScreenshotCapture = { [weak self] enabled in self?.setInbox(enabled) }
        libraryController.onToggleFullScreen = { [weak self] enabled in
            FullScreen.showLineOver = enabled
            self?.refresh()
            self?.libraryController.refresh()
        }
        libraryController.onRevealLine = { [weak self] in
            guard let self else { return }
            self.keepOpen = true
            self.pinned = true
            self.openedOnPurpose = true
            self.comeDown(on: nil)
            self.reveal(pinned: true)
        }
        libraryController.onSaved = { [weak self] saved in
            guard let self else { return }; _ = self.line.hang(saved.url); self.comeDown(on: nil)
        }
        libraryController.onHang = { [weak self] entry in
            guard let self else { return }; _ = self.line.hang(entry.url); self.comeDown(on: nil)
        }
        libraryController.onTemporary = { [weak self] item, url in
            guard let self else { return }; self.line.hangTemporary(item, url: url); self.comeDown(on: nil)
        }
        libraryController.onCollectedTemporary = { [weak self] id, url in self?.line.discard(id, matching: url) }
        line.onCollectTemporary = { [weak self] id, url in self?.libraryController.collectTemporary(id, expectedURL: url) }
        libraryController.onRemovedNote = { [weak self] id, url in self?.line.discard(id, matching: url, deletion: true) }
        libraryController.onCleanedTemporary = { [weak self] id, url in self?.line.discard(id, matching: url, deletion: true) }
        // 明确点击垃圾桶即删除；不激活应用或弹确认框。失败仍在卡片外可见。
        line.onDeleteNote = { [weak self] url, id, fingerprint in
            guard let self else { return }
            self.libraryController.deleteNote(at: url, expectedID: id, expectedFingerprint: fingerprint)
            CaptureFeedback.shared.show(title: "删除笔记", detail: self.libraryController.message)
        }
        line.onCleanTemporary = { [weak self] id, url in
            guard let self else { return }
            self.libraryController.cleanTemporary(id, expectedURL: url)
            CaptureFeedback.shared.show(title: "删除截图", detail: self.libraryController.message)
        }
        setUpStatusItem()
        watchMenuBarClicks()
        if !AppEnvironment.isDevelopment {
            WelcomeGuide.runOnLaunch()
        }

        // Hang on Tendedero, in the menu of images in Finder and other apps.
        let service = TextCaptureService { [weak self] text in
            try MainActor.assumeIsolated {
                guard let self else { throw SelectionFailure.sourceExited }
                _ = try self.libraryController.capture(text)
            }
        }
        textService = service
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
        if CommandLine.arguments.contains("--show-library") {
            libraryController.show()
        }

        if AppEnvironment.isDevelopment && CommandLine.arguments.contains("--demo-line") {
            do {
                _ = try libraryController.capture("合成便笺 · 长文本测试\n" + String(repeating: "保留完整文字与 emoji 🌱，界面只显示摘要。", count: 40))
                let image = AppEnvironment.library.deletingLastPathComponent().appendingPathComponent("synthetic.png")
                try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!.write(to: image, options: .withoutOverwriting)
                libraryController.addTemporary(image)
                keepOpen = true; wanted = true; refresh(); reveal(pinned: true)
            } catch { libraryController.message = "合成演示初始化失败，原文件已保留。" }
        }
        Markup.shared.onSaved = { [weak self] url in
            guard let self else { return }
            self.libraryController.receiveEditedImage(url)
            CaptureFeedback.shared.show(title: "图片编辑", detail: self.libraryController.message)
        }
        Trim.shared.onSaved = { [weak self] url in
            guard let self else { return }
            _ = self.line.hang(url)
            self.comeDown(on: nil)
        }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onHold = { [weak self] id in self?.hold(id) }
        line.onHangBack = { id in Held.hangBack(id) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !AppEnvironment.isDevelopment && !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !AppEnvironment.isDevelopment && !AppEnvironment.preferences.bool(forKey: "welcomed") {
            AppEnvironment.preferences.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !AppEnvironment.isDevelopment { Inbox.restore() }
        AppEnvironment.preferences.synchronize()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        guard !AppEnvironment.isDevelopment else { return }
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        folderWatchers.forEach { $0.stop() }; folderWatchers = []
        guard Inbox.isEnabled else { return }
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot arrived in fallback folder")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = AppEnvironment.preferences.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { AppEnvironment.preferences.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        guard !AppEnvironment.isDevelopment else { return }
        Inbox.captureRequested = on
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        libraryController.message = Inbox.lastError
        startWatcher()
        libraryController.refresh()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = "让 Catch what you see 接管截图？"
        alert.informativeText = L(
            "系统截图将保存到本应用目录，并登记为临时图片。临时图片不会自动过期；点击收藏后生成 Markdown。关闭接管或退出时，只还原仍属于本应用的设置。请先退出原版截图所有者。")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.


    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if !AppEnvironment.isDevelopment { Inbox.restore() }
                AppEnvironment.preferences.synchronize()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        Held.forget(except: Set(line.items.filter { !$0.falling && $0.held }.map(\.id)))
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        if isRecording(url) { _ = line.hang(url, quietly: true); comeDown(on: nil); return }
        libraryController.addTemporary(url)
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, !Self.reducesMotion, CaptureFlight.flightsInProgress < 2,
              let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    /// Reduce motion in Accessibility settings: photos land and leave
    /// without flying across the screen or falling down it.
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = PeggedView.animationImage(for: item, scale: screen.backingScaleFactor) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), pinned: item.kept, on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].displaySize)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
        holdPutBackKey(false)
        holdPhotoKeys(over: nil)
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// The part of the menu bar that brings the line down: the middle third,
    /// so the menus on the left and the icons on the right stay easy to reach.
    static func revealBand(of screen: NSScreen) -> NSRect {
        let bar = menuBarBand(of: screen)
        let width = bar.width / 3
        return NSRect(x: bar.midX - width / 2, y: bar.minY, width: width, height: bar.height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }
        let inRevealBand = screenUnderPointer.map { NSMouseInRect(mouse, Self.revealBand(of: $0), false) } ?? false

        guard isRevealed else {
            holdPutBackKey(false)
            holdPhotoKeys(over: nil)
            line.closeGaps()
            // Resting in the middle of the menu bar brings the line down on
            // that screen. Pushing against the top edge is part of it, and it
            // also works when another display sits above and the pointer
            // never stops.
            // An empty line stays up there: only the shortcut and the menu
            // bring it down on purpose.
            if line.liveCount > 0, Self.opensFromMenuBar, let screen = screenUnderPointer,
               inRevealBand, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }
        holdPutBackKey(inside)
        holdPhotoKeys(over: inside ? photo(under: mouse) : nil)
        // Gaps left by discarded photos close once the pointer moves away.
        if !inside { line.closeGaps() }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu
            || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Holding

    /// Takes a photo off the line to hold in front of you. The line goes
    /// up, so it is out of the way of the photo you are looking at.
    private func hold(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.held }) else { return }
        line.setHeld(id, true)
        Held.show(id, url: item.url, line: line) { [weak self] id, frame in self?.hangBack(id, from: frame) }
    }

    /// Back onto its clip: the line comes down and the photo flies home.
    private func hangBack(_ id: UUID, from frame: CGRect) {
        line.setHeld(id, false)
        comeDown(on: NSScreen.screens.first { $0.frame.intersects(frame) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: frame)
        }
    }

    // MARK: Hang on Tendedero

    /// The service macOS lists for images in Finder and elsewhere. What
    /// you hang yourself is pinned, and the line comes down to show it.
    @objc func hangOnLine(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        comeDown(on: nil)
        var any = false
        for url in urls where line.hangKept(url) { any = true }
        if !any { NSSound.beep() }
    }

    // MARK: Keys over a photo

    /// Delete and Space while the pointer rests on a photo: Delete does what
    /// its corner button does, Space takes a quick look, as in Finder. Like
    /// ⌘Z, they are borrowed as hot keys only then, so every other app keeps
    /// them.
    private var photoKeys: [HotKey] = []
    private var photoKeysFor: UUID?

    private func holdPhotoKeys(over id: UUID?) {
        let id = id.flatMap { id in line.items.first { $0.id == id && !$0.falling && !$0.held }?.id }
        guard id != photoKeysFor else { return }
        photoKeysFor = id
        photoKeys = []
        guard let id else { return }
        photoKeys = [
            HotKey(Shortcut(keyCode: kVK_Delete, modifiers: [], key: "\u{8}")) { [weak self] in
                self?.line.pressCorner(id)
            },
            HotKey(Shortcut(keyCode: kVK_Space, modifiers: [], key: " ")) { [weak self] in
                self?.quickLookToggle(id)
            },
        ].compactMap { $0 }
    }

    /// The photo whose card is under the pointer, if any.
    private func photo(under mouse: NSPoint) -> UUID? {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.contains(flipped) }?.key
    }

    /// Space opens Quick Look, and closes it again if it is already open.
    private func quickLookToggle(_ id: UUID) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            line.quickLook(id)
        }
    }

    // MARK: Putting back

    /// ⌘Z while the pointer is on the line. The line never takes the
    /// keyboard, so it only borrows ⌘Z then, as a hot key. Everywhere else
    /// ⌘Z stays the undo of the app you are in.
    private var putBackKey: HotKey?

    /// Set when another app holds ⌘Z, so it is not asked for again on every
    /// tick, only the next time the pointer comes to the line.
    private var putBackKeyRefused = false

    private func holdPutBackKey(_ hold: Bool) {
        guard hold && line.canPutBack else {
            putBackKey = nil
            putBackKeyRefused = false
            return
        }
        guard putBackKey == nil, !putBackKeyRefused else { return }
        putBackKey = HotKey(Shortcut.putBack) { [weak self] in self?.putBack() }
        putBackKeyRefused = putBackKey == nil
    }

    /// From the menu the line is usually up, so it comes down for a moment
    /// to show the photos going back.
    private func putBack() {
        if !isRevealed {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        }
        line.putBack()
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        hotKey?.suspended = true
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            defer { self.hotKey?.suspended = false }
            guard let result else { return }
            guard let shortcut = result else { self.hotKey = nil; Shortcut.current = nil; return }
            if shortcut == Shortcut.current { return }
            guard let replacement = HotKey(shortcut, action: { [weak self] in self?.toggle() }) else {
                self.libraryController.message = "快捷键注册失败，原配置已保留。"; NSSound.beep(); return
            }
            self.hotKey = replacement
            Shortcut.current = shortcut
        }
    }
    private var captureShortcut: Shortcut? {
        get {
            guard let value = AppEnvironment.preferences.dictionary(forKey: "captureShortcut") else {
                return Shortcut.captureStandard
            }
            guard let code = value["keyCode"] as? Int, let modifiers = value["modifiers"] as? UInt, let key = value["key"] as? String else { return nil }
            return Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), key: key)
        }
        set {
            AppEnvironment.preferences.set(newValue.map { ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any] } ?? [:], forKey: "captureShortcut")
        }
    }
    private func registerCaptureShortcut() {
        guard let shortcut = captureShortcut else { return }
        captureKey = HotKey(shortcut) { [weak self] in self?.captureSelection() }
        if captureKey == nil { libraryController.message = "收藏快捷键无法注册，请修改组合或使用文本服务。" }
    }
    private func changeCaptureShortcut() {
        captureKey?.suspended = true
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            defer { self.captureKey?.suspended = false }
            guard let result else { return }
            guard let shortcut = result else { self.captureKey = nil; self.captureShortcut = nil; return }
            if shortcut == self.captureShortcut && self.captureKey != nil { return }
            guard let replacement = HotKey(shortcut, action: { [weak self] in self?.captureSelection() }) else {
                self.libraryController.message = "组合已被占用，旧收藏快捷键仍有效。可改组合或使用文本服务。"; NSSound.beep(); return
            }
            self.captureKey = replacement; self.captureShortcut = shortcut
        }
    }
    private func captureSelection() {
        guard !captureBusy else { return }
        captureBusy = true
        let allowCopy = AppEnvironment.preferences.object(forKey: "copyFallbackEnabled") as? Bool ?? true
        NativeSelectionReader.read(allowCopyFallback: allowCopy) { [weak self] sourceName, result in
            guard let self else { return }
            self.captureBusy = false
            do {
                let snapshot = try result.get()
                _ = try self.libraryController.capture(snapshot.text, sourceApp: snapshot.sourceID, sourceURL: snapshot.document ?? "")
                if snapshot.clipboardRestoration == .failed {
                    self.libraryController.message = "已收藏，但原剪贴板未能完整恢复。"
                    CaptureFeedback.shared.show(title: "已收藏 · " + sourceName, detail: self.libraryController.message)
                    return
                }
                if !self.isRevealed {
                    CaptureFeedback.shared.show(title: "已收藏 · " + sourceName, detail: "已保存为 Markdown。可从菜单或资料库显示晾衣绳。")
                }
            } catch {
                let reason: String
                if let copyError = error as? CopySelectionFailure {
                    switch copyError {
                    case .unavailable: reason = "无法执行兼容复制，可手动复制后使用“收藏剪贴板文字”。"
                    case .clipboardChanged: reason = "剪贴板被其他操作更新，已保留新内容，请重新选择后再试。"
                    case .protectedClipboard: reason = "剪贴板包含受保护内容，兼容复制已取消。"
                    case .unsupportedClipboard: reason = "无法完整备份剪贴板，可手动复制后使用“收藏剪贴板文字”。"
                    case .noFreshText: reason = "本次复制没有产生新文字，请确认选中了可复制的内容。"
                    case .keysStillHeld: reason = "请松开快捷键后重试。"
                    }
                } else { switch error as? SelectionFailure {
                case .permissionRequired:
                    reason = "需要辅助功能权限。"
                    PermissionGuide.captureNeedsPermission()
                case .emptySelection: reason = "当前没有选中文字。"
                case .secureInput: reason = "安全输入状态下无法采集。"
                case .sourceChanged: reason = "读取期间来源或选区变化，请重新选择。"
                case .sourceExited: reason = "来源应用已退出。"
                case .timeout: reason = "来源未及时响应。"
                case .unsupportedSelection: reason = "该视图不公开选区，可尝试系统文本服务。"
                case nil: reason = "保存失败，完整草稿可从资料库恢复。"
                } }
                self.libraryController.message = "未收藏 · " + sourceName + "：" + reason
                CaptureFeedback.shared.show(title: "未收藏 · " + sourceName, detail: reason)
                NSSound.beep()
            }
        }
    }

    private func captureClipboardText() {
        guard !captureBusy else { return }
        do {
            let text = try NativeCopySelection.clipboardText()
            _ = try libraryController.capture(text, sourceApp: "clipboard")
            CaptureFeedback.shared.show(title: "已收藏 · 剪贴板", detail: "已保存为 Markdown。")
        } catch {
            libraryController.message = "未收藏：剪贴板没有可保存的普通文字，或内容受到保护。"
            CaptureFeedback.shared.show(title: "未收藏 · 剪贴板", detail: libraryController.message)
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "CatchWhatYouSeeStatusItem"
        // 用户曾按住 Command 把图标拖出菜单栏时，系统会记住隐藏状态；这里恢复显示。
        statusItem.isVisible = true
        updateStatusIcon()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("打开资料库…", key: "l") { [weak self] in self?.libraryController.show() })
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let count = line.liveCount
        let description = "Catch what you see"
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        // 使用和应用图标一致的便笺标志（模板图，自动适配浅色/深色菜单栏）。
        // 以前用系统的 T 恤符号，而且绳上为空时变灰，别的 Mac 上几乎看不到。
        let image = StatusIcon.image(filled: count > 0)
        image.accessibilityDescription = "\(description), \(state)"
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = false
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)
        menu.addItem(ClosureMenuItem("收藏快捷键：" + (captureShortcut?.display ?? "未设置")) { [weak self] in self?.changeCaptureShortcut() })
        menu.addItem(ClosureMenuItem("收藏剪贴板文字") { [weak self] in self?.captureClipboardText() })
        let copyFallback = ClosureMenuItem("兼容复制后备") {
            let enabled = AppEnvironment.preferences.object(forKey: "copyFallbackEnabled") as? Bool ?? true
            AppEnvironment.preferences.set(!enabled, forKey: "copyFallbackEnabled")
        }
        copyFallback.state = (AppEnvironment.preferences.object(forKey: "copyFallbackEnabled") as? Bool ?? true) ? .on : .off
        copyFallback.toolTip = "仅在主动收藏且直接取字失败时复制；取得新文字后尽力恢复原剪贴板。"
        menu.addItem(copyFallback)
        let feedback = NSMenuItem(title: libraryController.message.isEmpty ? "文字收藏：等待主动采集" : libraryController.message, action: nil, keyEquivalent: "")
        menu.addItem(feedback)
        let permission = ClosureMenuItem(PermissionGuide.isTrusted ? "辅助功能权限：已授权" : "⚠︎ 授权辅助功能（Option+C 需要）…") {
            PermissionGuide.explain(reason: .menu)
        }
        menu.addItem(permission)


        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let putBackItem = ClosureMenuItem(L("Put back"), key: "z") { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = line.canPutBack
        menu.addItem(putBackItem)

        if !Held.heldIDs.isEmpty {
            menu.addItem(ClosureMenuItem(L("Hang everything back")) { Held.hangEverythingBack() })
        }

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)



        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            if let folder = self.watcher?.folder { NSWorkspace.shared.open(folder) }
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 Catch what you see", key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = "请把 Catch what you see 移到应用程序文件夹后重试。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}

