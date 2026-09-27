import Foundation

// MARK: - 守卫（spec §4）

public struct GuardSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case lockfile
        case process
    }

    public var type: Kind
    public var path: String?
    public var process: String?

    public init(type: Kind, path: String? = nil, process: String? = nil) {
        self.type = type
        self.path = path
        self.process = process
    }
}

// MARK: - 守卫评估结果

public struct Occupier: Codable, Equatable, Sendable {
    public var pid: Int32
    public var command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }

    public var description: String { "\(command)(\(pid))" }
}

public enum GuardStatus: Codable, Equatable, Sendable {
    case clear
    case blocked([Occupier])
    case unknown(String)
}

public struct DiskSummary: Codable, Equatable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

/// 并发收集结果的轻量锁包装（Swift 5 语言模式，不依赖平台 Mutex）。
final class MutexBox<T> {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    func withLock(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
