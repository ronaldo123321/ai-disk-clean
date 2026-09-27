import XCTest
@testable import CleanerCore

final class EnginePreconditionTests: XCTestCase {
    let home = EngineFixture.home

    func item(quit: [QuitApp] = [], locks: [String] = []) -> CleanItem {
        CleanItem(id: "i", app: "a", category: .dev, tier: .safe, title: "t", paths: [], action: .recover,
                  preconditions: RulePreconditions(quitApps: quit, lockfiles: locks),
                  copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    }

    func testRunningAppBlocks() {
        let files = InMemoryFileOperations(home: home)
        let apps = FakeAppControl()
        apps.running = ["com.google.Chrome"]
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        XCTAssertEqual(checker.blockers(for: item(quit: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")])),
                       [.appRunning(name: "Chrome", bundleID: "com.google.Chrome")])
        XCTAssertEqual(checker.blockers(for: item(quit: [QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")])), [])
    }

    func testHeldLockfileBlocksWithOccupier() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        let runner = FakeProcessRunner()
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p34045\0cuv\0n/x\0", stderr: "") : nil
        }
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: runner), home: home)
        XCTAssertEqual(checker.blockers(for: item(locks: ["~/.cache/uv/.lock"])), [.occupied("uv(34045)")])
    }

    func testMissingLockfileIsClear() {
        let files = InMemoryFileOperations(home: home)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        XCTAssertEqual(checker.blockers(for: item(locks: ["~/.cache/uv/.lock"])), [])
    }

    func testLsofFailureIsUnavailableNotClear() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        let runner = FakeProcessRunner()
        runner.handler = { _, _ in nil }
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: runner), home: home)
        XCTAssertEqual(checker.blockers(for: item(locks: ["~/.cache/uv/.lock"])),
                       [.unavailable("无法确认是否被占用：lsof 无法启动")])
    }

    func testRunningAppAndHeldLockBothBlockAppFirst() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        let runner = FakeProcessRunner()
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p34045\0cuv\0n/x\0", stderr: "") : nil
        }
        let apps = FakeAppControl()
        apps.running = ["com.google.Chrome"]
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: runner), home: home)
        XCTAssertEqual(checker.blockers(for: item(quit: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")],
                                                   locks: ["~/.cache/uv/.lock"])),
                       [.appRunning(name: "Chrome", bundleID: "com.google.Chrome"), .occupied("uv(34045)")])
    }
}
