import Foundation

public enum DocumentAccess {
    public enum Failure: Error { case unsafePath }
    public static func read(_ url: URL) throws -> Data {
        var current = url.standardizedFileURL
        while current.path != "/" {
            let link = try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            // macOS 的系统路径别名；应用资料库中的链接一律拒绝。
            guard !link || ["/var", "/tmp", "/etc"].contains(current.path) else { throw Failure.unsafePath }
            current.deleteLastPathComponent()
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.unsafePath }
        return try Data(contentsOf: url)
    }
}
