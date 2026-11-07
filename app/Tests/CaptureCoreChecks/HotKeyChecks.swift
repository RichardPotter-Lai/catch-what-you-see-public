import CaptureCore

func checkHotKey() throws {
    var key = HotKeyLatch()
    try require(key.press(), "首次按下")
    try require(!key.press(), "自动重复忽略")
    key.observeRelease(nil)
    try require(!key.press(), "释放丢失或状态未知不重新武装")
    key.observeRelease(false)
    try require(!key.press(), "焦点变化/权限提示时仍按住")
    key.observeRelease(true)
    try require(key.press(), "确认释放后下一主动动作")
    try require(!key.press(), "采集完成/取消不重置按键")
    print("PASS: 热键按住去重、未知释放保守拒绝、真实释放重新武装")
}
