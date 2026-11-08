import AppKit
import SwiftUI

/// 拖出只复制；收起不删除文件。显式删除复用资料库的安全检查。
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let isRecording = item.isRecording
        view.url = item.readOnly ? nil : item.contentURL
        view.provideURL = { line.exportURL(id) }
        view.dragImage = item.thumb ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown 笔记")
        view.isHeld = item.held
        view.onHangBack = { line.onHangBack?(id) }
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.pressCorner(id) }
        view.toolTip = line.corner(of: id) == .unpin
            ? "左上角：删除；右上角：取消固定。右键可仅收起。"
            : "左上角：删除；右上角：仅收起并保留文件。"
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            if let temporary = item.temporaryID {
                menu.addItem(ClosureMenuItem("收藏为 Markdown") { line.onCollectTemporary?(temporary, item.url) })
            }
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            if item.note != nil { menu.addItem(ClosureMenuItem("打开关联 Markdown") { NSWorkspace.shared.open(item.url) }) }
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if !isRecording && item.note == nil {
                menu.addItem(ClosureMenuItem(L("Hold")) { line.onHold?(id) })
            }
            if !isRecording && (item.note == nil || item.note?.attachment != nil) {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let currentItem = line.items.first(where: { $0.id == id })
            let kept = currentItem?.kept == true
            if !kept {
                menu.addItem(ClosureMenuItem(L("Pin")) { line.pin(id) })
            } else if currentItem?.byHand == false {
                menu.addItem(ClosureMenuItem(L("Unpin")) { line.unpin(id) })
            }
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("打开资料库…") { line.onOpenLibrary?() })
            menu.addItem(ClosureMenuItem("从晾衣绳收起（保留文件）") { line.discard(id) })
            if item.note != nil || item.temporaryID != nil {
                let remove = ClosureMenuItem(item.note != nil ? "删除笔记" : "删除截图") { line.requestDeletion(id) }
                remove.isEnabled = !item.readOnly && !item.falling && !item.held
                menu.addItem(remove)
            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var provideURL: (() -> URL?)?
    var dragImage: NSImage?
    /// Held in your hand: only its faded trace is on the line, and a click
    /// on it is all it answers, to bring the photo back.
    var isHeld = false
    var onHangBack: () -> Void = {}
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false
    /// A click copies only once it is clear it is not the first half of a
    /// double click, which opens the photo and must leave the clipboard alone.
    private var clickTimer: Timer?

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 右上角保留收起/取消固定；左上角删除由独立 SwiftUI Button 接收。
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: max(0, bounds.width - Self.crossHitSize), y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if isHeld {
            downPoint = nil
            onHangBack()
            return
        }
        if event.clickCount > 1 {
            clickTimer?.invalidate()
            clickTimer = nil
        }
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        guard let url = provideURL?() ?? (provideURL == nil ? url : nil) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            // Waits as long as the system lets a second click count as a double click.
            clickTimer?.invalidate()
            // The copy goes ahead even if the line redraws this view meanwhile.
            let copy = onClick
            let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clickTimer = nil
                    copy()
                }
            }
            // Keeps time while a menu or a drag runs the loop in another mode.
            RunLoop.main.add(timer, forMode: .common)
            clickTimer = timer
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isHeld else { return }
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
