import Foundation
import CryptoKit

public struct RecoveryEntry: Codable, Equatable, Sendable {
    /// cancelled：move 前崩溃，manifest 已记 pending 但原件从未离开原位（copy 不存在、原位置身份吻合）。
    /// 不算成功也不算失败，只是「这条记录已经处理完」，允许批次目录被回收。
    public enum State: String, Codable, Sendable { case pending, stored, restored, cancelled }

    public var originalPath: String
    public var storedPath: String
    public var bytes: Int64
    public var state: State
    public var identity: FileAttributes?
    /// 目录内容摘要：sha256(depth-first、按 childrenOfDirectory 既有顺序流式摘要的 "相对路径\0类型\0大小\0inode" 行)。
    /// 仅目录才有，普通文件恒为 nil。目录条目缺了它一律当作不可信——见 isTrustworthy 与 restore。
    public var contentDigest: String?
    /// 所属项的标识与标题，仅供界面展示与按项还原分组用，不参与任何可信性/安全校验。
    public var itemID: String?
    public var itemTitle: String?

    public init(originalPath: String, storedPath: String, bytes: Int64, state: State,
                identity: FileAttributes?, contentDigest: String? = nil,
                itemID: String? = nil, itemTitle: String? = nil) {
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.bytes = bytes
        self.state = state
        self.identity = identity
        self.contentDigest = contentDigest
        self.itemID = itemID
        self.itemTitle = itemTitle
    }
}

public struct RecoveryBatch: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var entries: [RecoveryEntry]

    public init(id: String, createdAt: Date, entries: [RecoveryEntry]) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
    }

    public var storedBytes: Int64 {
        entries.filter { $0.state == .stored }.reduce(0) { $0 + $1.bytes }
    }
}

public enum RecoveryError: Error, CustomStringConvertible, Equatable {
    case invalidBatchID(String)
    case batchExists(String)
    case missing(String)
    case symlink(String)
    case crossVolume(String)
    case protectedArea(String)
    case outsideHome(String)
    case moveVerificationFailed(String)
    case movedButUnrecorded(String)
    case contentUnverifiable(String)

    public var description: String {
        switch self {
        case .invalidBatchID(let id): return "恢复批次标识不合法：\(id)"
        case .batchExists(let id): return "恢复批次已存在：\(id)"
        case .missing(let path): return "目标不存在：\(path)"
        case .symlink(let path): return "拒绝移动符号链接：\(path)"
        case .crossVolume(let path): return "目标不在家目录所在磁盘上，首版不支持：\(path)"
        case .protectedArea(let path): return "拒绝移动恢复区或清理工具自己的数据目录：\(path)"
        case .outsideHome(let path): return "只能把家目录内的内容移入恢复区：\(path)"
        case .moveVerificationFailed(let path): return "移动后身份校验失败：\(path)"
        case .movedButUnrecorded(let path): return "已移入恢复区但记录未更新：\(path)"
        case .contentUnverifiable(let path): return "无法核对目录内容，未移入恢复区：\(path)"
        }
    }
}

/// 工具自管的恢复区：与被清理目录同卷，移入是一次 rename，不复制。
/// 每个批次一个目录：<directory>/<batchID>/manifest.json 与 items/<序号>/<原名>。
/// 移动前先把 pending 记录落盘，崩溃后仍能从清单定位。
public final class RecoveryStore {
    public static let retentionDays = 7

    public let directory: String
    let files: FileOperations
    /// 永久清空前后写审计；写不进去就不删。
    private let audit: AuditLog?

    public init(directory: String, files: FileOperations, audit: AuditLog? = nil) {
        self.directory = directory
        self.files = files
        self.audit = audit
    }

    /// 先写 purge.intent（失败则不删），删完写 purge.done。
    private func removeBatch(_ name: String, bytes: Int64) throws {
        try audit?.appendRequired(AuditEvent(op: "purge.intent", detail: name, bytes: bytes))
        try files.removeItem(atPath: directory + "/" + name)
        audit?.append(AuditEvent(op: "purge.done", detail: name, bytes: bytes, batchID: name))
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\0")
    }

    func manifestPath(_ id: String) -> String { directory + "/" + id + "/manifest.json" }

