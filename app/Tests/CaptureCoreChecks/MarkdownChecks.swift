import Foundation
import CaptureCore

func checkMarkdown() throws {
    let samples = ["", "中文 English 🌱", " leading\n\ntrailing \n", "```swift\nlet x = 1\n```", "# title\n## 我的笔记\n---\n<script>alert(1)</script>", "a\r\nb\rc\n", "``````\n~~~\n\t", "\u{0000}end"]
    for text in samples {
        let original = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "合成 <script>alert(1)</script> `*\\标题", excerpt: text, notes: "用户\n备注\n", sourceApp: "", sourceURL: "", sourceTitle: "引号 \" 和 \\ 路径")
        let data = try MarkdownFormat.encode(original)
        try require(try MarkdownFormat.decode(data) == original, "Markdown 应完整往返")
        try require(!String(decoding: data, as: UTF8.self).contains("# 合成 <script>"), "标题 HTML 必须作为文本")
        try require(String(data: data, encoding: .utf8)?.contains("## 摘录") == true, "文档应可读")
    }
    let original = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-02T16:00:00Z", title: "合成", excerpt: "keep", notes: "old")
    let file = try MarkdownFormat.encode(original)
    let changed = String(decoding: file, as: UTF8.self).replacingOccurrences(of: "\nold", with: "\nnew")
    try require(try MarkdownFormat.decode(Data(changed.utf8)).notes == "new", "备注应可外部编辑")
    let externalTitle = String(decoding: file, as: UTF8.self).replacingOccurrences(of: "# 合成", with: "# 路径\\query")
    try require(try MarkdownFormat.decode(Data(externalTitle.utf8)).title == "路径\\query", "外部标题非转义反斜线保留")
    do { _ = try MarkdownFormat.decode(Data("not a note".utf8)); fatalError("损坏文档应拒绝") }
    catch MarkdownFormat.Invalid.malformed { }
    print("PASS: Markdown 特殊字符/空出处/换行往返、备注外部编辑、损坏文件拒绝")
}
