import Foundation
import Darwin

/// 整个所有者进程生命周期持有非阻塞文件锁；崩溃后由内核释放。
/// 锁文件不可删除或替换，否则不同进程可能锁住不同 inode。
public final class ExclusiveProcessLease {
    private var descriptor: Int32
    public init?(url: URL) {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
