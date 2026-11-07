import Foundation
import CaptureCore

func checkCopySelection() throws {
    let expected = SelectionSnapshot(text: "微信与网页的合成选区\nCopy fixture 🌱", sourceID: "local.synthetic.source")
    var copies = 0
    let capture = SelectionCapture(direct: { throw SelectionFailure.unsupportedSelection }, copy: {
        copies += 1; return expected
    })
    try require(try capture.read() == expected && copies == 1,
                "不公开 AX 选区但可复制的内容应通过受控后备取得")
    print("PASS: AX unsupported but copyable selection reaches capture")

    for failure in [SelectionFailure.unsupportedSelection, .emptySelection, .timeout] {
        var calls = 0
        let reader = SelectionCapture(direct: { throw failure }, copy: { calls += 1; return expected })
        try require(try reader.read() == expected && calls == 1, "可复制的选区失败应走一次后备")
        do { _ = try reader.read(allowCopyFallback: false); throw CopyFixtureFailure.expectedFailure }
        catch let error as SelectionFailure { try require(error == failure && calls == 1, "关闭后备应保留原失败") }
    }
    for failure in [SelectionFailure.permissionRequired, .secureInput, .sourceChanged, .sourceExited] {
        var calls = 0
        do {
            _ = try SelectionCapture(direct: { throw failure }, copy: { calls += 1; return expected }).read()
            throw CopyFixtureFailure.expectedFailure
        } catch let error as SelectionFailure { try require(error == failure && calls == 0, "危险/失效来源不得复制后备") }
    }
    copies = 0
    let direct = SelectionCapture(direct: { expected }, copy: { copies += 1; return expected })
    try require(try direct.read() == expected && copies == 0, "原生成功不得碰剪贴板")

    let success = CopyFixture()
    success.clip = CopyFixture.payload(7, "old", extra: ["public.rtf": Data([1,2,3])])
    let old = success.clip.items
    let saved = try CopySelectionTransaction(access: success).read()
    try require(saved.text == CopyFixture.text && saved.sourceID == success.sourceID && saved.clipboardRestoration == .restored,
                "新复制内容应完整返回并记录恢复结果")
    try require(success.clip.items == old && success.copyCalls == 1 && success.restoreCalls == 1, "富文本剪贴板应恢复所有类型")

    let unchanged = CopyFixture(); unchanged.copyAction = { _ in }
    try failCopy(.noFreshText) { try CopySelectionTransaction(access: unchanged).read(timeout: 0.08) }
    try require(unchanged.restoreCalls == 0 && unchanged.clip.text == "old", "禁止读取旧剪贴板冒充选区")

    let sameText = CopyFixture(); sameText.copyAction = { f in f.clip = CopyFixture.payload(f.clip.changeCount + 1, "old") }
    try require(try CopySelectionTransaction(access: sameText).read().text == "old", "相同文字但新复制版本应可收藏")

    let nonText = CopyFixture(); nonText.copyAction = { f in
        f.clip = CopyClipboardSnapshot(changeCount: 9, items: [["public.png":Data([1])]], text: nil)
    }
    try failCopy(.noFreshText) { try CopySelectionTransaction(access: nonText).read() }
    try require(nonText.clip.text == "old" && nonText.restoreCalls == 1, "图片结果不能变文字笔记且应恢复原剪贴板")

    let privateOld = CopyFixture()
    privateOld.clip = CopyClipboardSnapshot(changeCount: 1, items: [], text: nil, protected: true)
    try failCopy(.protectedClipboard) { try CopySelectionTransaction(access: privateOld).read() }
    try require(privateOld.copyCalls == 0, "原剪贴板受保护时不得开始复制")

    let privateNew = CopyFixture(); privateNew.copyAction = { f in
        f.clip = CopyClipboardSnapshot(changeCount: 9, items: [], text: nil, protected: true)
    }
    try failCopy(.protectedClipboard) { try CopySelectionTransaction(access: privateNew).read() }
    try require(privateNew.clip.text == "old", "不保存复制的新受保护内容")

    let newer = CopyFixture(); newer.onWait = { f in
        if f.copyCalls > 0 { f.clip = CopyFixture.payload(25, "newer user copy") }
    }
    try failCopy(.clipboardChanged) { try CopySelectionTransaction(access: newer).read() }
    try require(newer.clip.text == "newer user copy", "不得用旧快照覆盖后来复制")

    let restoreRace = CopyFixture(); restoreRace.beforeRestore = { f in
        f.clip = CopyFixture.payload(30, "later copy")
    }
    let raceResult = try CopySelectionTransaction(access: restoreRace).read()
    try require(raceResult.text == CopyFixture.text && raceResult.clipboardRestoration == .newerContentPreserved
                && restoreRace.clip.text == "later copy", "恢复前的新复制应保留")

    let restoreFailure = CopyFixture(); restoreFailure.failRestore = true
    try require(try CopySelectionTransaction(access: restoreFailure).read().clipboardRestoration == .failed,
                "恢复失败必须反馈而非谎称已恢复")

    let initialRace = CopyFixture(); initialRace.onSnapshot = { f in
        if f.copyCalls == 0 { f.clip = CopyFixture.payload(11,"newer") }
    }
    try failCopy(.clipboardChanged) { try CopySelectionTransaction(access: initialRace).read() }
    try require(initialRace.copyCalls == 0, "备份期间变化不得发出复制")

    let freshRace = CopyFixture(); freshRace.onSnapshot = { f in
        if f.copyCalls > 0 { f.clip = CopyFixture.payload(12,"newer") }
    }
    try failCopy(.clipboardChanged) { try CopySelectionTransaction(access: freshRace).read() }
    try require(freshRace.clip.text == "newer", "取字期间变化不覆盖新内容")

    let held = CopyFixture(); held.triggeringKeysReleased = false
    try failCopy(.keysStillHeld) { try CopySelectionTransaction(access: held).read(releaseTimeout: 0.06) }
    try require(held.copyCalls == 0 && held.snapshotCalls == 0, "按键未松开不得复制或备份")
    let released = CopyFixture(); released.triggeringKeysReleased = false
    released.onWait = { f in if f.waits == 3 { f.triggeringKeysReleased = true } }
    try require(try CopySelectionTransaction(access: released).read().text == CopyFixture.text, "松开后才复制")

    let sourceRace = CopyFixture(); sourceRace.onWait = { f in
        if f.copyCalls > 0 { f.sourceFailure = .sourceChanged }
    }
    do { _ = try CopySelectionTransaction(access: sourceRace).read(); throw CopyFixtureFailure.expectedFailure }
    catch SelectionFailure.sourceChanged { }
    try require(sourceRace.restoreCalls == 1, "已识别复制版本失败时安全恢复")
    print("PASS: controlled copy eligibility, freshness, full restore, protected data, focus/clipboard races and key release")
}

