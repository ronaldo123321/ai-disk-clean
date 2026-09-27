import Foundation
import Darwin

// MARK: - 文件操作抽象（spec §10：引擎可测性的关键）

public struct FileAttributes: Codable, Equatable, Sendable {
    public var isSymbolicLink: Bool
    public var isDirectory: Bool
    public var isRegularFile: Bool
    /// 逻辑大小（stat st_size；目录为 0，符号链接为链接路径长度）
    public var size: Int64
    /// 磁盘占用（st_blocks × 512，du 口径）。稀疏 / clonefile 文件以占用为准，避免 Docker.raw 这类
    /// 逻辑大小虚高到超过整盘的误导展示。
    public var allocatedSize: Int64
    public var modificationDate: Date?
    public var device: UInt64?
    public var inode: UInt64?
    public var modificationStamp: String?
    /// 硬链接数（st_nlink）；内存实现为 nil。用于可释放量估算。
    public var linkCount: UInt32?

    public init(isSymbolicLink: Bool, isDirectory: Bool, isRegularFile: Bool,
                size: Int64, allocatedSize: Int64? = nil, modificationDate: Date?, device: UInt64? = nil, inode: UInt64? = nil, modificationStamp: String? = nil, linkCount: UInt32? = nil) {
        self.isSymbolicLink = isSymbolicLink
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.size = size
        self.allocatedSize = allocatedSize ?? size
        self.modificationDate = modificationDate
        self.device = device
        self.inode = inode
        self.modificationStamp = modificationStamp
        self.linkCount = linkCount
    }
}

extension FileAttributes {
    public static func == (lhs: FileAttributes, rhs: FileAttributes) -> Bool {
        lhs.matches(rhs) && lhs.allocatedSize == rhs.allocatedSize
    }

    func matches(_ other: FileAttributes) -> Bool {
        isSymbolicLink == other.isSymbolicLink && isDirectory == other.isDirectory
            && isRegularFile == other.isRegularFile && size == other.size
            && device == other.device && inode == other.inode
            && (modificationStamp != nil ? modificationStamp == other.modificationStamp : modificationDate == other.modificationDate)
    }
}

public enum FileOpError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case refuseSymlink(String)
    case posix(path: String, errno: Int32, context: String)

    public var description: String {
        switch self {
        case .notFound(let p): return "\(p) 不存在"
        case .refuseSymlink(let p): return "拒绝通过符号链接操作：\(p)"
        case .posix(let p, let e, let ctx): return "\(ctx) 失败：\(p)（errno \(e)）"
        }
    }
}

public protocol FileOperations: AnyObject {
    func homeDirectory() -> String

    /// lstat 语义：不解析符号链接；不存在返回 nil（坏链接返回其自身属性）。
    func attributesIfExist(atPath path: String) -> FileAttributes?
    func realPath(ofPath path: String) -> String?
    /// 直接子项的完整路径，按末段名排序。
    func childrenOfDirectory(atPath path: String) throws -> [String]
    /// lstat 语义的存在性（坏符号链接也算存在）。
    func fileExists(_ path: String) -> Bool

    /// 删除文件 / 符号链接（仅 unlink link 本身）/ 目录（递归，但目录内的符号链接同样只删链接）。
    func removeItem(atPath path: String) throws
    func moveItem(fromPath: String, toPath: String) throws
    /// 经系统废纸篓服务移入；返回实际落位路径（测试注入时为 <home>/.Trash）
    func trashItem(atPath path: String) throws -> String
    func createDirectory(atPath path: String, intermediate: Bool) throws
    /// 清空文件内容。符号链接一律拒绝（truncate 会跟随链接改写目标，属于第 2 层围栏红线）。
    func truncateFile(atPath path: String) throws

    func writeFile(_ data: Data, toPath path: String) throws
    func readFile(atPath path: String) -> Data?
    /// 文件末尾最多 maxBytes 字节（追加型日志的完整性检查用，避免为看尾部而读全量）。
    func tailBytes(atPath path: String, maxBytes: Int) -> Data?
    /// 追加写入（审计日志用）；文件不存在则创建。
    func appendFile(_ data: Data, toPath path: String) throws

    /// 所在卷容量摘要；内存实现返回 nil。
    func volumeSummary(atPath path: String) -> DiskSummary?
}

extension FileOperations {
    /// 默认实现：读全量后截取。内存实现的假文件树很小，够用；RealFileOperations 覆写为 lseek 定位。
    public func tailBytes(atPath path: String, maxBytes: Int) -> Data? {
        readFile(atPath: path).map { Data($0.suffix(maxBytes)) }
    }

