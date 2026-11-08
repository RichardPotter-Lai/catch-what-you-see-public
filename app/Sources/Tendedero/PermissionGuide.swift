import AppKit
import ApplicationServices

/// 引导用户完成“辅助功能”授权。
///
/// Option+C 读取其他应用的选区需要辅助功能权限。以前只在采集失败时闪过
/// 半秒提示，用户很难发现要去哪里授权。现在：
/// - 首次启动、或按 Option+C 时发现未授权，弹出说明窗口；
/// - 用户点“去授权”后，调用系统授权请求（把本应用加入权限列表并弹出系统提示），
///   同时打开对应的系统设置页面；
/// - 之后轮询授权状态，打开开关后立即提示“已授权”，不需要重启应用。
@MainActor
enum PermissionGuide {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var alertShowing = false
    private static var pollTimer: Timer?
    private static var lastPromptAt = Date.distantPast
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// 采集时发现没有权限：弹出说明（短时间内重复按快捷键不重复弹窗）。
    static func captureNeedsPermission() {
        guard Date().timeIntervalSince(lastPromptAt) > 3 else { return }
        explain(reason: .capture)
    }

    enum Reason { case launch, capture, menu }

    static func explain(reason: Reason) {
        guard !alertShowing else { return }
        if isTrusted {
            if reason == .menu { showGranted() }
            return
        }
        alertShowing = true
        lastPromptAt = Date()
        defer { alertShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = reason == .capture
            ? "Option+C 需要“辅助功能”权限才能收藏选中的文字"
            : "允许 Catch what you see 读取选中的文字"
        alert.informativeText = """
        在微信、浏览器等应用里按 Option+C 收藏文字，需要 macOS 的“辅助功能”权限。

        点“去授权”后：
        1. 系统会弹出提示，选择“打开系统设置”；
        2. 在“隐私与安全性 → 辅助功能”列表中，打开 Catch what you see 的开关（macOS 27 中这一项叫“设备控制和数据访问”）；
        3. 按提示输入密码或使用 Touch ID。

        如果列表里已有 Catch 且开关已打开仍不生效（通常发生在升级后），请先选中旧条目点“−”删除，再点“+”重新添加“应用程序”中的 Catch what you see。

        打开开关后这里会自动生效，不需要重启应用。Catch 只在你主动按快捷键时读取选区，不会上传任何内容。
        """
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        request()
    }

    /// 调用系统授权请求，并打开系统设置的对应页面，然后等待用户打开开关。
    static func request() {
        // 带 prompt 选项时，系统会把本应用加入辅助功能列表（默认关闭）并弹出系统提示。
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(settingsURL)
        startPolling()
    }

    private static func startPolling() {
        pollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(600)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if isTrusted {
                    timer.invalidate(); pollTimer = nil
                    showGranted()
                } else if Date() > deadline {
                    timer.invalidate(); pollTimer = nil
                }
            }
        }
    }

    private static func showGranted() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "已获得辅助功能权限"
        alert.informativeText = "现在可以在任意应用中选中文字，按下并松开 Option+C 收藏。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
