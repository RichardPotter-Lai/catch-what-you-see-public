import Foundation

public struct CaptureClock {
    public let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }
}

public enum PreferenceValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
}

public protocol Preferences: AnyObject {
    func value(for key: String) -> PreferenceValue?
    func set(_ value: PreferenceValue?, for key: String)
}

/// 合成测试使用内存偏好，不连接系统截图域或 UserDefaults.standard。
public final class MemoryPreferences: Preferences {
    private var values: [String: PreferenceValue] = [:]
    public init() {}
    public func value(for key: String) -> PreferenceValue? { values[key] }
    public func set(_ value: PreferenceValue?, for key: String) { values[key] = value }
}

public protocol CaptureFiles {
    func read(_ path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
    func createDirectory(_ path: String) throws
}

public enum FileBoundaryError: Error { case outsideRoot }

/// 文件访问只接受相对于显式资料库的路径。调用方可替换整个适配器注入故障。
/// 这里防止误用路径与既有符号链接，不宣称抵御其他进程同时替换目录的攻击。
public struct RootedFiles: CaptureFiles {
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    private func resolve(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw FileBoundaryError.outsideRoot
        }
        // 逐段解析：Foundation 对尚不存在的末端文件可能保留父目录符号链接。
        var url = root
        for component in path.split(separator: "/") {
            url = url.appendingPathComponent(String(component)).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
                throw FileBoundaryError.outsideRoot
            }
        }
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw FileBoundaryError.outsideRoot
        }
        return url
    }
    public func read(_ path: String) throws -> Data { try Data(contentsOf: resolve(path)) }
    public func write(_ data: Data, to path: String) throws {
        try data.write(to: resolve(path), options: .atomic)
    }
    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: resolve(path), withIntermediateDirectories: true)
    }
}
