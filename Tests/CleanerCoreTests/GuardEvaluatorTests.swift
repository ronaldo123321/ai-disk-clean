import XCTest
@testable import CleanerCore

/// spec §10：guard 用例（层 6）
final class GuardEvaluatorTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var runner: FakeProcessRunner!
    private var evaluator: GuardEvaluator!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-guards")
        files = RealFileOperations()
        runner = FakeProcessRunner()
        evaluator = GuardEvaluator(files: files, runner: runner)
    }

    override func tearDown() {
        TestEnv.remove(root!)
    }

    func testLockfileMissingMeansClear() {
        let guardSpec = GuardSpec(type: .lockfile, path: root + "/.lock")
        let status = evaluator.evaluate(guardSpec, home: root)
        XCTAssertEqual(status, .clear)
        XCTAssertEqual(runner.calls.count, 0) // 锁不存在，不启动 lsof
    }

    func testLockfileHeldByProcessIsBlocked() throws {
        let lock = root + "/.cache/uv/.lock"
        try TestEnv.makeTree(root: root, files: { () -> [String: String] in
            var f = [String: String]()
            f[".cache/uv/.lock"] = ""
            return f
        }())
        runner.handler = { launchPath, args in
            XCTAssertEqual(launchPath, GuardEvaluator.lsofPath)
            XCTAssertTrue(args.contains("--"))
            return ProcessResult(exitStatus: 0,
                                 stdout: "p123\0cchroma-mcp\0n\(lock)\0p123\0cchroma-mcp\0n\(lock)\0",
                                 stderr: "")
        }
        let status = evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 123, command: "chroma-mcp")])) // 同进程去重
    }

    func testLockfileWithNoHolderIsClear() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { _, _ in ProcessResult(exitStatus: 1, stdout: "", stderr: "") } // lsof 无持有者
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root), .clear)
    }

    func testLsofFieldParsing() {
        let output = "p10\0ccodex\0n/a\0p20\0cChrome Helper\0n/b\0junk\0"
        let occupiers = evaluator.parseLsofFields(output)
        XCTAssertEqual(occupiers, [Occupier(pid: 10, command: "codex"),
                                   Occupier(pid: 20, command: "Chrome Helper")])
        XCTAssertTrue(evaluator.parseLsofFields("").isEmpty)
    }

    func testProcessGuardBlockedWhenRunning() {
        runner.handler = { launchPath, args in
            XCTAssertEqual(launchPath, GuardEvaluator.pgrepPath)
            XCTAssertEqual(args, ["-x", "docker-daemon"])
            return ProcessResult(exitStatus: 0, stdout: "99\n100\n", stderr: "")
        }
        let status = evaluator.evaluate(GuardSpec(type: .process, process: "docker-daemon"), home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 99, command: "docker-daemon"),
                                         Occupier(pid: 100, command: "docker-daemon")]))
    }

    func testProcessGuardClearWhenNotRunning() {
        runner.handler = { _, _ in ProcessResult(exitStatus: 1, stdout: "", stderr: "") }
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .process, process: "docker-daemon"), home: root), .clear)
    }

    func testCombinedGuardsAnyBlockBlocksAll() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { launchPath, _ in
            launchPath == GuardEvaluator.pgrepPath
                ? ProcessResult(exitStatus: 1, stdout: "", stderr: "")
                : ProcessResult(exitStatus: 0, stdout: "p7\0cholder\0n\(lock)\0", stderr: "")
        }
        let status = evaluator.status(of: [GuardSpec(type: .process, process: "something"),
                                           GuardSpec(type: .lockfile, path: lock)],
                                      home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 7, command: "holder")]))
    }

    func testLsofUnavailableIsUnknown() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { _, _ in nil }
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root), .unknown("lsof 无法启动"))
    }
}
