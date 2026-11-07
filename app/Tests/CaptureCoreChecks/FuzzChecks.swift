import Foundation
import CaptureCore

func checkFuzz() throws {
    var state: UInt64 = 0xC47C20261103
    func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
    let alphabet = Array("中文🌱é\\`~<>[]{}:#*\"'\t\n\r abc0123")
    for _ in 0..<500 {
        let body = String((0..<Int(next() % 256)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
        let note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "模糊测试 \\ <script> ` []", excerpt: body, notes: body)
        try require(try MarkdownFormat.decode(MarkdownFormat.encode(note)) == note, "随机 Unicode/围栏/转义完整往返")
    }
    for _ in 0..<2000 {
        let bytes = Data((0..<Int(next() % 512)).map { _ in UInt8(truncatingIfNeeded: next() >> 32) })
        _ = try? MarkdownFormat.decode(bytes)
    }
    for path in ["../../outside.png", "file:///tmp/image.png", "../Attachments/../../outside", "../Attachments/" + String(repeating: "a", count: 64) + ".png\n", "../Attachments/" + String(repeating: "a", count: 64) + ".png/child"] {
        let note = MarkdownNote(id: UUID(), operationID: UUID(), createdAt: "2026-11-03T00:00:00Z", title: "攻击", excerpt: "", attachment: path)
        let accepted = (try? MarkdownFormat.decode(MarkdownFormat.encode(note))) != nil
        try require(!accepted, "恶意附件引用拒绝")
    }
    print("PASS: 固定种子 500 组随机往返、2000 组畸形输入与恶意附件引用")
}
