import Foundation

public struct SizeMeasurement: Equatable, Sendable {
    public var apparent: Int64
    public var reclaimable: Int64
    /// 每个起始路径的表观大小（空间分布扣除已列出项时用）
    public var perPath: [String: Int64]
    /// 无法列出内容的目录（通常是缺少完全磁盘访问权限）；其大小未计入，不猜测
    public var unreadable: [String]
}

/// 表观大小：同一 inode 只计一次（与 `apparentSize` 一致的口径：只加子项的磁盘占用，
/// 目录自身的块不计入）。
/// 可释放量：硬链接文件只有在它的全部链接都位于本次范围内时才计入——
/// 否则删掉这一处，数据仍被范围外的链接占着（uv 缓存与虚拟环境就是这种情况）。
/// 符号链接只计自身，不跟随。
public struct Sizer {
    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    public let files: FileOperations
    public let cancellation: OperationCancellation?

    public init(files: FileOperations, cancellation: OperationCancellation? = nil) {
        self.files = files
        self.cancellation = cancellation
    }

    public func measure(_ paths: [String]) -> SizeMeasurement {
        var result = SizeMeasurement(apparent: 0, reclaimable: 0, perPath: [:], unreadable: [])
        var links: [InodeKey: (seen: UInt32, total: UInt32, bytes: Int64)] = [:]
        for root in normalizedRoots(paths) {
            var rootBytes: Int64 = 0
            var stack = [root]
            while let path = stack.popLast() {
                if cancellation?.isCancelled == true { break }
                guard let attributes = files.attributesIfExist(atPath: path) else {
                    result.unreadable.append(path)
                    continue
                }
                if attributes.isDirectory && !attributes.isSymbolicLink {
                    do {
                        stack.append(contentsOf: try files.childrenOfDirectory(atPath: path))
                    } catch {
                        if !Sizer.isVanished(error) {
                            result.unreadable.append(path)
                        }
                    }
                    continue
                }
                if attributes.isRegularFile, let total = attributes.linkCount, total > 1,
                   let device = attributes.device, let inode = attributes.inode {
                    let key = InodeKey(device: device, inode: inode)
                    if var entry = links[key] {
                        entry.seen += 1
                        links[key] = entry
                        continue
                    }
                    links[key] = (1, total, attributes.allocatedSize)
                    rootBytes += attributes.allocatedSize
                } else {
                    rootBytes += attributes.allocatedSize
                    result.reclaimable += attributes.allocatedSize
                }
            }
            result.perPath[root] = rootBytes
            result.apparent += rootBytes
        }
        for entry in links.values where entry.seen >= entry.total {
            result.reclaimable += entry.bytes
        }
        return result
    }

    /// 归一化、去重，并丢弃被其他起始路径包含的路径（嵌套或完全重复的 root 只算一次）。
    private func normalizedRoots(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        let home = files.homeDirectory()
        for path in paths {
            let normalized = PathSafety.normalize(path, home: home)
            if seen.insert(normalized).inserted {
                unique.append(normalized)
            }
        }
        // 祖先路径的字符串长度必然短于其后代，按长度升序排列后祖先必先入选。
        let sorted = unique.sorted { $0.count < $1.count }
        var kept: [String] = []
        for candidate in sorted where !kept.contains(where: { PathSafety.isInside(candidate, root: $0) }) {
            kept.append(candidate)
        }
        return kept
    }

    /// 列目录失败若只是「目录已经不在了 / 不再是目录」，视为扫描期间的正常波动，不上报为不可读。
    static func isVanished(_ error: Error) -> Bool {
        if case FileOpError.notFound = error { return true }
        if let cocoa = error as? CocoaError,
           cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
            return true
        }
        let nsError = error as NSError
        if isPosixVanished(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, isPosixVanished(underlying) {
            return true
        }
        return false
    }

    private static func isPosixVanished(_ error: NSError) -> Bool {
        guard error.domain == NSPOSIXErrorDomain else { return false }
        return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
    }
}