private enum CopyFixtureFailure: Error { case expectedFailure }
private func failCopy(_ expected: CopySelectionFailure, _ body: () throws -> SelectionSnapshot) throws {
    do { _ = try body(); throw CopyFixtureFailure.expectedFailure }
    catch let failure as CopySelectionFailure { try require(failure == expected, "复制失败类型不符") }
}

private final class CopyFixture: CopySelectionAccess {
    static let text = "新复制的合成文字\nWechat / Web 🌱"
    var now = Date(timeIntervalSince1970: 0)
    var clip = payload(1,"old")
    var changeCount: Int { clip.changeCount }
    var triggeringKeysReleased = true
    let sourceID = "local.synthetic.source"
    var sourceFailure: SelectionFailure?
    var copyCalls = 0, restoreCalls = 0, snapshotCalls = 0, waits = 0
    var failRestore = false
    var onWait: ((CopyFixture) -> Void)?
    var onSnapshot: ((CopyFixture) -> Void)?
    var beforeRestore: ((CopyFixture) -> Void)?
    var copyAction: (CopyFixture) -> Void = { f in f.clip = payload(f.changeCount + 1,text) }
    static func payload(_ version: Int, _ text: String, extra: [String:Data] = [:]) -> CopyClipboardSnapshot {
        var item = extra; item["public.utf8-plain-text"] = Data(text.utf8)
        return CopyClipboardSnapshot(changeCount: version, items: [item], text: text)
    }
    func validateSource() throws { if let sourceFailure { throw sourceFailure } }
    func snapshot() throws -> CopyClipboardSnapshot {
        snapshotCalls += 1
        let result = clip; onSnapshot?(self); return result
    }
    func requestCopy() throws { copyCalls += 1; copyAction(self) }
    func restore(_ original: CopyClipboardSnapshot, ifUnchanged version: Int) -> ClipboardRestoration {
        restoreCalls += 1; beforeRestore?(self)
        guard changeCount == version else { return .newerContentPreserved }
        guard !failRestore else { return .failed }
        clip = CopyClipboardSnapshot(changeCount: version + 1, items: original.items, text: original.text)
        return .restored
    }
    func waitBriefly() { now.addTimeInterval(0.02); waits += 1; onWait?(self) }
}
