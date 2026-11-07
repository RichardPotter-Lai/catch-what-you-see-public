import Foundation
import CaptureCore

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
if CommandLine.arguments.contains("--copy-selection-only") {
    do { try checkCopySelection(); exit(0) }
    catch { fputs("FAIL: unsupported AX selection has no copy fallback: \(error)\n", stderr); exit(1) }
}
let fixture = fm.temporaryDirectory.appendingPathComponent("cwsy-checks-" + UUID().uuidString)
try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) }
let library = fixture.appendingPathComponent("Library")
try fm.createDirectory(at: library, withIntermediateDirectories: true)
let files = RootedFiles(root: library)
try files.createDirectory("Notes")
let input = Data("合成内容 🌱".utf8)
try files.write(input, to: "Notes/fixture.md")
try require(try files.read("Notes/fixture.md") == input, "真实临时目录往返失败")
for path in ["../outside.md", "/tmp/outside.md"] {
    do { try files.write(input, to: path); fatalError("路径越界未被拒绝") }
    catch FileBoundaryError.outsideRoot { }
}
let outside = fixture.appendingPathComponent("outside")
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: library.appendingPathComponent("link"), withDestinationURL: outside)
do { try files.write(input, to: "link/escaped.md"); fatalError("符号链接越界未被拒绝") }
catch FileBoundaryError.outsideRoot { }
try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "写入越过了测试库")
let preferences = MemoryPreferences()
preferences.set(.string("synthetic"), for: "location")
try require(preferences.value(for: "location") == .string("synthetic"), "偏好适配失败")
preferences.set(nil, for: "location")
try require(preferences.value(for: "location") == nil, "偏好删除失败")
let fixed = Date(timeIntervalSince1970: 42)
let clock = CaptureClock(now: { fixed })
try require(clock.now() == fixed, "时钟不可注入")
print("PASS: 临时库往返、路径/符号链接隔离、内存偏好、固定时钟")
let config = try DevelopmentConfiguration(arguments: ["--development", "--library", library.path])
try require(config.library?.path == library.standardizedFileURL.path, "测试库参数丢失")
for args in [["--development"], ["--library", library.path], ["--development", "--library", "relative"]] {
    do { _ = try DevelopmentConfiguration(arguments: args); fatalError("无效参数应拒绝") }
    catch DevelopmentConfiguration.Invalid.arguments { }
}
print("PASS: 开发参数拒绝不完整或相对路径")
let sessionID = UUID()
let resumedConfig = try DevelopmentConfiguration(arguments: ["--development", "--library", library.path, "--development-session", sessionID.uuidString])
try require(resumedConfig.session == sessionID && config.session == nil, "显式会话恢复与默认隔离应分开")
for args in [["--development-session", sessionID.uuidString],
             ["--development", "--library", library.path, "--development-session"],
             ["--development", "--library", library.path, "--development-session", "local.catchwhatyousee.mac"],
             ["--development", "--library", library.path, "--development-session", sessionID.uuidString, "--development-session", sessionID.uuidString]] {
    do { _ = try DevelopmentConfiguration(arguments: args); fatalError("无效会话参数应拒绝") }
    catch DevelopmentConfiguration.Invalid.arguments { }
}
print("PASS: 开发会话恢复仅接受显式开发模式与单个 UUID，不能选生产偏好域")

struct SyntheticSelection: SelectionSource {
    let action: (Date) throws -> SelectionSnapshot
    func read(deadline: Date) throws -> SelectionSnapshot { try action(deadline) }
}
let selected = SelectionSnapshot(text: "中英 selection\n🌱", sourceID: "synthetic")
let reader = SelectionReader(source: SyntheticSelection { _ in selected })
try require(try reader.read() == selected, "选区正文应保持完整")
for failure in [SelectionFailure.permissionRequired, .secureInput, .unsupportedSelection, .timeout, .sourceExited] {
    do {
        _ = try SelectionReader(source: SyntheticSelection { _ in throw failure }).read()
        fatalError("读取错误必须保留")
    } catch let actual as SelectionFailure { try require(actual == failure, "读取错误被混淆") }
}
do {
    _ = try SelectionReader(source: SyntheticSelection { _ in SelectionSnapshot(text: " \n", sourceID: "test") }).read()
    fatalError("空选区应失败")
} catch SelectionFailure.emptySelection { }
var tick = fixed
let late = SelectionReader(source: SyntheticSelection { _ in tick = fixed.addingTimeInterval(2); return selected }, clock: CaptureClock { tick })
do { _ = try late.read(); fatalError("超时结果应丢弃") } catch SelectionFailure.timeout { }
var reads = 0
let changed = SelectionReader(source: SyntheticSelection { _ in
    reads += 1
    return SelectionSnapshot(text: "text", sourceID: reads == 1 ? "before" : "after")
})
do { _ = try changed.read(); fatalError("来源变化应失败") } catch SelectionFailure.sourceChanged { }
print("PASS: 完整选区、分类失败、超时、来源变化")

var expiredReads = 0
let expired = SelectionReader(source: SyntheticSelection { _ in expiredReads += 1; return selected }, clock: clock)
do { _ = try expired.read(timeout: 0); fatalError("零预算应超时") } catch SelectionFailure.timeout { }
try require(expiredReads == 0, "截止后不得读取来源")
for second in [
    SelectionSnapshot(text: "text", sourceID: "app", document: "other", range: "0:4"),
    SelectionSnapshot(text: "text", sourceID: "app", document: "doc", range: "8:4"),
    SelectionSnapshot(text: "else", sourceID: "app", document: "doc", range: "0:4")
] {
    var n = 0
    let changing = SelectionReader(source: SyntheticSelection { _ in
        n += 1
        return n == 1 ? SelectionSnapshot(text: "text", sourceID: "app", document: "doc", range: "0:4") : second
    })
    do { _ = try changing.read(); fatalError("文档/范围/文字变化应拒绝") }
    catch SelectionFailure.sourceChanged { }
}
var current = selected
let stableReader = SelectionReader(source: SyntheticSelection { _ in current })
let captured = try stableReader.read()
current = SelectionSnapshot(text: "different", sourceID: "different")
try require(captured == selected && captured.document == nil, "完成快照应保持原内容，未知链接留空")
print("PASS: 截止前检查、同窗文档/同控件选区竞态、不可变快照、未知链接")
try checkMarkdown()
try checkStore(fixture)
try checkRecovery(fixture)
try checkAttachments(fixture)
try checkLibrary(fixture)
try checkService()

try checkTrash(fixture)

try checkHotKey()

try checkTemporary(fixture)

try checkLease()

try checkAdversarial(fixture)

try checkRecordForgery(fixture)

try checkProcessOwnership(fixture)

try checkFuzz()
try checkCopySelection()
