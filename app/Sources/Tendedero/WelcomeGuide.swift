import AppKit
import CaptureCore

/// 首次启动说明：告诉用户 Catch 在菜单栏的位置，再引导授权。
/// Catch 没有 Dock 图标，菜单栏图标又可能被刘海或其他图标挤掉，
/// 不说明的话，用户会以为应用没有启动。
@MainActor
enum WelcomeGuide {
    private static let key = "welcomeShownVersion"

    static func runOnLaunch() {
        // 等菜单栏图标和面板就绪后再弹窗。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            if AppEnvironment.preferences.string(forKey: key) == nil {
                showWelcome()
            }
            AppEnvironment.preferences.set(version, forKey: key)
            if !PermissionGuide.isTrusted { PermissionGuide.explain(reason: .launch) }
        }
    }

    static func showWelcome() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Catch what you see 已在菜单栏运行"
        alert.informativeText = """
        它没有 Dock 图标，入口在屏幕顶部菜单栏右侧的便笺图标（和应用图标同款）。

        • 选中文字，按下并松开 Option+C 收藏
        • 鼠标停在菜单栏中部，或按 Control+Option+T 拉下晾衣绳
        • 在“应用程序”里再次打开 Catch，会打开资料库

        看不到菜单栏图标？
        • 刘海屏 Mac 的菜单栏图标太多时，部分图标会被刘海挡住：按住 Command 拖动其他图标腾出位置，或用 Bartender、Ice 等工具
        • macOS 26 及更新版本：系统设置 → 菜单栏 →“允许在菜单栏中显示”，确认 Catch what you see 已打开
        """
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