    /// 调用方负责持有 OperationLease（执行器在整个执行期间持有）。
    public func begin(batchID: String, now: Date) throws -> RecoveryBatchWriter {
        guard Self.isValidID(batchID) else { throw RecoveryError.invalidBatchID(batchID) }
        let batchDir = directory + "/" + batchID
        if files.fileExists(batchDir) { throw RecoveryError.batchExists(batchID) }
        for dir in [directory, batchDir, batchDir + "/items"] {
            try files.createDirectory(atPath: dir, intermediate: true)
        }
        let writer = RecoveryBatchWriter(store: self, batch: RecoveryBatch(id: batchID, createdAt: now, entries: []))
        try write(writer.batch)
        return writer
    }

    func write(_ batch: RecoveryBatch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.writeFile(try encoder.encode(batch), toPath: manifestPath(batch.id))
    }

    /// manifest 是否可信：批次目录名与清单内容必须严丝合缝，任何一处对不上都当作损坏处理（宁可拒绝也不冒险）。
    private func isTrustworthy(_ batch: RecoveryBatch, id: String) -> Bool {
        guard batch.id == id, Self.isValidID(batch.id) else { return false }
        let home = files.homeDirectory()
        var seenStoredPaths = Set<String>()
        for (index, entry) in batch.entries.enumerated() {
            guard seenStoredPaths.insert(entry.storedPath).inserted else { return false }
            let expectedStoredPath = directory + "/" + id + "/items/" + String(index) + "/"
                + (entry.originalPath as NSString).lastPathComponent
            guard entry.storedPath == expectedStoredPath else { return false }
            guard Self.originalPathProblem(entry.originalPath, home: home, recoveryDirectory: directory) == nil else { return false }
            guard entry.identity != nil else { return false }
            if entry.identity?.isDirectory == true {
                guard entry.contentDigest != nil else { return false }
            }
        }
        return true
    }

    /// 恢复条目原位置的统一判定：移入（admit）与读取清单（isTrustworthy）共用同一套规则，
    /// 绝不会出现「移得进去、却因清单校验不过而读不出来」的孤儿批次。
    /// 家目录按原样字符串比较（识别器产出的路径都由 home 拼出）；只在忽略大小写时才落在家目录内的路径一律拒绝。
    /// 工具自己的数据目录（恢复区、新旧数据目录）不区分大小写地拒绝：既不能在其内部，也不能包含它们。
    static func originalPathProblem(_ path: String, home: String, recoveryDirectory: String) -> RecoveryError? {
        guard path.hasPrefix("/"), path == PathSafety.normalize(path, home: home),
              PathSafety.isInside(path, root: home) else { return .outsideHome(path) }
        let lower = path.lowercased()
        for guarded in [recoveryDirectory, EnginePaths.dataDirectory(home: home), V2Paths.dataDirectory(home: home)] {
            let root = guarded.lowercased()
            if PathSafety.isInside(lower, root: root) || PathSafety.isInside(root, root: lower) {
                return .protectedArea(path)
            }
        }
        return nil
    }

