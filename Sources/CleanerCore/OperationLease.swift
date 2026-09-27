import Foundation
import Darwin

/// One advisory lock per Home shared by every GUI/CLI mutation. Never unlink the lock file.
final class OperationLease {
    private let descriptor: Int32
    static func acquire(files: FileOperations) throws -> OperationLease? {
        guard files is RealFileOperations else { return nil }
        try V2Paths.ensureDataDirectory(home: files.homeDirectory(), files: files)
        return try OperationLease(home: files.homeDirectory())
    }
    private init(home: String) throws {
        let path = V2Paths.dataDirectory(home: home) + "/operation.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOpError.posix(path: path, errno: errno, context: "打开操作锁") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1,
              (st.st_mode & S_IFMT) == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FileOpError.posix(path: path, errno: EBUSY, context: "已有任务运行或操作锁不安全，请稍后重试")
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
