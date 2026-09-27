import Foundation

// MARK: - 审计日志（spec §7：所有操作追加写入 ~/.dclean-v3/audit.log，每次操作一行 JSON）

public struct AuditEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var op: String
    public var detail: String
    public var bytes: Int64?

    public init(ts: Date = Date(), op: String, detail: String, bytes: Int64? = nil) {
        self.ts = ts
        self.op = op
        self.detail = detail
        self.bytes = bytes
    }
}

public final class AuditLog {
    /// 超过此大小则轮转为 <path>.1（只保留一代）。执行期每项至少两条记录，无上限会无限增长。
    public static let rotateThreshold = 5 << 20

    public let path: String
    private let files: FileOperations
    private let lock = NSLock()
    /// 本实例是否已做过全量完整性校验。校验是 O(文件大小)，而 Executor 每个条目要追加 2 条以上，
    /// 每次都重读重解整个日志就是 O(n²)。操作期间有 OperationLease 独占，本实例之后写入的每一行
    /// 都是自己 fsync 完成的完整行，因此只需首次校验一次。
    private var validated = false

    public init(files: FileOperations, path: String) {
        self.files = files
        self.path = path
    }

    public func append(_ event: AuditEvent) {
        try? appendRequired(event)
    }

    public func appendRequired(_ event: AuditEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if files.fileExists(path) {
            guard files.attributesIfExist(atPath: path)?.isSymbolicLink == false else { throw FileOpError.refuseSymlink(path) }
            if validated {
                // 快路径：只核对尾部是否为完整行。截断写入与外部覆写都会在这里暴露。
                guard let tail = files.tailBytes(atPath: path, maxBytes: 1) else { throw FileOpError.refuseSymlink(path) }
                guard tail.isEmpty || tail.last == 0x0A else { throw AuditLogError.corrupt }
            } else {
                guard let existing = files.readFile(atPath: path) else { throw FileOpError.refuseSymlink(path) }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard existing.isEmpty || existing.last == 0x0A else { throw AuditLogError.corrupt }
                for line in existing.split(separator: 0x0A) { guard (try? decoder.decode(AuditEvent.self, from: Data(line))) != nil else { throw AuditLogError.corrupt } }
            }
        }
        validated = true
        try rotateIfOversized()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(event)
        line.append(0x0A)
        let dir = (path as NSString).deletingLastPathComponent
        try files.createDirectory(atPath: dir, intermediate: true)
        try files.appendFile(line, toPath: path)
    }

    /// 日志超限时整体轮转为 <path>.1，只保留一代；轮转后当前日志为空，无需再次全量校验。
    private func rotateIfOversized() throws {
        guard let size = files.attributesIfExist(atPath: path)?.size,
              size >= Int64(Self.rotateThreshold) else { return }
        let rotated = path + ".1"
        if files.fileExists(rotated) { try files.removeItem(atPath: rotated) }
        try files.moveItem(fromPath: path, toPath: rotated)
    }

    /// 轮转出去的一代在前、当前日志在后，保持时间升序。
    public func readAll() -> [AuditEvent] {
        decodeEvents(atPath: path + ".1") + decodeEvents(atPath: path)
    }

    private func decodeEvents(atPath path: String) -> [AuditEvent] {
        guard let data = files.readFile(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(AuditEvent.self, from: Data(line))
        }
    }
}

public enum AuditLogError: Error, LocalizedError {
    case corrupt
    public var errorDescription: String? { "审计日志含损坏或未完成记录，已停止操作。请保留原日志供检查。" }
}