    func read(_ id: String) -> RecoveryBatch? {
        guard Self.isValidID(id),
              files.attributesIfExist(atPath: manifestPath(id))?.isSymbolicLink == false,
              let data = files.readFile(atPath: manifestPath(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(RecoveryBatch.self, from: data), isTrustworthy(batch, id: id) else { return nil }
        return batch
    }

    public func list() -> [RecoveryBatch] {
        guard let children = try? files.childrenOfDirectory(atPath: directory) else { return [] }
        return children.compactMap { read(($0 as NSString).lastPathComponent) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 目录名有清单，但清单缺失或未通过 isTrustworthy 校验：既不出现在 list() 里，也绝不会被 purge 删除。
    /// 只看真正的子目录——恢复区里出现的散落文件不算孤儿批次。
    public func orphanBatches() -> [String] {
        guard let children = try? files.childrenOfDirectory(atPath: directory) else { return [] }
        return children
            .filter { files.attributesIfExist(atPath: $0)?.isDirectory == true }
            .map { ($0 as NSString).lastPathComponent }
            .filter { read($0) == nil }
    }

    /// 单个批次里「占地」的字节数：已入库，或崩溃窗口内已落地但清单还没来得及标记的 pending。
    public func occupiedBytes(of batch: RecoveryBatch) -> Int64 {
        batch.entries.reduce(0) { sum, entry in
            let counted = entry.state == .stored || (entry.state == .pending && files.fileExists(entry.storedPath))
            return sum + (counted ? entry.bytes : 0)
        }
    }

    public func occupiedBytes() -> Int64 {
        list().reduce(0) { $0 + occupiedBytes(of: $1) }
    }

    private struct DigestUnavailable: Error {}

    /// 目录内容摘要：depth-first 流式摘要 storedPath 下所有条目（lstat，不追踪符号链接），不构建全量清单。
    /// 普通文件（非目录）没有意义，返回 nil。任何一层列不出来或读不到属性都 fail closed（抛错，不吞掉）。
    static func contentDigest(storedPath: String, files: FileOperations) throws -> String? {
        guard let root = files.attributesIfExist(atPath: storedPath), root.isDirectory, !root.isSymbolicLink else { return nil }
        var hasher = SHA256()
        try hashEntries(root: storedPath, relative: "", files: files, hasher: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// childrenOfDirectory 按末段名排序，深度优先先访问自身再递归即得到确定顺序，不必再收集、排序、拼接一遍。
    private static func hashEntries(root: String, relative: String, files: FileOperations, hasher: inout SHA256) throws {
        let dirPath = relative.isEmpty ? root : root + "/" + relative
        let children = try files.childrenOfDirectory(atPath: dirPath)
        for child in children {
            let name = (child as NSString).lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            guard let attrs = files.attributesIfExist(atPath: child) else { throw DigestUnavailable() }
            let type = attrs.isSymbolicLink ? "l" : (attrs.isDirectory ? "d" : "f")
            let inode = attrs.inode ?? 0
            hasher.update(data: Data("\(rel)\u{0}\(type)\u{0}\(attrs.size)\u{0}\(inode)\n".utf8))
            if attrs.isDirectory && !attrs.isSymbolicLink {
                try hashEntries(root: root, relative: rel, files: files, hasher: &hasher)
            }
        }
    }

    /// 从 path 的父目录开始向上走到 home（或到根为止）：每个已存在的祖先都必须是真实目录、不能是符号链接。
    /// 尚不存在的祖先跳过（还原时会被逐级创建），但一旦发现某一层是符号链接就整体拒绝。
    private func ancestorsAreSafe(_ path: String, home: String) -> Bool {
        var current = path
        while true {
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return true }
            current = parent
            if let attrs = files.attributesIfExist(atPath: current) {
                guard attrs.isDirectory, !attrs.isSymbolicLink else { return false }
            }
            if current == home { return true }
        }
    }

    /// `itemIDs` 为 nil 是整批还原的唯一方式。非 nil 时只处理 `itemID` 落在集合内、且状态为
    /// `.stored`/`.pending` 的条目；一个都匹配不上（包括传入空集合）就直接返回错误，不动任何条目、不搬动任何文件。
    /// 没有记录 `itemID` 的条目（旧数据或未走按项路径写入）只能随整批还原，任何非 nil 的 `itemIDs` 都会跳过它们。
    public func restore(batchID: String, itemIDs: Set<String>? = nil, destinationDirectory: String? = nil) -> (restored: [String], errors: [String]) {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { return ([], [String(describing: error)]) }
        defer { withExtendedLifetime(lease) {} }
        guard var batch = read(batchID) else { return ([], ["恢复批次不存在或记录损坏：\(batchID)"]) }
        if let itemIDs {
            let hasMatch = batch.entries.contains {
                ($0.state == .stored || $0.state == .pending) && $0.itemID.map(itemIDs.contains) == true
            }
            guard hasMatch else { return ([], ["没有匹配的可还原项：\(batchID)"]) }
        }
        var restored: [String] = []
        var errors: [String] = []
        let safety = PathSafety(home: files.homeDirectory(), files: files)
        let home = files.homeDirectory()
        if let destinationDirectory {
            guard itemIDs?.count == 1,
                  Self.originalPathProblem(destinationDirectory, home: home, recoveryDirectory: directory) == nil,
                  ancestorsAreSafe(destinationDirectory + "/placeholder", home: home),
                  let attributes = files.attributesIfExist(atPath: destinationDirectory),
                  attributes.isDirectory, !attributes.isSymbolicLink,
                  attributes.device == files.attributesIfExist(atPath: home)?.device,
                  (try? safety.assertAllowed(destinationDirectory)) != nil,
                  (try? files.childrenOfDirectory(atPath: destinationDirectory).isEmpty) == true else {
                return ([], ["另存恢复需要家目录内同卷、安全且为空的目录；每次只能恢复一项。"])
            }
        }

        for index in batch.entries.indices {
            let entry = batch.entries[index]
            if entry.state == .restored || entry.state == .cancelled { continue }
            if let itemIDs, !(entry.itemID.map(itemIDs.contains) ?? false) { continue }
            let destination = destinationDirectory.map { $0 + "/" + (entry.originalPath as NSString).lastPathComponent } ?? entry.originalPath

            let copyExists = files.fileExists(entry.storedPath)
            if entry.state == .pending && !copyExists {
                // move 前崩溃：copy 从未落地。如果原件仍在原位且身份吻合，视为「未发生」，可以放行清理。
                if let identity = entry.identity,
                   let current = files.attributesIfExist(atPath: entry.originalPath),
                   identity.matches(current) {
                    batch.entries[index].state = .cancelled
                    _ = try? write(batch)
                } else {
                    errors.append("副本不存在：" + entry.originalPath)
                }
                continue
            }
            guard copyExists, let current = files.attributesIfExist(atPath: entry.storedPath) else {
                errors.append("副本不存在：" + entry.originalPath)
                continue
            }
            if let identity = entry.identity, !identity.matches(current) {
                errors.append("副本已变化，未还原：" + entry.originalPath)
                continue
            }
            if entry.identity?.isDirectory == true {
                // 目录条目没有摘要就一律拒绝：宁可拒绝也不冒险还原内容可能已被篡改的目录。
                guard let digest = entry.contentDigest else {
                    errors.append("无法核对副本内容，未还原：" + entry.originalPath)
                    continue
                }
                do {
                    guard try Self.contentDigest(storedPath: entry.storedPath, files: files) == digest else {
                        errors.append("副本内容已变化（可能被部分删除），未还原：" + entry.originalPath)
                        continue
                    }
                } catch {
                    errors.append("无法核对副本内容，未还原：" + entry.originalPath)
                    continue
                }
            }

            guard entry.identity != nil else {
                errors.append("目标身份信息缺失，拒绝还原：" + entry.originalPath)
                continue
            }
            do {
                _ = try safety.assertAllowed(destination)
            } catch {
                errors.append("还原目标不安全：\(entry.originalPath)（\(error)）")
                continue
            }
            guard ancestorsAreSafe(destination, home: home) else {
                errors.append("还原目标路径上存在符号链接：" + entry.originalPath)
                continue
            }
            guard !files.fileExists(destination) else {
                errors.append("原位置已有内容，不覆盖：" + entry.originalPath)
                continue
            }

            do {
                try audit?.appendRequired(AuditEvent(op: "restore.intent", detail: destination, batchID: batchID,
                                                     itemTitle: entry.itemTitle, paths: [entry.originalPath]))
                try files.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, intermediate: true)
                try files.moveItem(fromPath: entry.storedPath, toPath: destination)
                restored.append(destination)
                audit?.append(AuditEvent(op: "restore.done", detail: destination, bytes: entry.bytes, batchID: batchID,
                                        itemTitle: entry.itemTitle, paths: [entry.originalPath], action: destinationDirectory == nil ? "restored" : "alternate"))
                batch.entries[index].state = .restored
                do {
                    try write(batch)
                } catch {
                    errors.append("恢复记录更新失败：\(error)")
                }
            } catch {
                errors.append("还原失败：\(entry.originalPath)（\(error)）")
            }
        }

        if batch.entries.allSatisfy({ $0.state == .restored || $0.state == .cancelled }) {
            do { try files.removeItem(atPath: directory + "/" + batchID) } catch { errors.append("恢复记录清理失败：\(error)") }
        }
        return (restored, errors)
    }

    /// 永久删除超过保留期的批次。只能由用户显式触发（或用户开启的到期自动清空）。
    /// 按目录名删除，绝不依据清单里可能被篡改的 id；清单缺失或校验不过的目录一律跳过，见 orphanBatches()。
    public func purge(olderThanDays days: Int, now: Date) -> (purged: [String], errors: [String]) {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { return ([], [String(describing: error)]) }
        defer { withExtendedLifetime(lease) {} }
        guard let children = try? files.childrenOfDirectory(atPath: directory) else { return ([], []) }
        var purged: [String] = []
        var errors: [String] = []
        for child in children {
            let name = (child as NSString).lastPathComponent
            guard let batch = read(name) else { continue }
            guard now.timeIntervalSince(batch.createdAt) >= Double(days) * 86_400 else { continue }
            do {
                try removeBatch(name, bytes: batch.storedBytes)
                purged.append(name)
            } catch {
                errors.append("清空失败：\(name)（\(error)）")
            }
        }
        return (purged, errors)
    }

    /// 立即永久删除指定批次（用户在恢复区里点了「立即永久清空此批」并二次确认）。只处理记录可信的批次。
    /// 返回错误信息，空数组表示成功。
    public func purge(batchID: String) -> [String] {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { return [String(describing: error)] }
        defer { withExtendedLifetime(lease) {} }
        guard Self.isValidID(batchID), let batch = read(batchID) else { return ["恢复批次不存在或记录损坏：\(batchID)"] }
        do {
            try removeBatch(batchID, bytes: batch.storedBytes)
            return []
        } catch {
            return ["清空失败：\(batchID)（\(error)）"]
        }
    }
}

public final class RecoveryBatchWriter {
    public private(set) var batch: RecoveryBatch
    private let store: RecoveryStore

    init(store: RecoveryStore, batch: RecoveryBatch) {
        self.store = store
        self.batch = batch
    }

    public func admit(path: String, bytes: Int64, itemID: String? = nil, itemTitle: String? = nil,
                      expectedIdentity: FileAttributes? = nil) throws {
        let files = store.files
        // 与读取清单时的校验同一套规则，且在落盘 pending 记录与 move 之前：通不过就什么都不做。
        if let problem = RecoveryStore.originalPathProblem(path, home: files.homeDirectory(), recoveryDirectory: store.directory) {
            throw problem
        }
        guard let identity = files.attributesIfExist(atPath: path) else { throw RecoveryError.missing(path) }
        if let expectedIdentity, !expectedIdentity.matches(identity) { throw RecoveryError.moveVerificationFailed(path) }
        guard !identity.isSymbolicLink else { throw RecoveryError.symlink(path) }
        guard EnginePathChecks.isCanonical(path, files: files) else { throw RecoveryError.symlink(path) }
        if let recovery = files.attributesIfExist(atPath: store.directory), recovery.device != identity.device {
            throw RecoveryError.crossVolume(path)
        }

        // 工具绝不能收下一个日后还不回去的目录：摘要在 move 之前先算好（此时路径还是原件），
        // 算不出来就直接拒绝整次 admit——原件分毫不动，什么记录都不落盘、什么 move 都不做。
        var preDigest: String?
        if identity.isDirectory {
            do {
                preDigest = try RecoveryStore.contentDigest(storedPath: path, files: files)
            } catch {
                throw RecoveryError.contentUnverifiable(path)
            }
        }

        let index = batch.entries.count
        let slot = store.directory + "/" + batch.id + "/items/" + String(index)
        let storedPath = slot + "/" + (path as NSString).lastPathComponent
        batch.entries.append(RecoveryEntry(originalPath: path, storedPath: storedPath, bytes: bytes, state: .pending,
                                            identity: identity, contentDigest: preDigest,
                                            itemID: itemID, itemTitle: itemTitle))
        try store.write(batch)

        try files.createDirectory(atPath: slot, intermediate: true)
        if let expectedIdentity {
            guard let current = files.attributesIfExist(atPath: path), expectedIdentity.matches(current) else {
                batch.entries.removeLast()
                try store.write(batch)
                throw RecoveryError.moveVerificationFailed(path)
            }
        }
        try files.moveItem(fromPath: path, toPath: storedPath)

        guard let movedIdentity = files.attributesIfExist(atPath: storedPath), identity.matches(movedIdentity) else {
            // 身份对不上：立刻尝试把东西挪回去。挪回成功就撤销这条 pending 记录；挪不回去就保持 pending
            // （copy 仍在 storedPath，还原路径能兜底），两种情况都把这次 admit 报告为失败。
            if (try? files.moveItem(fromPath: storedPath, toPath: path)) != nil {
                batch.entries.removeLast()
                _ = try? store.write(batch)
            }
            throw RecoveryError.moveVerificationFailed(path)
        }

        // move 之后按同样的方式重算一次：算不出来，或者跟 move 前的摘要对不上，都说明这段窗口期
        // 内容不可信——按身份校验失败同样处理（挪回去，挪不回去就保持 pending）。
        if identity.isDirectory {
            var postDigest: String?
            var postDigestFailed = false
            do {
                postDigest = try RecoveryStore.contentDigest(storedPath: storedPath, files: files)
            } catch {
                postDigestFailed = true
            }
            if postDigestFailed || postDigest != preDigest {
                if (try? files.moveItem(fromPath: storedPath, toPath: path)) != nil {
                    batch.entries.removeLast()
                    _ = try? store.write(batch)
                }
                throw RecoveryError.moveVerificationFailed(path)
            }
            batch.entries[index].contentDigest = postDigest
        }
        batch.entries[index].state = .stored

        do {
            try store.write(batch)
        } catch let writeError {
            if (try? files.moveItem(fromPath: storedPath, toPath: path)) != nil {
                batch.entries.removeLast()
                _ = try? store.write(batch)
                throw writeError
            }
            throw RecoveryError.movedButUnrecorded(path)
        }
    }
}
