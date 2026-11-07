import AppKit
import CaptureNative

func checkService() throws {
    let board = NSPasteboard(name: .init("local.catchwhatyousee.test." + UUID().uuidString))
    defer { board.releaseGlobally() }
    var received: [String] = []
    let service = TextCaptureService { received.append($0) }
    try require(service.responds(to: NSSelectorFromString("collectText:userData:error:")), "Services 必须暴露系统要求的 Objective-C 入口")
    var error: NSString?
    service.collectText(board, userData: nil, error: &error)
    try require(error != nil && received.isEmpty, "空服务载荷必须失败")
    board.clearContents()
    let text = "合成服务\nexact text 🌱"
    board.setString(text, forType: .string)
    error = nil
    service.collectText(board, userData: nil, error: &error)
    try require(error == nil && received == [text], "完整服务文本进入采集")
    try require(board.string(forType: .string) == text, "不能替换服务来源文本")
    let failing = TextCaptureService { _ in throw NSError(domain: "synthetic-save", code: 1) }
    failing.collectText(board, userData: nil, error: &error)
    try require(error != nil && board.string(forType: .string) == text, "保存失败不清空来源")
    print("PASS: 独立 pasteboard 文本服务、空载荷/保存失败、来源文本保留")
}
