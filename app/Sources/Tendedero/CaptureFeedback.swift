import AppKit
import SwiftUI

/// 只显示操作结果，不显示选区正文；不夺取来源窗口焦点。
@MainActor
final class CaptureFeedback {
    static let shared = CaptureFeedback()
    private var panel: FeedbackPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, detail: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        guard let screen = LinePanel.screenUnderPointer() else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - 220, y: screen.visibleFrame.maxY - 115, width: 440, height: 95)
        let panel = FeedbackPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Catch what you see · 采集反馈"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).lineLimit(3)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .frame(width: 440, height: 95).background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        self.panel = panel
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            panel.orderOut(nil)
            self.panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
