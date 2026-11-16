import AppKit
import SwiftUI
import CaptureCore

@MainActor
final class PromptController: NSObject, ObservableObject {
    @Published private(set) var prompts: [PromptItem] = []
    @Published private(set) var categories: [String] = PromptStore.defaultCategories
    @Published var selectedCategory: String = PromptController.allCategory
    @Published var searchQuery: String = ""
    @Published var message: String = ""
    @Published private(set) var copiedPromptID: UUID?
    @Published private(set) var root: URL

    static let allCategory = "全部"
    static let featuredFilter = "★ \(PromptStore.kazikeBadge)"

    var onHangPrompt: ((PromptItem) -> Void)?

    private var store: PromptStore?
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    private var panel: PromptFloatingPanel?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(root: URL) {
        self.root = root
        super.init()
        reloadStore(seed: true)
    }

    deinit {
        watcher?.cancel()
        refreshWork?.cancel()
    }

    func switchRoot(to newRoot: URL) {
        guard newRoot.standardizedFileURL != root.standardizedFileURL else { return }
        root = newRoot
        selectedCategory = Self.allCategory
        reloadStore(seed: true)
    }

    private func reloadStore(seed: Bool) {
        watcher?.cancel()
        watcher = nil
        do {
            let store = try PromptStore(root: root)
            if seed { try store.seedIfNeeded() }
            self.store = store
            refresh()
            startWatching(folder: store.folder)
        } catch {
            self.store = nil
            message = "Prompt 目录不可用，原文件未改动。"
        }
    }

    func refresh() {
        guard let store else { return }
        do {
            let loaded = try store.loadAll()
            if categories != loaded.categories { categories = loaded.categories }
            if prompts != loaded.items { prompts = loaded.items }
            if selectedCategory != Self.allCategory
                && selectedCategory != Self.featuredFilter
                && !categories.contains(selectedCategory) {
                selectedCategory = Self.allCategory
            }
        } catch {
            message = "读取 Prompt 列表失败，原文件已保留。"
        }
    }

    var hasFeaturedPrompts: Bool {
        prompts.contains { $0.badge == PromptStore.kazikeBadge }
    }