    /// 目录表观大小（du 口径）：递归累加文件磁盘占用；符号链接按 lstat 计，不跟随。
    /// 并行 BFS：按层并发 stat（大目录树的主要耗时是等待元数据返回）。
    /// 语义与串行版一致：du 口径、符号链接只计自身、无法读取的目录经 onUnreadable 上报。
    func apparentSize(of path: String, cancellation: OperationCancellation? = nil,
                      onUnreadable: ((String, Error) -> Void)? = nil) -> Int64 {
        guard let attrs = attributesIfExist(atPath: path) else { return 0 }
        if !attrs.isDirectory || attrs.isSymbolicLink { return attrs.allocatedSize }
        let lock = NSLock()
        var total: Int64 = 0
        var unreadable: [(String, Error)] = []
        var frontier: [String] = [path]
        while !frontier.isEmpty {
            if cancellation?.isCancelled == true { break }
            let level = frontier
            frontier = []
            let subdirs = MutexBox([[String]](repeating: [], count: level.count))
            // concurrentPerform 自身已按活动核数限制并发；再套一层信号量只会阻塞它的工作线程。
            DispatchQueue.concurrentPerform(iterations: level.count) { index in
                let dir = level[index]
                let children: [String]
                do { children = try self.childrenOfDirectory(atPath: dir) }
                catch {
                    if case FileOpError.notFound = error { return } // 扫描期间消失属正常波动
                    lock.lock(); unreadable.append((dir, error)); lock.unlock()
                    return
                }
                var own: [String] = []
                // 本目录先局部累加，整目录只抢一次锁；逐文件加锁在大目录树上是主要的争用来源。
                var localTotal: Int64 = 0
                for child in children {
                    guard let attributes = self.attributesIfExist(atPath: child) else { continue }
                    if attributes.isDirectory && !attributes.isSymbolicLink {
                        own.append(child)
                    } else {
                        localTotal += attributes.allocatedSize
                    }
                }
                lock.lock(); total += localTotal; lock.unlock()
                subdirs.withLock { $0[index] = own }
            }
            frontier = subdirs.value.flatMap { $0 }
        }
        for (dir, error) in unreadable { onUnreadable?(dir, error) }
        return total
    }
}

// MARK: - 真实实现（lstat / realpath / unlink，绝不跟随符号链接删除）

public final class RealFileOperations: FileOperations {
    private let homeOverride: String?

    /// - Parameter home: 注入 home 供测试使用临时目录；默认取当前用户 home。
    public init(home: String? = nil) {
        self.homeOverride = home
    }

    public func homeDirectory() -> String { homeOverride ?? NSHomeDirectory() }

