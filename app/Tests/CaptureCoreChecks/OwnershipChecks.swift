import Foundation
import CaptureCore

func checkProcessOwnership(_ root: URL) throws {
    let lock = root.appendingPathComponent("ownership-test.lock")
    var owner = ExclusiveProcessLease(url: lock)
    try require(owner != nil, "首个实例取得所有权")
    try require(ExclusiveProcessLease(url: lock) == nil, "第二实例不得获得恢复权限")
    func childAttempt() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(2)\nsys.exit(0)", lock.path]
        try child.run(); child.waitUntilExit()
        return child.terminationStatus
    }
    try require(try childAttempt() == 2, "另一实际进程不得取得活实例收据")
    owner = nil
    try require(try childAttempt() == 0, "原实例释放后才可恢复收据")
    print("PASS: 活实例跨进程锁保护；第二实例不得恢复/覆盖其收据；释放后恢复可用")
}
