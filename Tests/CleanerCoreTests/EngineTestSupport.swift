import Foundation
@testable import CleanerCore

enum EngineFixture {
    static let home = "/Users/tester"

    static func context(_ files: InMemoryFileOperations, runner: FakeProcessRunner = FakeProcessRunner(),
                        now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> DetectContext {
        DetectContext(files: files, safety: PathSafety(home: files.homeDirectory(), files: files), runner: runner, now: now)
    }

    static func daysBefore(_ days: Double, _ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }
}

final class FakeAppControl: AppControl {
    var running: Set<String> = []
    var quitSucceeds = true
    private(set) var quitRequests: [String] = []
    private(set) var forceQuits: [String] = []
    /// 在 requestQuit 内部调用，用来模拟等待应用退出期间用户的操作
    var onRequestQuit: ((String) -> Void)?

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }

    func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool {
        quitRequests.append(bundleID)
        onRequestQuit?(bundleID)
        if quitSucceeds { running.remove(bundleID) }
        return quitSucceeds
    }

    func forceQuit(bundleID: String) -> Bool {
        forceQuits.append(bundleID)
        running.remove(bundleID)
        return true
    }
}
