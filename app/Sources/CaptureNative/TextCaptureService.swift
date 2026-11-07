import AppKit

/// 只消费本次 Services 提供的 pasteboard，不读取共享剪贴板，不返回替换文本。
public final class TextCaptureService: NSObject {
    private let submit: (String) throws -> Void
    public init(submit: @escaping (String) throws -> Void) { self.submit = submit }

    @objc public func collectText(_ pasteboard: NSPasteboard, userData: String?, error outputError: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            outputError.pointee = "未收藏：来源没有提供文字。"; return
        }
        do { try submit(text); outputError.pointee = nil }
        catch { outputError.pointee = "未保存：请检查资料库位置和文件状态后重试。" }
    }
}
