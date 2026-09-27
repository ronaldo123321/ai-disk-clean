import Foundation
import XCTest
@testable import CleanerCore

enum TestEnv {
    static func makeTempDir(_ label: String = "dclean") -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func write(_ content: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    /// 以 root 为根批量造文件；key 为相对路径。
    static func makeTree(root: String, files: [String: String]) throws {
        for (rel, content) in files {
            let p = root + "/" + rel
            try FileManager.default.createDirectory(
                atPath: (p as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try write(content, to: p)
        }
    }

    static func setMTime(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    static func daysAgo(_ n: Double, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-n * 86_400)
    }

    static func sleep(seconds: TimeInterval) throws {
        try Thread.sleep(forTimeInterval: seconds)
    }
}

/// guard 与 command 策略的单测注入点。
final class FakeProcessRunner: ProcessRunner {
    var handler: ((String, [String]) -> ProcessResult?)? {
        get { lock.lock(); defer { lock.unlock() }; return handlerStorage }
        set { lock.lock(); defer { lock.unlock() }; handlerStorage = newValue }
    }
    private var handlerStorage: ((String, [String]) -> ProcessResult?)?
    private let lock = NSLock()
    private(set) var calls: [(launchPath: String, arguments: [String])] = []

    func run(launchPath: String, arguments: [String]) -> ProcessResult? {
        lock.lock(); calls.append((launchPath, arguments)); lock.unlock()
        return handler?(launchPath, arguments)
    }
}
