import Foundation
import CaptureCore

enum AppEnvironment {
    // main 在创建 AppDelegate / Line 之前解析；无效参数不允许进入应用生命周期。
    static var development: DevelopmentConfiguration!
    static var isDevelopment: Bool { development.enabled }
    static let preferences: UserDefaults = {
        // 正常 app 身份必须使用 standard；macOS 拒绝以自身 bundle ID 创建 suite。
        guard isDevelopment else { return UserDefaults.standard }
        let suite = "local.catchwhatyousee.test." + (development.session ?? UUID()).uuidString
        return UserDefaults(suiteName: suite)!
    }()
    static var library: URL {
        resolveLibrary(developmentLibrary: development.library,
                       selectedPath: preferences.string(forKey: "libraryPath"),
                       applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
    static func resolveLibrary(developmentLibrary: URL?, selectedPath: String?, applicationSupport: URL) -> URL {
        if let developmentLibrary { return developmentLibrary }
        if let selectedPath, !selectedPath.isEmpty { return URL(fileURLWithPath: selectedPath, isDirectory: true) }
        return applicationSupport.appendingPathComponent("CatchWhatYouSee/Library", isDirectory: true)
    }
}
