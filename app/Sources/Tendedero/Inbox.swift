import AppKit
import CaptureCore

enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    private static let receiptKey = "screenshotOwnershipReceipt"
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CatchWhatYouSee/Screenshots", isDirectory: true)
    private static var processLease: ExclusiveProcessLease?
    private static var acquiredHere = false
    /// 恢复遗留收据前必须获得跨进程所有权，不能仅依靠运行列表快照。
    private static func ownSession() -> Bool {
        guard !AppEnvironment.isDevelopment else { return false }
        if processLease != nil { return true }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { lastError = "截图所有权目录不可用。"; return false }
        processLease = ExclusiveProcessLease(url: folder.appendingPathComponent(".owner.lock"))
        guard processLease != nil else {
            lastError = "另一实例仍持有截图所有权；本实例不会接管或还原其设置。"
            return false
        }
        return true
    }
    static var isEnabled: Bool {
        get { processLease != nil && AppEnvironment.preferences.bool(forKey: "inboxEnabled") }
        set { if ownSession() { AppEnvironment.preferences.set(newValue, forKey: "inboxEnabled") } }
    }
    /// 用户的持久选择与本进程实际持有的截图设置分开；退出还原不撤销选择。
    static var captureRequested: Bool {
        get { AppEnvironment.preferences.bool(forKey: "screenshotCaptureRequested") }
        set { AppEnvironment.preferences.set(newValue, forKey: "screenshotCaptureRequested") }
    }
    static var wasOffered: Bool {
        get { AppEnvironment.preferences.bool(forKey: "inboxOffered") }
        set { AppEnvironment.preferences.set(newValue, forKey: "inboxOffered") }
    }
    static var isApplied: Bool { processLease != nil && AppEnvironment.preferences.data(forKey: receiptKey) != nil }
    static var lastError = ""
    private static var lease: PreferenceLease {
        PreferenceLease(read: { key in
            CFPreferencesAppSynchronize(domain)
            guard let value = CFPreferencesCopyAppValue(key as CFString, domain) else { return nil }
            if let string = value as? String { return .string(string) }
            if let bool = value as? Bool { return .bool(bool) }
            return nil
        }, write: { key, value in
            let property: CFPropertyList?
            switch value { case .string(let s): property = s as CFString; case .bool(let b): property = b ? kCFBooleanTrue : kCFBooleanFalse; case nil: property = nil }
            CFPreferencesSetAppValue(key as CFString, property, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw PreferenceLease.Failure.writeFailed }
        }, load: { AppEnvironment.preferences.data(forKey: receiptKey) }, persist: { data in
            if let data { AppEnvironment.preferences.set(data, forKey: receiptKey) }
            else { AppEnvironment.preferences.removeObject(forKey: receiptKey) }
            guard AppEnvironment.preferences.synchronize() else { throw PreferenceLease.Failure.writeFailed }
        })
    }
    private static var competingOwnerRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            (app.bundleIdentifier == "app.tendedero.Tendedero" || app.bundleIdentifier == "local.catchwhatyousee.mac" || app.localizedName == "Tendedero")
        }
    }
    static func apply() {
        guard ownSession() else { return }
        let other = competingOwnerRunning
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 新收据即使只完成部分写入，也归本进程负责恢复。
            if AppEnvironment.preferences.data(forKey: receiptKey) == nil { acquiredHere = true }
            try lease.acquire(["location": .string(folder.path), "location-screenshot": .string(folder.path),
                               "location-screenrecording": .string(folder.path), "target": .string("file"),
                               "target-screenshot": .string("file"), "target-screenrecording": .string("file"),
                               "show-thumbnail": .bool(false)], otherOwnerRunning: other)
            acquiredHere = true
            lastError = ""; isEnabled = true
        } catch {
            isEnabled = false
            lastError = other ? "另一截图所有者仍在运行，请先明确交接。" : "截图接管未完成，原设置按收据保护。"
        }
    }
    /// 当前实例的收据始终可按项 CAS 还原；只有恢复历史收据才需要等待其他所有者。
    static func restoreOwnedLease(acquiredHere: inout Bool, competitor: Bool, release: () throws -> Void) throws -> Bool {
        guard acquiredHere || !competitor else { return false }
        try release()
        acquiredHere = false
        return true
    }
    static func restore() {
        guard ownSession() else { return }
        do {
            guard try restoreOwnedLease(acquiredHere: &acquiredHere, competitor: competingOwnerRunning, release: { try lease.release() }) else {
                lastError = "另一已知截图所有者仍在运行，遗留收据暂不恢复。"
                return
            }
            isEnabled = false; lastError = ""
        } catch { lastError = "部分截图设置无法还原，所有权收据已保留。" }
    }
}