    private func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st
    }

    public func attributesIfExist(atPath path: String) -> FileAttributes? {
        guard let st = lstatInfo(path) else { return nil }
        let mode = st.st_mode
        let mtime = Date(timeIntervalSince1970:
            TimeInterval(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileAttributes(
            isSymbolicLink: (mode & S_IFMT) == S_IFLNK,
            isDirectory: (mode & S_IFMT) == S_IFDIR,
            isRegularFile: (mode & S_IFMT) == S_IFREG,
            size: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationDate: mtime, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), modificationStamp: "\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)",
            linkCount: UInt32(st.st_nlink))
    }

    public func realPath(ofPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func childrenOfDirectory(atPath path: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        return names.sorted().map { path.hasSuffix("/") ? path + $0 : path + "/" + $0 }
    }

    public func fileExists(_ path: String) -> Bool {
        lstatInfo(path) != nil
    }

    public func removeItem(atPath path: String) throws {
        try SafeDirectory.remove(path)
    }

    public func moveItem(fromPath: String, toPath: String) throws {
        let source = try SafeDirectory.parent(of: fromPath)
        defer { close(source.fd) }
        let destination = try SafeDirectory.parent(of: toPath)
        defer { close(destination.fd) }
        guard renameatx_np(source.fd, source.name, destination.fd, destination.name, UInt32(RENAME_EXCL)) == 0 else {
            throw FileOpError.posix(path: toPath, errno: errno, context: "同卷移动（禁止覆盖）")
        }
        // No cross-volume copy/delete fallback.

    }

    /// 经系统废纸篓服务移入（由系统执行并记录「放回原处」）。返回实际落位路径。
    /// 测试注入 home 时退回手动移动到 <home>/.Trash，不触碰真实废纸篓。
    public func trashItem(atPath path: String) throws -> String {
        if let homeOverride {
            let destinationDir = homeOverride + "/.Trash"
            try createDirectory(atPath: destinationDir, intermediate: true)
            var destination = destinationDir + "/" + (path as NSString).lastPathComponent
            var bump = 1
            while fileExists(destination) {
                bump += 1
                destination = destinationDir + "/" + (path as NSString).lastPathComponent + "-\(bump)"
            }
            try moveItem(fromPath: path, toPath: destination)
            return destination
        }
        var destination: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
        return destination?.path ?? ""
    }

    public func createDirectory(atPath path: String, intermediate: Bool) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: intermediate)
    }

    public func truncateFile(atPath path: String) throws {
        if let attrs = attributesIfExist(atPath: path), attrs.isSymbolicLink {
            throw FileOpError.refuseSymlink(path)
        }
        let fd = open(path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw FileOpError.posix(path: path, errno: errno, context: "truncate")
        }
        defer { close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG, ftruncate(fd, 0) == 0 else {
            throw FileOpError.posix(path: path, errno: errno, context: "truncate")
        }
    }

    public func writeFile(_ data: Data, toPath path: String) throws {
        let parent = try SafeDirectory.parent(of: path)
        defer { close(parent.fd) }
        let temporary = ".dclean-write-" + UUID().uuidString
        let fd = openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOpError.posix(path: path, errno: errno, context: "写入临时清单") }
        defer { close(fd); unlinkat(parent.fd, temporary, 0) }
        try writeAll(data, descriptor: fd, path: path)
        guard fsync(fd) == 0, renameat(parent.fd, temporary, parent.fd, parent.name) == 0, fsync(parent.fd) == 0 else {
            throw FileOpError.posix(path: path, errno: errno, context: "持久化清单")
        }
    }

    public func readFile(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// 直接 lseek 到末尾读取，不把整个文件载入内存（审计日志每次追加都要看尾部）。
    public func tailBytes(atPath path: String, maxBytes: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size)
        let count = min(size, maxBytes)
        guard count > 0 else { return Data() }
        guard lseek(fd, off_t(size - count), SEEK_SET) >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: filled), count - filled) }
            if n > 0 { filled += n }
            else if n < 0 && errno == EINTR { continue }
            else { break }
        }
        return Data(buffer.prefix(filled))
    }

    private func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FileOpError.posix(path: path, errno: errno, context: "写入") }
                offset += count
            }
        }
    }

    public func appendFile(_ data: Data, toPath path: String) throws {
        let parent = try SafeDirectory.parent(of: path)
        defer { close(parent.fd) }
        let fd = openat(parent.fd, parent.name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOpError.posix(path: path, errno: errno, context: "打开审计日志") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { throw FileOpError.refuseSymlink(path) }
        try writeAll(data, descriptor: fd, path: path)
        guard fsync(fd) == 0 else { throw FileOpError.posix(path: path, errno: errno, context: "持久化审计日志") }
    }

    public func volumeSummary(atPath path: String) -> DiskSummary? {
        guard
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSummary(totalBytes: Int64(total), freeBytes: free)
    }
}

// MARK: - 内存实现（spec §10：单测用假文件树）

public final class InMemoryFileOperations: FileOperations {
    public struct Entry {
        public var isDirectory: Bool
        public var size: Int64
        public var modificationDate: Date
        public var symlinkTarget: String?
        public var content: Data?
    }

    private let home: String
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(home: String) {
        self.home = PathSafety.normalize(home, home: home)
        entries[self.home] = Entry(isDirectory: true, size: 0,
                                   modificationDate: Date(timeIntervalSince1970: 0),
                                   symlinkTarget: nil, content: nil)
    }

    public func homeDirectory() -> String { home }

    private func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // ---- 测试辅助：构造假文件树 ----

    @discardableResult
    public func makeDirectory(_ path: String) -> String {
        let p = PathSafety.normalize(path, home: home)
        var chain = p
        lock.lock(); defer { lock.unlock() }
        while chain != "/" && entries[chain] == nil {
            entries[chain] = Entry(isDirectory: true, size: 0,
                                   modificationDate: Date(timeIntervalSince1970: 0),
                                   symlinkTarget: nil, content: nil)
            chain = parent(of: chain)
        }
        return p
    }

    @discardableResult
    public func makeFile(_ path: String, size: Int64, modifiedAt: Date = Date(timeIntervalSince1970: 0),
                         content: Data? = nil) -> String {
        let p = PathSafety.normalize(path, home: home)
        _ = makeDirectory(parent(of: p))
        lock.lock(); defer { lock.unlock() }
        entries[p] = Entry(isDirectory: false, size: size, modificationDate: modifiedAt,
                           symlinkTarget: nil, content: content)
        return p
    }

    @discardableResult
    public func makeSymlink(at path: String, target: String) -> String {
        let p = PathSafety.normalize(path, home: home)
        _ = makeDirectory(parent(of: p))
        lock.lock(); defer { lock.unlock() }
        entries[p] = Entry(isDirectory: false, size: Int64(target.utf8.count),
                           modificationDate: Date(timeIntervalSince1970: 0),
                           symlinkTarget: target, content: nil)
        return p
    }

