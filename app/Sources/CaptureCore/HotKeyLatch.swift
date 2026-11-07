/// 只在确认释放后重新武装；与采集成功、取消、焦点和权限状态无关。
public struct HotKeyLatch {
    private var held = false
    public init() {}
    public mutating func press() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }
    public mutating func observeRelease(_ released: Bool?) {
        if released == true { held = false }
    }
}
