import Foundation

public struct MarkdownNote: Equatable {
    public var id: UUID
    public var operationID: UUID
    public var createdAt: String
    public var title: String
    public var excerpt: String
    public var notes: String
    public var sourceApp: String
    public var sourceURL: String
    public var sourceTitle: String
    public var attachment: String?
    public var extraMetadata: [String: String] = [:]
    public init(id: UUID, operationID: UUID, createdAt: String, title: String,
                excerpt: String, notes: String = "", sourceApp: String = "",
                sourceURL: String = "", sourceTitle: String = "", attachment: String? = nil) {
        self.id = id; self.operationID = operationID; self.createdAt = createdAt
        self.title = title; self.excerpt = excerpt; self.notes = notes
        self.sourceApp = sourceApp; self.sourceURL = sourceURL; self.sourceTitle = sourceTitle
        self.attachment = attachment
    }
}

/// 自有 YAML 字符串子集；正文是惰性文本，不交给 HTML/脚本解释器。
public enum MarkdownFormat {
    public enum Invalid: Error { case malformed, unsupported }
    private static let keys = ["id", "operation_id", "kind", "created_at", "source_app", "source_url", "source_title", "attachment"]

    static func escapeTitle(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
                || (91...96).contains(scalar.value) || (123...126).contains(scalar.value) { result += "\\" }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
    private static func unescapeTitle(_ value: String) -> String {
        var result = "", escaped = false
        for character in value {
            if escaped {
                if !character.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains($0) }) { result.append("\\") }
                result.append(character); escaped = false
            }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result += "\\" }
        return result
    }

    public static func encode(_ note: MarkdownNote) throws -> Data {
        guard !note.title.contains("\n"), !note.title.contains("\r") else { throw Invalid.unsupported }
        let values = [note.id.uuidString, note.operationID.uuidString, note.attachment == nil ? "text" : "image", note.createdAt,
                      note.sourceApp, note.sourceURL, note.sourceTitle, note.attachment ?? ""]
        var header = "---\ncwsy_version: 1\n"
        for (key, value) in zip(keys, values) {
            let escaped = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            header += "\(key): \(escaped)\n"
        }
        for key in note.extraMetadata.keys.sorted() {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  key != "cwsy_version", !keys.contains(key),
                  let raw = note.extraMetadata[key], !raw.contains("\n"), !raw.contains("\r") else { throw Invalid.unsupported }
            header += "\(key): \(raw)\n"
        }
        if let attachment = note.attachment, !validAttachment(attachment) { throw Invalid.unsupported }
        let image = note.attachment.map { "![截图](\($0))\n\n" } ?? ""
        var run = 0, longest = 0
        for scalar in note.excerpt.unicodeScalars {
            run = scalar == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        // 结构分隔换行各增加一个；读取时仅移除结构换行，保留原文所有空白。
        return Data((header + "---\n\n# \(escapeTitle(note.title))\n\n\(image)## 摘录\n\n\(fence)text\n"
            + note.excerpt + "\n\(fence)\n\n## 我的笔记\n\n" + note.notes).utf8)
    }

    static func validAttachment(_ path: String) -> Bool {
        path.range(of: #"^\.\./Attachments/[0-9a-f]{64}\.(png|jpg|jpeg|gif|tiff|heic|webp|bmp)\z"#, options: .regularExpression) != nil
    }

    public static func decode(_ data: Data) throws -> MarkdownNote {
        guard let file = String(data: data, encoding: .utf8), file.hasPrefix("---\n"),
              let headerEnd = file.range(of: "\n---\n", range: file.index(file.startIndex, offsetBy: 4)..<file.endIndex)
        else { throw Invalid.malformed }
        let header = file[file.index(file.startIndex, offsetBy: 4)..<headerEnd.lowerBound]
        var fields: [String: String] = [:], extras: [String: String] = [:]
        var seen = Set<String>()
        for line in header.components(separatedBy: "\n") {
            guard let separator = line.range(of: ": ") else { throw Invalid.malformed }
            let key = String(line[..<separator.lowerBound])
            guard seen.insert(key).inserted else { throw Invalid.malformed }
            let raw = String(line[separator.upperBound...])
            if key == "cwsy_version" { fields[key] = raw }
            else {
                guard keys.contains(key) else {
                    guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw Invalid.unsupported }
                    extras[key] = raw
                    continue
                }
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { throw Invalid.unsupported }
                fields[key] = decoded
            }
        }
        guard fields["cwsy_version"] == "1", ["text", "image"].contains(fields["kind"] ?? "") else { throw Invalid.unsupported }
        guard let id = fields["id"].flatMap(UUID.init(uuidString:)),
              let operation = fields["operation_id"].flatMap(UUID.init(uuidString:)),
              let date = fields["created_at"], ISO8601DateFormatter().date(from: date) != nil,
              let app = fields["source_app"], let url = fields["source_url"], let sourceTitle = fields["source_title"]
        else { throw Invalid.malformed }
        let body = String(file[headerEnd.upperBound...])
        guard body.hasPrefix("\n# "), let titleEnd = body.range(of: "\n\n## 摘录\n\n") else { throw Invalid.malformed }
        var title = String(body[body.index(body.startIndex, offsetBy: 3)..<titleEnd.lowerBound])
        let attachment = fields["attachment"].flatMap { $0.isEmpty ? nil : $0 }
        if fields["kind"] == "image" {
            guard let path = attachment, validAttachment(path), title.hasSuffix("\n\n![截图](\(path))") else { throw Invalid.unsupported }
            title = String(title.dropLast("\n\n![截图](\(path))".count))
        } else if attachment != nil { throw Invalid.malformed }
        guard !title.contains("\n"), !title.contains("\r") else { throw Invalid.unsupported }
        let excerptPart = String(body[titleEnd.upperBound...])
        guard let openerEnd = excerptPart.firstIndex(of: "\n") else { throw Invalid.malformed }
        let opener = String(excerptPart[..<openerEnd])
        guard opener.hasSuffix("text") else { throw Invalid.unsupported }
        let fence = String(opener.dropLast(4))
        guard fence.count >= 3, fence.allSatisfy({ $0 == "`" }) else { throw Invalid.malformed }
        // 按 UTF-8 字节识别结构分隔符，避免原文尾部 CR 与结构 LF
        // 合成一个 Swift Character 后，字符串搜索无法定位该 LF。
        let excerptBytes = Data(excerptPart.utf8)
        guard let newline = excerptBytes.firstIndex(of: 10) else { throw Invalid.malformed }
        let start = newline + 1
        let marker = Data("\n\(fence)\n\n## 我的笔记\n\n".utf8)
        guard let end = excerptBytes.range(of: marker, in: start..<excerptBytes.endIndex),
              let excerpt = String(data: excerptBytes[start..<end.lowerBound], encoding: .utf8),
              let notes = String(data: excerptBytes[end.upperBound...], encoding: .utf8) else { throw Invalid.malformed }
        var note = MarkdownNote(id: id, operationID: operation, createdAt: date, title: unescapeTitle(title),
                            excerpt: excerpt, notes: notes,
                            sourceApp: app, sourceURL: url, sourceTitle: sourceTitle, attachment: attachment)
        note.extraMetadata = extras
        return note
    }
}
