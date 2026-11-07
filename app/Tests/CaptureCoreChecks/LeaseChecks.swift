import Foundation
import CaptureCore

func checkLease() throws {
    var values: [String: PreferenceLease.Value] = ["location": .string("original")]
    var receipt: Data?
    var failing = false
    let lease = PreferenceLease(read: { values[$0] }, write: { key, value in
        if failing && key == "thumbnail" { throw PreferenceLease.Failure.writeFailed }; values[key] = value
    }, load: { receipt }, persist: { receipt = $0 })
    let desired: [String: PreferenceLease.Value] = ["location": .string("owned"), "thumbnail": .bool(false)]
    do { try lease.acquire(desired, otherOwnerRunning: true); fatalError("另一所有者运行应拒绝") } catch PreferenceLease.Failure.ownerRunning { }
    try require(receipt == nil && values["location"] == .string("original"), "拒绝接管不写设置")
    try lease.acquire(desired, otherOwnerRunning: false)
    values["location"] = .string("user-new")
    try lease.release()
    try require(values["location"] == .string("user-new") && values["thumbnail"] == nil, "逐项保留用户修改并恢复缺省")
    failing = true
    do { try lease.acquire(desired, otherOwnerRunning: false); fatalError("注入写入失败") } catch PreferenceLease.Failure.writeFailed { }
    try require(values["location"] == .string("user-new"), "部分失败回滚已写项目")
    failing = false
    try lease.acquire(desired, otherOwnerRunning: false)
    let restarted = PreferenceLease(read: { values[$0] }, write: { values[$0] = $1 }, load: { receipt }, persist: { receipt = $0 })
    try restarted.release()
    try require(values["location"] == .string("user-new") && receipt == nil, "崩溃后收据恢复")
    try restarted.release()
    try require(values["location"] == .string("user-new"), "过期收据不改设置")
    print("PASS: 截图所有权拒绝、逐项还原、用户中途修改、部分失败回滚、崩溃/过期收据")
}