    public func allPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted()
    }

    public func entry(at path: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)]
    }

    // ---- FileOperations ----

    public func attributesIfExist(atPath path: String) -> FileAttributes? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[PathSafety.normalize(path, home: home)] else { return nil }
        return FileAttributes(isSymbolicLink: e.symlinkTarget != nil,
                              isDirectory: e.isDirectory && e.symlinkTarget == nil,
                              isRegularFile: !e.isDirectory && e.symlinkTarget == nil,
                              size: e.size,
                              modificationDate: e.modificationDate)
    }

    public func realPath(ofPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var current = PathSafety.normalize(path, home: home)
        var hops = 0
        while hops < 16 {
            guard let e = entries[current] else { return nil }
            guard let target = e.symlinkTarget else { return current }
            current = PathSafety.normalize(target, home: home)
            hops += 1
        }
        return nil
    }

    public func childrenOfDirectory(atPath path: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard let e = entries[p], e.isDirectory, e.symlinkTarget == nil else {
            throw FileOpError.notFound(p)
        }
        return entries.keys
            .filter { $0 != p && parent(of: $0) == p }
            .sorted()
    }

    public func fileExists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)] != nil
    }

    public func removeItem(atPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard entries[p] != nil else { throw FileOpError.notFound(p) }
        let prefix = p + "/"
        for key in entries.keys where key == p || key.hasPrefix(prefix) {
            entries.removeValue(forKey: key)
        }
    }

    public func moveItem(fromPath: String, toPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        let from = PathSafety.normalize(fromPath, home: home)
        let to = PathSafety.normalize(toPath, home: home)
        guard entries[from] != nil else { throw FileOpError.notFound(from) }
        guard entries[to] == nil else {
            throw FileOpError.posix(path: to, errno: Int32(EEXIST), context: "move 目标已存在")
        }
        let toParent = parent(of: to)
        if let pe = entries[toParent], !(pe.isDirectory && pe.symlinkTarget == nil) {
            throw FileOpError.posix(path: toParent, errno: Int32(ENOTDIR), context: "move 目标父级不是目录")
        }
        guard entries[toParent] != nil else { throw FileOpError.notFound(toParent) }
        let moved = entries.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
        for (key, value) in moved {
            entries.removeValue(forKey: key)
            entries[to + key.dropFirst(from.count)] = value
        }
    }

    public func createDirectory(atPath path: String, intermediate: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        if entries[p] != nil { return }
        let parentEntry = entries[parent(of: p)]
        if parentEntry == nil {
            guard intermediate || parent(of: p) == "/" else {
                throw FileOpError.posix(path: p, errno: Int32(ENOENT), context: "createDirectory")
            }
        }
        entries[p] = Entry(isDirectory: true, size: 0,
                           modificationDate: Date(timeIntervalSince1970: 0), symlinkTarget: nil)
    }

    public func truncateFile(atPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard var e = entries[p] else { throw FileOpError.notFound(p) }
        if e.symlinkTarget != nil { throw FileOpError.refuseSymlink(p) }
        e.size = 0
        e.content = Data() // 截断后仍是存在的 0 字节文件，readFile 应得到空 Data 而非 nil
        entries[p] = e
    }

    public func writeFile(_ data: Data, toPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard entries[p] != nil || entries[parent(of: p)] != nil else {
            throw FileOpError.posix(path: p, errno: Int32(ENOENT), context: "writeFile")
        }
        entries[p] = Entry(isDirectory: false, size: Int64(data.count),
                           modificationDate: Date(), symlinkTarget: nil, content: data)
    }

    public func readFile(atPath path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)]?.content
    }

    public func appendFile(_ data: Data, toPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        var existing = entries[p]?.content ?? Data()
        existing.append(data)
        entries[p] = Entry(isDirectory: false, size: Int64(existing.count),
                           modificationDate: Date(), symlinkTarget: nil, content: existing)
    }

    public func trashItem(atPath path: String) throws -> String {
        let destinationDir = home + "/.Trash"
        try createDirectory(atPath: destinationDir, intermediate: true)
        var destination = destinationDir + "/" + (path as NSString).lastPathComponent
        var bump = 1
        while entries[destination] != nil {
            bump += 1
            destination = destinationDir + "/" + (path as NSString).lastPathComponent + "-\(bump)"
        }
        try moveItem(fromPath: path, toPath: destination)
        return destination
    }

    public func volumeSummary(atPath path: String) -> DiskSummary? { nil }
}