    var filteredPrompts: [PromptItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.filter { item in
            let matchesCategory: Bool
            if selectedCategory == Self.allCategory {
                matchesCategory = true
            } else if selectedCategory == Self.featuredFilter {
                matchesCategory = item.badge == PromptStore.kazikeBadge
            } else {
                matchesCategory = item.category == selectedCategory
            }
            guard matchesCategory else { return false }
            guard !query.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(query)
                || item.content.localizedCaseInsensitiveContains(query)
                || item.category.localizedCaseInsensitiveContains(query)
                || (item.badge?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func count(for category: String) -> Int {
        if category == Self.allCategory { return prompts.count }
        if category == Self.featuredFilter { return prompts.filter { $0.badge == PromptStore.kazikeBadge }.count }
        return prompts.filter { $0.category == category }.count
    }

    func copy(_ item: PromptItem, closePanel: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.content, forType: .string)
        copiedPromptID = item.id
        message = "已复制：\(item.title)"
        CaptureFeedback.shared.show(title: "已复制 Prompt", detail: item.title)
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedPromptID == id { self?.copiedPromptID = nil }
        }
        if closePanel { hidePanel() }
    }

    @discardableResult
    func savePrompt(id: UUID? = nil, title: String, category: String, badge: String? = nil, content: String) -> Bool {
        guard let store else { return false }
        do {
            let saved = try store.save(id: id, title: title, category: category, badge: badge, content: content)
            refresh()
            selectedCategory = saved.category
            message = id == nil ? "已新建 Prompt：\(saved.title)" : "已更新 Prompt：\(saved.title)"
            return true
        } catch {
            message = "保存失败：请确认标题、分类与正文均不为空。"
            return false
        }
    }

    func deletePrompt(_ item: PromptItem) {
        guard let store else { return }
        do {
            try store.delete(id: item.id)
            refresh()
            message = "已删除 Prompt：\(item.title)"
        } catch {
            message = "删除失败，请刷新后重试。"
        }
    }

    @discardableResult
    func addCategory(_ name: String) -> Bool {
        guard let store else { return false }
        do {
            try store.addCategory(name)
            refresh()
            selectedCategory = name.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "已新增分类：\(selectedCategory)"
            return true
        } catch {
            message = "分类已存在或名称无效。"
            return false
        }
    }

    @discardableResult
    func renameCategory(from oldName: String, to newName: String) -> Bool {
        guard let store else { return false }
        do {
            try store.renameCategory(from: oldName, to: newName)
            let cleanNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedCategory == oldName { selectedCategory = cleanNew }
            refresh()
            message = "已重命名分类：\(oldName) → \(cleanNew)"
            return true
        } catch {
            message = "重命名失败：新名称为空或已存在同名分类。"
            return false
        }
    }

    func deleteCategory(_ name: String) {
        guard let store else { return }
        do {
            try store.deleteCategory(name)
            if selectedCategory == name { selectedCategory = Self.allCategory }
            refresh()
            message = "已删除分类「\(name)」，原有内容已保留。"
        } catch {
            message = "删除分类失败。"
        }
    }

    func openFolder() {
        guard let store else { return }
        NSWorkspace.shared.open(store.folder)
    }

    func openInEditor(_ item: PromptItem) {
        if let url = item.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Floating Popover Panel

    var isPanelVisible: Bool { panel?.isVisible == true }

    func togglePanel() {
        if isPanelVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        refresh()
        if panel == nil {
            let hosting = NSHostingView(rootView: PromptPopoverRootView(controller: self))
            let created = PromptFloatingPanel(content: hosting)
            panel = created
        }
        guard let panel else { return }
        placePanel(panel)
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    func hidePanel() {
        removeDismissMonitors()
        panel?.orderOut(nil)
    }

    func activateForInput() {
        guard let panel, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func placePanel(_ panel: NSPanel) {
        let screen = LinePanel.screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let width: CGFloat = min(760, max(560, visible.width - 80))
        let height: CGFloat = min(560, max(420, visible.height - 120))
        let x = visible.midX - width / 2
        let y = visible.maxY - height - 28
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                let onOwnedWindow = NSApp.windows.contains { $0.isVisible && NSMouseInRect(mouse, $0.frame, false) }
                if !onOwnedWindow {
                    self.hidePanel()
                }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.isPanelVisible, self.panel?.attachedSheet == nil {
                self.hidePanel()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
    }

    private func startWatching(folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

private final class PromptFloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        contentView = content
        title = "Catch what you see · Prompt 提示词库"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PromptPopoverRootView: View {
    @ObservedObject var controller: PromptController

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        PromptBrowserView(
            controller: controller,
            isPopover: true,
            onClose: { controller.hidePanel() }
        )
        .background(.ultraThinMaterial, in: shape)
        .overlay(
            shape
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.02), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        )
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.60), Color.white.opacity(0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.85
            )
            .allowsHitTesting(false)
        )
        .overlay(
            shape.stroke(Color.black.opacity(0.14), lineWidth: 0.5)
                .padding(-0.5)
                .allowsHitTesting(false)
        )
        .clipShape(shape)
        .padding(8)
    }
}

struct PromptBrowserView: View {
    @ObservedObject var controller: PromptController
    var isPopover: Bool = false
    var onClose: (() -> Void)? = nil

    @State private var editingTarget: PromptEditorDraft?
    @State private var previewingPrompt: PromptItem?
    @State private var showingCategoryManager = false

    private let columns = [
        GridItem(.adaptive(minimum: 226, maximum: 360), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            glassDivider
            categoryBar
            glassDivider
            contentGrid
            glassDivider
            footerBar
        }
        .sheet(item: $editingTarget) { draft in
            PromptEditorSheet(
                draft: draft,
                categories: controller.categories,
                onSave: { title, category, badge, content in
                    controller.savePrompt(id: draft.noteID, title: title, category: category, badge: badge, content: content)
                }
            )
        }
        .sheet(item: $previewingPrompt) { item in
            PromptPreviewSheet(
                item: item,
                onCopy: { controller.copy(item, closePanel: isPopover) },
                onEdit: {
                    previewingPrompt = nil
                    if isPopover { controller.activateForInput() }
                    editingTarget = PromptEditorDraft(item: item)
                },
                onHang: {
                    controller.onHangPrompt?(item)
                },
                onOpenFile: { controller.openInEditor(item) }
            )
        }
        .sheet(isPresented: $showingCategoryManager) {
            CategoryManagerSheet(controller: controller)
        }
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 0.5)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Prompt 提示词库")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索标题、内容或分类", text: $controller.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !controller.searchQuery.isEmpty {
                    Button {
                        controller.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
            .frame(minWidth: 170, maxWidth: 260)
            .simultaneousGesture(TapGesture().onEnded {
                if isPopover { controller.activateForInput() }
            })

            Spacer()

            Button {
                if isPopover { controller.activateForInput() }
                let defaultCategory = (controller.selectedCategory == PromptController.allCategory
                    || controller.selectedCategory == PromptController.featuredFilter)
                    ? (controller.categories.first ?? PromptStore.defaultCategoryFallback)
                    : controller.selectedCategory
                let defaultBadge = controller.selectedCategory == PromptController.featuredFilter ? PromptStore.kazikeBadge : ""
                editingTarget = PromptEditorDraft(category: defaultCategory, badge: defaultBadge)
            } label: {
                Label("新建 Prompt", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("分类管理") {
                if isPopover { controller.activateForInput() }
                showingCategoryManager = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                controller.openFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .help("在访达中打开 Prompts 文件夹")
            .controlSize(.small)

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryPill(
                    title: PromptController.allCategory,
                    count: controller.prompts.count,
                    selected: controller.selectedCategory == PromptController.allCategory
                ) {
                    controller.selectedCategory = PromptController.allCategory
                }

                if controller.hasFeaturedPrompts {
                    CategoryPill(
                        title: PromptController.featuredFilter,
                        count: controller.count(for: PromptController.featuredFilter),
                        selected: controller.selectedCategory == PromptController.featuredFilter,
                        accentOverride: Color.orange
                    ) {
                        controller.selectedCategory = PromptController.featuredFilter
                    }
                }

                ForEach(controller.categories, id: \.self) { category in
                    CategoryPill(
                        title: category,
                        count: controller.count(for: category),
                        selected: controller.selectedCategory == category
                    ) {
                        controller.selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var contentGrid: some View {
        Group {
            if controller.filteredPrompts.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(controller.prompts.isEmpty ? "还没有 Prompt，点击右上角「新建 Prompt」添加第一条" : "当前分类或搜索条件下没有匹配的 Prompt")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(controller.filteredPrompts) { item in
                            PromptCardView(
                                item: item,
                                copied: controller.copiedPromptID == item.id,
                                onCopy: {
                                    let keepOpen = NSEvent.modifierFlags.contains(.option)
                                    controller.copy(item, closePanel: isPopover && !keepOpen)
                                },
                                onPreview: { previewingPrompt = item },
                                onEdit: {
                                    if isPopover { controller.activateForInput() }
                                    editingTarget = PromptEditorDraft(item: item)
                                },
                                onHang: { controller.onHangPrompt?(item) },
                                onDelete: { controller.deletePrompt(item) }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Text(controller.message.isEmpty ? "点击卡片立即复制；按住 Option 点击可连续复制不收起" : controller.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("共 \(controller.filteredPrompts.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct CategoryPill: View {
    let title: String
    let count: Int
    let selected: Bool
    var accentOverride: Color? = nil
    let action: () -> Void

    var body: some View {
        let activeColor = accentOverride ?? Color.accentColor
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(
                Capsule().fill(
                    selected
                        ? activeColor
                        : (accentOverride?.opacity(0.14) ?? Color.white.opacity(0.09))
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.white.opacity(0.32) : Color.white.opacity(0.16),
                    lineWidth: 0.6
                )
            )
            .foregroundStyle(selected ? .white : (accentOverride ?? .primary))
            .shadow(color: selected ? activeColor.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct PromptBadgePill: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2.5)
        .background(Color.orange.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
        .foregroundStyle(Color.orange)
    }
}

private struct PromptCardView: View {
    let item: PromptItem
    let copied: Bool
    let onCopy: () -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onHang: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var activeBorder: Bool { hovering || copied }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            // 顶部胶囊锁死单行，不与悬停按钮抢占空间，保证文字行列零变化。
            HStack(spacing: 6) {
                Text(item.category)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    .foregroundStyle(.primary.opacity(0.88))

                if let badge = item.badge {
                    PromptBadgePill(text: badge)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 20)

            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)

            Text(item.content)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(4)
                .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .topLeading)

            HStack(spacing: 6) {
                if copied {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(hovering ? "点击卡片复制" : "\(item.content.count) 字")
                        .font(.system(size: 10.5, weight: hovering ? .medium : .regular))
                        .foregroundStyle(hovering ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    CardIconButton(systemName: "pin", help: "挂到顶部晾衣绳", action: onHang)
                    CardIconButton(systemName: "eye", help: "查看全文", action: onPreview)
                    CardIconButton(systemName: "pencil", help: "编辑 Prompt", action: onEdit)
                    CardIconButton(systemName: "trash", help: "删除 Prompt", action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(height: 22)
        }
        .padding(13)
        .background(.ultraThinMaterial, in: cardShape)
        .overlay(
            cardShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hovering ? 0.16 : 0.08),
                            Color.white.opacity(hovering ? 0.05 : 0.01)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        )
        .overlay(
            cardShape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(activeBorder ? 0.45 : 0.28),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        )
        .overlay(
            Group {
                if activeBorder {
                    ShimmerBorderOverlay(
                        cornerRadius: 15,
                        copied: copied,
                        isFeatured: item.badge != nil
                    )
                } else if item.badge != nil {
                    cardShape
                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.85)
                }
            }
            .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 10 : 3, y: hovering ? 4 : 1.5)
        .scaleEffect(hovering ? 1.012 : 1.0)
        .contentShape(cardShape)
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: hovering)
        .animation(.easeOut(duration: 0.18), value: copied)
    }
}

private struct ShimmerBorderOverlay: View {
    let cornerRadius: CGFloat
    let copied: Bool
    let isFeatured: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let colors: [Color] = copied
            ? [Color.green, Color.mint, Color.white.opacity(0.95), Color.green.opacity(0.55), Color.green]
            : (isFeatured
                ? [Color.orange.opacity(0.95), Color.white, Color.yellow.opacity(0.85), Color.cyan.opacity(0.65), Color.orange.opacity(0.95)]
                : [Color.white, Color.cyan.opacity(0.85), Color.indigo.opacity(0.65), Color.purple.opacity(0.55), Color.white])
        let glowColor: Color = copied ? .green : (isFeatured ? .orange : .cyan)

        shape
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: colors),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 1.5
            )
            .shadow(color: glowColor.opacity(0.38), radius: 6)
            .onAppear {
                guard !reduceMotion else { return }
                angle = 0
                withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

private struct CardIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.14), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PromptEditorDraft: Identifiable {
    let id = UUID()
    let noteID: UUID?
    var title: String
    var category: String
    var badge: String
    var content: String

    init(category: String, title: String = "", badge: String = "", content: String = "") {
        self.noteID = nil
        self.title = title
        self.category = category
        self.badge = badge
        self.content = content
    }

    init(item: PromptItem) {
        self.noteID = item.id
        self.title = item.title
        self.category = item.category
        self.badge = item.badge ?? ""
        self.content = item.content
    }
}

struct PromptEditorSheet: View {
    let draft: PromptEditorDraft
    let categories: [String]
    let onSave: (String, String, String?, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var selectedCategory: String
    @State private var customCategory: String = ""
    @State private var useCustomCategory: Bool = false
    @State private var badge: String
    @State private var content: String
    @State private var errorMessage: String = ""

    init(draft: PromptEditorDraft, categories: [String], onSave: @escaping (String, String, String?, String) -> Bool) {
        self.draft = draft
        self.categories = categories
        self.onSave = onSave
        _title = State(initialValue: draft.title)
        _selectedCategory = State(initialValue: categories.contains(draft.category) ? draft.category : (categories.first ?? PromptStore.defaultCategoryFallback))
        _badge = State(initialValue: draft.badge)
        _content = State(initialValue: draft.content)
        if !categories.contains(draft.category) && !draft.category.isEmpty {
            _useCustomCategory = State(initialValue: true)
            _customCategory = State(initialValue: draft.category)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.noteID == nil ? "新建 Prompt" : "编辑 Prompt")
                .font(.title3.weight(.semibold))

            TextField("标题（例如：第一性原理排查）", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                if !useCustomCategory {
                    Picker("分类", selection: $selectedCategory) {
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                    .frame(maxWidth: 240)
                    Button("新建分类") { useCustomCategory = true }
                } else {
                    TextField("输入新分类名称", text: $customCategory)
                        .textFieldStyle(.roundedBorder)
                    Button("选已有分类") { useCustomCategory = false }
                }
            }

            HStack {
                TextField("精选角标（可选，如：卡兹克精选）", text: $badge)
                    .textFieldStyle(.roundedBorder)
                Button(badge == PromptStore.kazikeBadge ? "取消精选" : "标为卡兹克精选") {
                    badge = (badge == PromptStore.kazikeBadge) ? "" : PromptStore.kazikeBadge
                }
            }

            Text("Prompt 正文")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $content)
                .font(.system(size: 13))
                .padding(6)
                .frame(minHeight: 165)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let finalCategory = useCustomCategory ? customCategory : selectedCategory
                    if onSave(title, finalCategory, badge, content) {
                        dismiss()
                    } else {
                        errorMessage = "请填写完整的标题、分类和 Prompt 正文。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480, height: 430)
    }
}

private struct PromptPreviewSheet: View {
    let item: PromptItem
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onHang: () -> Void
    let onOpenFile: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.category)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if let badge = item.badge {
                    PromptBadgePill(text: badge)
                }
                Text(item.title).font(.headline)
                Spacer()
                Button("打开 MD") { onOpenFile() }
            }

            ScrollView {
                Text(item.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("挂到晾衣绳") { onHang(); dismiss() }
                Button("编辑") { onEdit() }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("复制全文") { onCopy(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 420)
    }
}

private struct CategoryManagerSheet: View {
    @ObservedObject var controller: PromptController
    @Environment(\.dismiss) private var dismiss

    @State private var newCategoryName = ""
    @State private var renamingFrom: String?
    @State private var renamingTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理 Prompt 分类")
                .font(.title3.weight(.semibold))

            HStack {
                TextField("输入新分类名称", text: $newCategoryName)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    if controller.addCategory(newCategoryName) { newCategoryName = "" }
                }
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach(controller.categories, id: \.self) { category in
                    HStack {
                        if renamingFrom == category {
                            TextField("新名称", text: $renamingTo)
                                .textFieldStyle(.roundedBorder)
                            Button("确定") {
                                if controller.renameCategory(from: category, to: renamingTo) {
                                    renamingFrom = nil
                                    renamingTo = ""
                                }
                            }
                            Button("取消") { renamingFrom = nil }
                        } else {
                            Text(category)
                            Text("(\(controller.count(for: category)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("重命名") {
                                renamingFrom = category
                                renamingTo = category
                            }
                            .buttonStyle(.borderless)
                            Button("删除") {
                                controller.deleteCategory(category)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            HStack {
                Text("删除分类不会删除该分类下的 Prompt，它们会归入「未分类」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 440, height: 360)
    }
}
