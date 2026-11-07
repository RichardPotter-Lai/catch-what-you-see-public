import Foundation

public struct DevelopmentConfiguration {
    public enum Invalid: Error { case arguments }
    public let library: URL?
    public let session: UUID?
    public var enabled: Bool { library != nil }
    public init(arguments: [String]) throws {
        guard arguments.contains("--development") else {
            guard !arguments.contains("--library"), !arguments.contains("--development-session") else { throw Invalid.arguments }
            library = nil
            session = nil
            return
        }
        guard let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/") else { throw Invalid.arguments }
        library = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        if let sessionIndex = arguments.firstIndex(of: "--development-session") {
            guard arguments.filter({ $0 == "--development-session" }).count == 1,
                  sessionIndex + 1 < arguments.count, let id = UUID(uuidString: arguments[sessionIndex + 1]) else { throw Invalid.arguments }
            session = id
        } else { session = nil }
    }
}
