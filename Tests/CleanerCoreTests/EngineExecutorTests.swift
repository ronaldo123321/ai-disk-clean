import XCTest
@testable import CleanerCore

final class EngineExecutorTests: XCTestCase {
    let home = EngineFixture.home
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var apps: FakeAppControl!
    var recovery: RecoveryStore!
    /// 注入的时钟：sleep 推进它，等待超时才会结束。
    var clock = EngineFixture.daysBefore(0)

    override func setUp() {
        files = InMemoryFileOperations(home: home)
        files.makeDirectory(EnginePaths.recoveryDirectory(home: home))
        runner = FakeProcessRunner()
        clock = EngineFixture.daysBefore(0)
        apps = FakeAppControl()
        recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
    }

    func executor() -> PlanExecutor {
        PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner, commandRunner: runner,
                     apps: apps, recovery: recovery, audit: AuditLog(files: files, path: EnginePaths.auditLog(home: home)),
                     now: { self.clock }, sleep: { self.clock += $0 })
    }

    func item(_ id: String, tier: CleanTier = .safe, paths: [String], action: RuleAction = .recover,
              preconditions: RulePreconditions = .empty, regrows: String? = nil) -> CleanItem {
        var i = CleanItem(id: id, app: id, category: .dev, tier: tier, title: id, paths: paths, action: action,
                          preconditions: preconditions, copy: RuleCopy(what: "w", impact: "i", regrows: regrows))
        i.reclaimableBytes = 10
        return i
    }

    /// 阻塞检查在路径复核之后：第二项若仍用同一路径会在应用检查前先因目标已不存在得到 .gone，
    /// 所以第二项换用另一个存在的目录，保持断言 .appRunning（参见任务说明）。
    func testResultsCarryStructuredReasons() throws {
        files.makeFile(home + "/Library/Caches/A/x", size: 1)
        files.makeFile(home + "/Library/Caches/B/x", size: 1)
        files.makeFile(home + "/Documents/x/a", size: 1)
        apps.running = ["com.google.Chrome"]
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let report = try executor().run([
            item("done", paths: [home + "/Library/Caches/A"]),
            item("app", tier: .suggested, paths: [home + "/Library/Caches/B"], preconditions: RulePreconditions(quitApps: [chrome])),
            item("gone", paths: [home + "/Library/Caches/Gone"]),
            item("protected", paths: [home + "/Documents/x"]),
        ])
        XCTAssertEqual(report.results.map(\.reason), [nil, .appRunning, .gone, .protected])
    }

    func testPublicInitializersExist() {
        let result = ItemRunResult(itemID: "a", title: "A", outcome: .done, estimatedBytes: 1, recoveredBytes: 0, reason: nil)
        let report = RunReport(batchID: "b", startedAt: Date(), finishedAt: Date(), freeBefore: nil, freeAfter: nil,
                               results: [result], serviceIssues: [], regrowNotes: [])
        XCTAssertEqual(report.results.first?.reason, nil)
        XCTAssertEqual(OutcomeReason.appRunning.title, "应用仍在运行")
    }

    func testRecoverMovesIntoRecoveryStore() throws {
        files.makeFile(home + "/.gradle/caches/a", size: 70)
        let report = try executor().run([item("gradle", paths: [home + "/.gradle/caches"], regrows: "会长回来")])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertFalse(files.fileExists(home + "/.gradle/caches"))
        XCTAssertEqual(report.recoveryBytes, 70)
        XCTAssertEqual(recovery.occupiedBytes(), 70)
        XCTAssertEqual(report.regrowNotes, ["gradle：会长回来"])
        XCTAssertNil(report.measuredFreedBytes)
    }

    func testNestedPathsInOneItemMoveOuterOnceAndReportDone() throws {
        files.makeFile(home + "/.gradle/caches/b/x", size: 30)
        files.makeFile(home + "/.gradle/caches/y", size: 40)
        let report = try executor().run([item("gradle", paths: [home + "/.gradle/caches/b", home + "/.gradle/caches"])])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertFalse(files.fileExists(home + "/.gradle/caches"))
        XCTAssertEqual(recovery.list().first?.entries.map(\.originalPath), [home + "/.gradle/caches"])
        XCTAssertEqual(report.recoveryBytes, 70)
    }

    func testCommandRunsResolvedExecutableWithFixedPATH() throws {
        files.makeFile("/opt/homebrew/bin/npm", size: 1)
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        let report = try executor().run([item("npm", paths: [], action: .command(["npm", "cache", "clean", "--force"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(runner.calls.last?.launchPath, "/usr/bin/env")
        XCTAssertEqual(runner.calls.last?.arguments,
                       ["PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin/npm", "cache", "clean", "--force"])
    }

    func testCommandItemResultAuditHasNoByteCount() throws {
        files.makeFile("/opt/homebrew/bin/npm", size: 1)
        files.makeFile(home + "/Library/Caches/A/x", size: 7)
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        _ = try executor().run([item("npm", paths: [], action: .command(["npm", "cache", "clean", "--force"])),
                                item("a", paths: [home + "/Library/Caches/A"])])
        let results = AuditLog(files: files, path: EnginePaths.auditLog(home: home)).readAll().filter { $0.op == "run.item.result" }
        // 命令项释放了多少执行器不知道，记 nil 而不是 0
        XCTAssertEqual(results.map(\.bytes), [nil, 7])
    }

    func testFailedCommandIsReportedAndNeverFallsBackToDeletion() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(home + "/.cache/uv/a", size: 5)
        runner.handler = { _, _ in ProcessResult(exitStatus: 2, stdout: "", stderr: "warn\nerror: locked\n") }
        let report = try executor().run([item("uv", paths: [home + "/.cache/uv"], action: .command(["uv", "cache", "prune"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.failed("命令失败（退出码 2）：error: locked")])
        XCTAssertEqual(report.results.map(\.reason), [.commandFailed])
        XCTAssertTrue(files.fileExists(home + "/.cache/uv/a"))
    }

    func testForbiddenPathAtExecutionSkipsWholeItem() throws {
        files.makeFile(home + "/Library/Caches/ok/a", size: 1)
        files.makeFile(home + "/Documents/work/a", size: 1)
        let report = try executor().run([item("mixed", paths: [home + "/Library/Caches/ok", home + "/Documents/work"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/ok/a"))
        XCTAssertTrue(files.fileExists(home + "/Documents/work/a"))
    }

    func testSymlinkPathSkipsWholeItem() throws {
        files.makeSymlink(at: home + "/Library/Caches/link", target: home + "/Library/Caches/real")
        files.makeFile(home + "/Library/Caches/real/a", size: 1)
        let report = try executor().run([item("link", paths: [home + "/Library/Caches/link"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/link"))
    }

    func testSymlinkedAncestorAtExecutionSkipsItem() throws {
        let tmp = TestEnv.makeTempDir("exec")
        defer { TestEnv.remove(tmp) }
        try TestEnv.write("x", to: tmp + "/Library/Caches/Real/CacheStorage/f")
        try FileManager.default.createSymbolicLink(atPath: tmp + "/Library/Caches/App",
                                                   withDestinationPath: tmp + "/Library/Caches/Real")
        let real = RealFileOperations(home: tmp)
        let exec = PlanExecutor(files: real, safety: PathSafety(home: tmp, files: real), runner: runner, commandRunner: runner,
                                apps: apps, recovery: RecoveryStore(directory: EnginePaths.recoveryDirectory(home: tmp), files: real),
                                audit: AuditLog(files: real, path: EnginePaths.auditLog(home: tmp)), sleep: { _ in })
        let report = try exec.run([item("app", paths: [tmp + "/Library/Caches/App/CacheStorage"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/Real/CacheStorage/f"))
    }

    func testAlreadyGoneItemIsSkipped() throws {
        let report = try executor().run([item("gone", paths: [home + "/Library/Caches/gone"])])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("目标已不存在或已被修改")])
    }

    func testDisplayOnlyIsNeverExecuted() throws {
        files.makeFile(home + "/.codex/sessions/a", size: 1)
        let report = try executor().run([item("codex", tier: .displayOnly, paths: [home + "/.codex/sessions"], action: .noAction)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("只展示项不可执行")])
        XCTAssertTrue(files.fileExists(home + "/.codex/sessions/a"))
    }

    func testRecoverOlderThanRechecksAge() throws {
        let dir = home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/now-fresh.ips", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        let action = RuleAction(type: .recoverOlderThan, olderThanDays: 30)
        let report = try executor().run([item("diag", paths: [dir + "/now-fresh.ips"], action: action)])
        guard case .skipped = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(files.fileExists(dir + "/now-fresh.ips"))
    }

    func testRecoverOlderThanWithoutDaysIsSkipped() throws {
        let path = home + "/Library/Logs/DiagnosticReports/old.ips"
        files.makeFile(path, size: 1, modifiedAt: EngineFixture.daysBefore(365))
        let report = try executor().run([item("diag", paths: [path], action: RuleAction(type: .recoverOlderThan))])
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(files.fileExists(path))
    }

    func testAuditStartFailureThrowsBeforeAnyChange() throws {
        files.makeDirectory(EnginePaths.auditLog(home: home))
        files.makeFile(home + "/.gradle/caches/a", size: 70)
        files.makeFile("/opt/homebrew/bin/npm", size: 1)
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        XCTAssertThrowsError(try executor().run([item("npm", paths: [], action: .command(["npm", "cache", "clean"])),
                                                 item("gradle", paths: [home + "/.gradle/caches"])])) { error in
            guard case ExecutorRunError.auditUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(files.fileExists(home + "/.gradle/caches/a"))
    }

    func testItemIntentAuditFailureStopsRemainingItems() throws {
        files.makeFile("/opt/homebrew/bin/npm", size: 1)
        files.makeFile(home + "/.gradle/caches/a", size: 70)
        let log = EnginePaths.auditLog(home: home)
        runner.handler = { [files] _, _ in
            try? files!.removeItem(atPath: log)
            files!.makeDirectory(log)
            return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
        }
        let report = try executor().run([item("npm", paths: [], action: .command(["npm", "cache", "clean"])),
                                         item("gradle", paths: [home + "/.gradle/caches"]),
                                         item("npm2", paths: [], action: .command(["npm", "cache", "verify"]))])
        XCTAssertEqual(report.results[0].outcome, .done)
        XCTAssertNil(report.results[0].reason)
        for result in report.results.dropFirst() {
            guard case .failed(let why) = result.outcome, why.hasPrefix("审计日志无法写入，已停止：") else {
                return XCTFail("\(result.outcome)")
            }
            XCTAssertEqual(result.reason, .auditFailed)
        }
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(files.fileExists(home + "/.gradle/caches/a"))
    }

    func testRecoverOlderThanMovesOldFileAndDropsFreshSibling() throws {
        let dir = home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/old.ips", size: 4, modifiedAt: EngineFixture.daysBefore(60))
        files.makeFile(dir + "/fresh.ips", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        let action = RuleAction(type: .recoverOlderThan, olderThanDays: 30)
        let report = try executor().run([item("diag", paths: [dir + "/old.ips", dir + "/fresh.ips"], action: action)])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertFalse(files.fileExists(dir + "/old.ips"))
        XCTAssertTrue(files.fileExists(dir + "/fresh.ips"))
        XCTAssertEqual(report.recoveryBytes, 4)
    }

    func testRunningAppBlocksItem() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = ["com.google.Chrome"]
        let pre = RulePreconditions(quitApps: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")])
        let report = try executor().run([item("chrome", paths: [home + "/Library/Caches/Chrome"], preconditions: pre)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/Chrome/a"))
    }

    func testOccupiedLockfileBlocksItem() throws {
        files.makeFile(home + "/.cache/uv/a", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p34045\0cuv\0n/x\0", stderr: "") : nil
        }
        let pre = RulePreconditions(lockfiles: ["~/.cache/uv/.lock"])
        let report = try executor().run([item("uv", paths: [home + "/.cache/uv"], preconditions: pre)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：uv(34045)")])
        XCTAssertEqual(report.results.map(\.reason), [.occupied])
        XCTAssertTrue(files.fileExists(home + "/.cache/uv/a"))
    }

    func testUnknownLockStatusBlocksItem() throws {
        files.makeFile(home + "/.cache/uv/a", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { _, _ in nil }
        let pre = RulePreconditions(lockfiles: ["~/.cache/uv/.lock"])
        let report = try executor().run([item("uv", paths: [home + "/.cache/uv"], preconditions: pre)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("无法确认是否被占用：lsof 无法启动")])
        XCTAssertEqual(report.results.map(\.reason), [.unavailable])
        XCTAssertTrue(files.fileExists(home + "/.cache/uv/a"))
    }

    /// admit 拒收的情形：目录内有无法列出的子目录，内容摘要算不出来（contentUnverifiable），原件不动。
    func testPartialAdmitFailureReportsCounts() throws {
        let tmp = TestEnv.makeTempDir("exec")
        let locked = tmp + "/Library/Caches/Bad/locked"
        defer { chmod(locked, 0o755); TestEnv.remove(tmp) }
        try TestEnv.write("x", to: tmp + "/Library/Caches/Ok/f")
        try TestEnv.write("y", to: locked + "/f")
        XCTAssertEqual(chmod(locked, 0), 0)
        let real = RealFileOperations(home: tmp)
        let exec = PlanExecutor(files: real, safety: PathSafety(home: tmp, files: real), runner: runner, commandRunner: runner,
                                apps: apps, recovery: RecoveryStore(directory: EnginePaths.recoveryDirectory(home: tmp), files: real),
                                audit: AuditLog(files: real, path: EnginePaths.auditLog(home: tmp)), sleep: { _ in })
        let report = try exec.run([item("mixed", paths: [tmp + "/Library/Caches/Ok", tmp + "/Library/Caches/Bad"])])
        guard case .failed(let why) = report.results[0].outcome,
              why.hasPrefix("1 个已移入恢复区，1 个失败：") else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(report.results[0].reason, .recoveryFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/Ok"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/Bad/locked"))
        XCTAssertGreaterThan(report.recoveryBytes, 0)
    }

    func testToolDataDirectoryIsSkipped() throws {
        let lock = V2Paths.dataDirectory(home: home) + "/cache/a"
        files.makeFile(lock, size: 1)
        let report = try executor().run([item("v2", paths: [V2Paths.dataDirectory(home: home) + "/cache"])])
        guard case .skipped(let why) = report.results[0].outcome, why.hasPrefix("目标是清理工具自己的数据目录") else {
            return XCTFail("\(report.results[0].outcome)")
        }
        XCTAssertTrue(files.fileExists(lock))
    }

    func testMixedItemWithToolDataDirectoryIsSkippedWhole() throws {
        files.makeFile(home + "/Library/Caches/ok/a", size: 3)
        files.makeFile(EnginePaths.dataDirectory(home: home) + "/x/a", size: 1)
        let report = try executor().run([item("mixed", paths: [home + "/Library/Caches/ok",
                                                               EnginePaths.dataDirectory(home: home).uppercased() + "/x"])])
        guard case .skipped(let why) = report.results[0].outcome, why.hasPrefix("目标是清理工具自己的数据目录") else {
            return XCTFail("\(report.results[0].outcome)")
        }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/ok/a"))
        XCTAssertTrue(files.fileExists(EnginePaths.dataDirectory(home: home) + "/x/a"))
    }

    func testMissingCommandFails() throws {
        let report = try executor().run([item("nope", paths: [], action: .command(["no-such-tool", "clean"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.failed("找不到命令或命令无法启动、超时：no-such-tool")])
        XCTAssertEqual(report.results.map(\.reason), [.commandFailed])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testExecutableWithEqualsOrColonIsRefused() throws {
        files.makeFile("/opt/homebrew/bin/a=b", size: 1)
        files.makeFile("/opt/home:brew/tool", size: 1)
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        let report = try executor().run([item("eq", paths: [], action: .command(["/opt/homebrew/bin/a=b"])),
                                         item("colon", paths: [], action: .command(["/opt/home:brew/tool"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.failed("找不到命令或命令无法启动、超时：/opt/homebrew/bin/a=b"),
                                                       .failed("找不到命令或命令无法启动、超时：/opt/home:brew/tool")])
        XCTAssertEqual(report.results.map(\.reason), [.commandFailed, .commandFailed])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testDuplicatePathIsMovedOnce() throws {
        files.makeFile(home + "/.gradle/caches/a", size: 70)
        let report = try executor().run([item("gradle", paths: [home + "/.gradle/caches", home + "/.gradle/caches"])])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(report.recoveryBytes, 70)
        XCTAssertEqual(recovery.list().first?.entries.count, 1)
    }

    func testRecoveryBatchFailureIsRememberedWithoutRetry() throws {
        let tmp = TestEnv.makeTempDir("exec")
        defer { TestEnv.remove(tmp) }
        try TestEnv.write("x", to: tmp + "/Library/Caches/A/f")
        try TestEnv.write("y", to: tmp + "/Library/Caches/B/f")
        let recoveryDir = EnginePaths.recoveryDirectory(home: tmp)
        try TestEnv.write("not a directory", to: recoveryDir)
        runner.handler = { _, _ in
            try? FileManager.default.removeItem(atPath: recoveryDir)
            return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
        }
        let real = RealFileOperations(home: tmp)
        let exec = PlanExecutor(files: real, safety: PathSafety(home: tmp, files: real), runner: runner, commandRunner: runner,
                                apps: apps, recovery: RecoveryStore(directory: recoveryDir, files: real),
                                audit: AuditLog(files: real, path: EnginePaths.auditLog(home: tmp)), sleep: { _ in })
        let report = try exec.run([item("a", paths: [tmp + "/Library/Caches/A"]),
                                   item("fix", paths: [], action: .command(["/usr/bin/true"])),
                                   item("b", paths: [tmp + "/Library/Caches/B"])])
        XCTAssertEqual(report.results[1].outcome, .done)
        for index in [0, 2] {
            guard case .failed(let why) = report.results[index].outcome, why.hasPrefix("无法创建恢复区：") else {
                return XCTFail("\(report.results[index].outcome)")
            }
            XCTAssertEqual(report.results[index].reason, .recoveryFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/A/f"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/B/f"))
    }

    let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
    let pycharm = QuitApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm", mayQuitForUser: false)

    func testRunningAppWithoutConsentIsSkipped() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        let report = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"],
                                               preconditions: RulePreconditions(quitApps: [chrome]))])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertEqual(apps.quitRequests, [])
    }

    func testConsentedAppIsQuitOnceThenItemRuns() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        files.makeFile(home + "/Library/Caches/ChromeModel/a", size: 1)
        apps.running = [chrome.bundleID]
        let pre = RulePreconditions(quitApps: [chrome])
        let report = try executor().run([item("c1", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre),
                                         item("c2", tier: .confirm, paths: [home + "/Library/Caches/ChromeModel"], preconditions: pre)],
                                        options: ExecutionOptions(quitApps: [chrome.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done])
        XCTAssertEqual(apps.quitRequests, [chrome.bundleID])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func testForceQuitOnlyWhenConsentedAfterTimeout() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        apps.quitSucceeds = false
        let pre = RulePreconditions(quitApps: [chrome])
        let skipped = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre)],
                                         options: ExecutionOptions(quitApps: [chrome.bundleID]))
        XCTAssertEqual(skipped.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertEqual(apps.forceQuits, [])
        let done = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre)],
                                      options: ExecutionOptions(quitApps: [chrome.bundleID], forceQuitApps: [chrome.bundleID]))
        XCTAssertEqual(done.results.map(\.outcome), [.done])
        XCTAssertEqual(apps.forceQuits, [chrome.bundleID])
    }

    func testEditorsAreNeverQuitEvenWithConsent() throws {
        files.makeFile(home + "/Library/Caches/JetBrains/PyCharm/a", size: 1)
        apps.running = [pycharm.bundleID]
        let report = try executor().run([item("jb", tier: .suggested, paths: [home + "/Library/Caches/JetBrains/PyCharm"],
                                               preconditions: RulePreconditions(quitApps: [pycharm]))],
                                        options: ExecutionOptions(quitApps: [pycharm.bundleID], forceQuitApps: [pycharm.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 PyCharm")])
        XCTAssertEqual(apps.quitRequests, [])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func testOccupiedWithoutPausableServiceIsSkipped() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "") : nil
        }
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：uv(9)")])
        XCTAssertEqual(report.results.map(\.reason), [.occupied])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" })
    }

    func testPausableServiceIsStoppedThenResumedAroundTheAction() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var serviceRunning = true
        var restarted = false
        var log: [String] = []
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case GuardEvaluator.pgrepPath:
                // 重新启动后是新的进程号
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: restarted ? "12\n" : "9\n", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case "/usr/bin/env", "/bin/sh":
                // /bin/sh -c '"$@" …&' sh /usr/bin/nohup /usr/bin/env PATH=… exe args…
                let command = args.dropFirst(path == "/bin/sh" ? 6 : 1).joined(separator: " ")
                log.append(command)
                if command.hasSuffix("svc stop") { serviceRunning = false }
                if command.hasSuffix("svc start") { serviceRunning = true; restarted = true }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp",
                                      stop: ["svc", "stop"], start: ["svc", "start"])
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"],
                                                                                pausableServices: [service]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(log, ["/opt/homebrew/bin/svc stop", "/opt/homebrew/bin/uv cache prune", "/opt/homebrew/bin/svc start"])
        XCTAssertEqual(report.serviceIssues, [])
        let pgrep = runner.calls.first { $0.launchPath == GuardEvaluator.pgrepPath }
        XCTAssertEqual(pgrep?.arguments, ["-u", String(getuid()), "-f", "chroma-mcp"])
        let stop = runner.calls.first { $0.launchPath == "/usr/bin/env" }
        XCTAssertEqual(stop?.arguments, ["PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin/svc", "stop"])
        let start = runner.calls.first { $0.launchPath == "/bin/sh" }
        XCTAssertEqual(start?.arguments, ["-c", "\"$@\" </dev/null >/dev/null 2>&1 &", "sh", "/usr/bin/nohup", "/usr/bin/env",
                                          "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin/svc", "start"])
    }

    func testRunReportsServicePauseAndResumeAsItemSteps() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var serviceRunning = true
        var restarted = false
        var log: [String] = []
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case GuardEvaluator.pgrepPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: restarted ? "12\n" : "9\n", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case "/usr/bin/env", "/bin/sh":
                let command = args.last ?? ""
                log.append(command)
                if command == "stop" { serviceRunning = false }
                if command == "start" { serviceRunning = true; restarted = true }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let report = try executor().run([item("a", paths: [], action: .command(["uv", "cache", "clean"])), serviceItem()],
                                        onItemStep: { index, step in log.append("\(index) \(step)") })
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done])
        XCTAssertEqual(log, ["clean", "1 正在暂停 记忆服务…", "stop", "1 正在清理…", "prune", "1 正在恢复 记忆服务…", "start"])
    }

    func testServiceThatFailsToComeBackIsReported() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var serviceRunning = true
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath, GuardEvaluator.pgrepPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: path == GuardEvaluator.lsofPath ? "p9\0cuv\0n/x\0" : "9\n", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case "/usr/bin/env":
                if args.last == "stop" { serviceRunning = false }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp", stop: ["svc", "stop"], start: ["svc", "start"])
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"],
                                                                                pausableServices: [service]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(report.serviceIssues, ["服务 记忆服务 未能自动恢复，请手动运行：svc start"])
    }

    func testUnknownLockStatusNeverPausesServices() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            path == GuardEvaluator.pgrepPath ? ProcessResult(exitStatus: 0, stdout: "9\n", stderr: "") : nil
        }
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp", stop: ["svc", "stop"], start: ["svc", "start"])
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"],
                                                                                pausableServices: [service]))])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("无法确认是否被占用：lsof 无法启动")])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" })
    }

    /// 服务停止后被别的程序以新进程号重新拉起并再次占用：跳过该项；恢复时服务已在运行，不重复启动也不报问题。
    func testRespawnedServiceIsNotStartedAgain() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var stopped = false
        var log: [String] = []
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath:
                return ProcessResult(exitStatus: 0, stdout: stopped ? "p10\0cchroma\0n/x\0" : "p9\0cchroma\0n/x\0", stderr: "")
            case GuardEvaluator.pgrepPath:
                return ProcessResult(exitStatus: 0, stdout: stopped ? "10\n" : "9\n", stderr: "")
            case "/usr/bin/env", "/bin/sh":
                log.append(args.last ?? "")
                if args.last == "stop" { stopped = true }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let report = try executor().run([serviceItem()])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("暂停服务后仍被占用：被占用：chroma(10)")])
        XCTAssertEqual(report.results.map(\.reason), [.occupied])
        XCTAssertEqual(log, ["stop"])
        XCTAssertEqual(report.serviceIssues, [])
    }

    func testOccupierThatIsNotTheServiceIsNeverPaused() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            switch path {
            case GuardEvaluator.lsofPath: return ProcessResult(exitStatus: 0, stdout: "p7\0cother\0n/x\0", stderr: "")
            case GuardEvaluator.pgrepPath: return ProcessResult(exitStatus: 0, stdout: "9\n", stderr: "")
            default: return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            }
        }
        let report = try executor().run([serviceItem()])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：other(7)")])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" || $0.launchPath == "/bin/sh" })
    }

    func testServiceAndAnotherOccupierIsNeverPaused() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            switch path {
            case GuardEvaluator.lsofPath:
                return ProcessResult(exitStatus: 0, stdout: "p9\0cchroma\0n/x\0p7\0cother\0n/x\0", stderr: "")
            case GuardEvaluator.pgrepPath: return ProcessResult(exitStatus: 0, stdout: "9\n", stderr: "")
            default: return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            }
        }
        let report = try executor().run([serviceItem()])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：chroma(9), other(7)")])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" || $0.launchPath == "/bin/sh" })
    }

    func testServiceNotRunningIsNeverStoppedOrStarted() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            switch path {
            case GuardEvaluator.lsofPath: return ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "")
            case GuardEvaluator.pgrepPath: return ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            default: return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            }
        }
        let report = try executor().run([serviceItem()])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：uv(9)")])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" || $0.launchPath == "/bin/sh" })
    }

    func testDisplayOnlyItemNeverQuitsItsApp() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        let report = try executor().run([item("c", tier: .displayOnly, paths: [home + "/Library/Caches/Chrome"],
                                               preconditions: RulePreconditions(quitApps: [chrome]))],
                                        options: ExecutionOptions(quitApps: [chrome.bundleID], forceQuitApps: [chrome.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("只展示项不可执行")])
        XCTAssertEqual(apps.quitRequests, [])
    }

    func testItemFailingRevalidationNeverQuitsItsApp() throws {
        files.makeFile(home + "/Documents/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        let report = try executor().run([item("c", paths: [home + "/Documents/Chrome"],
                                               preconditions: RulePreconditions(quitApps: [chrome]))],
                                        options: ExecutionOptions(quitApps: [chrome.bundleID]))
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(apps.quitRequests, [])
        XCTAssertTrue(files.fileExists(home + "/Documents/Chrome/a"))
    }

    func testItemBlockedByOtherOccupierNeverQuitsItsApp() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        files.makeFile(home + "/Library/Caches/Chrome/.lock", size: 0)
        apps.running = [chrome.bundleID]
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p7\0cother\0n/x\0", stderr: "") : nil
        }
        let report = try executor().run([item("c", paths: [home + "/Library/Caches/Chrome"],
                                               preconditions: RulePreconditions(quitApps: [chrome],
                                                                                lockfiles: ["~/Library/Caches/Chrome/.lock"]))],
                                        options: ExecutionOptions(quitApps: [chrome.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertEqual(apps.quitRequests, [])
    }

    func testQuitAuditFailureMeansNoQuit() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        let log = EnginePaths.auditLog(home: home)
        // 在 run.start 写入之后、退出应用之前把审计日志换成目录，让之后的必需审计失败。
        let control = AuditBreakingAppControl(inner: apps) { [files] in
            try? files!.removeItem(atPath: log)
            files!.makeDirectory(log)
        }
        apps.running = [chrome.bundleID]
        let report = try PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner,
                                      commandRunner: runner, apps: control, recovery: recovery,
                                      audit: AuditLog(files: files, path: log), now: { self.clock }, sleep: { self.clock += $0 })
            .run([item("c", paths: [home + "/Library/Caches/Chrome"], preconditions: RulePreconditions(quitApps: [chrome]))],
                 options: ExecutionOptions(quitApps: [chrome.bundleID], forceQuitApps: [chrome.bundleID]))
        XCTAssertEqual(apps.quitRequests, [])
        XCTAssertEqual(apps.forceQuits, [])
        guard case .failed = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/Chrome/a"))
    }

    /// 同一匹配模式下有个与锁无关的进程 50 一直在：暂停只等占用锁的 9 退出；恢复时必须出现暂停前没有的新进程才算恢复。
    func runWithUnrelatedMatchingProcess(afterStart: String) throws -> RunReport {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var phase = "before"
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath:
                return phase == "before" ? ProcessResult(exitStatus: 0, stdout: "p9\0cchroma\0n/x\0", stderr: "")
                                         : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case GuardEvaluator.pgrepPath:
                let out = ["before": "9\n50\n", "stopped": "50\n", "started": afterStart][phase]!
                return ProcessResult(exitStatus: 0, stdout: out, stderr: "")
            case "/usr/bin/env", "/bin/sh":
                if args.last == "stop" { phase = "stopped" }
                if args.last == "start" { phase = "started" }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        return try executor().run([serviceItem()])
    }

    func testUnrelatedMatchingProcessDoesNotBlockPauseAndNewProcessCountsAsBack() throws {
        let report = try runWithUnrelatedMatchingProcess(afterStart: "50\n77\n")
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertTrue(runner.calls.contains { $0.launchPath == "/bin/sh" && $0.arguments.last == "start" })
        XCTAssertEqual(report.serviceIssues, [])
        // 暂停没有空等到超时
        XCTAssertLessThan(clock.timeIntervalSince(EngineFixture.daysBefore(0)), 20)
    }

    func testUnrelatedMatchingProcessAloneDoesNotCountAsBack() throws {
        let report = try runWithUnrelatedMatchingProcess(afterStart: "50\n")
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertTrue(runner.calls.contains { $0.launchPath == "/bin/sh" && $0.arguments.last == "start" })
        XCTAssertEqual(report.serviceIssues, ["服务 记忆服务 未能自动恢复，请手动运行：svc start"])
    }

    func testWaitUntilTerminatesWithFrozenClock() {
        var sleeps = 0
        let executor = PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner,
                                    commandRunner: runner, apps: apps, recovery: recovery,
                                    audit: AuditLog(files: files, path: EnginePaths.auditLog(home: home)),
                                    now: { EngineFixture.daysBefore(0) }, sleep: { _ in sleeps += 1 })
        XCTAssertFalse(executor.waitUntil(2) { false })
        XCTAssertLessThanOrEqual(sleeps, 6)
    }

    func testExecutorRecordsItemIdentityInRecovery() throws {
        files.makeFile(home + "/.gradle/caches/a", size: 5)
        _ = try executor().run([item("gradle", paths: [home + "/.gradle/caches"])])
        let entry = try XCTUnwrap(recovery.list().first?.entries.first)
        XCTAssertEqual(entry.itemID, "gradle")
        XCTAssertEqual(entry.itemTitle, "gradle")
    }

    func auditOps() -> [String] {
        AuditLog(files: files, path: EnginePaths.auditLog(home: home)).readAll().map(\.op)
    }

    func testCancelBeforeFirstItemRunsNothing() throws {
        files.makeFile(home + "/Library/Caches/A/x", size: 1)
        files.makeFile(home + "/Library/Caches/B/x", size: 1)
        let cancellation = OperationCancellation()
        cancellation.cancel()
        var started: [Int] = []
        var finished: [Int] = []
        let report = try executor().run(
            [item("a", paths: [home + "/Library/Caches/A"]), item("b", paths: [home + "/Library/Caches/B"])],
            cancellation: cancellation,
            onItemStart: { index, _ in started.append(index) },
            onItemFinish: { index, _ in finished.append(index) })
        XCTAssertEqual(started, [])
        XCTAssertEqual(finished, [0, 1])
        XCTAssertEqual(report.results.map(\.reason), [.cancelled, .cancelled])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("已停止，未执行"), .skipped("已停止，未执行")])
        XCTAssertFalse(auditOps().contains("run.item.intent"))
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/A/x"))
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/B/x"))
    }

    func testQuitPhaseQuitsSharedAppOnceAndAudits() {
        files.makeFile(home + "/Library/Caches/C1/x", size: 1)
        files.makeFile(home + "/Library/Caches/C2/x", size: 1)
        apps.running = [chrome.bundleID]
        let pre = RulePreconditions(quitApps: [chrome])
        let items = [item("c1", tier: .suggested, paths: [home + "/Library/Caches/C1"], preconditions: pre),
                     item("c2", tier: .suggested, paths: [home + "/Library/Caches/C2"], preconditions: pre)]
        XCTAssertEqual(executor().quitPhase(items, consentedApps: [chrome.bundleID]), [])
        XCTAssertEqual(apps.quitRequests, [chrome.bundleID])
        XCTAssertEqual(auditOps().filter { $0 == "run.app.quit" }.count, 1)
    }

    func testForceQuitWritesAudit() {
        apps.running = [chrome.bundleID]
        executor().forceQuit([chrome])
        XCTAssertEqual(apps.forceQuits, [chrome.bundleID])
        XCTAssertEqual(auditOps().filter { $0 == "run.app.force-quit" }.count, 1)
    }

    func testQuitPhaseAuditFailureMeansNoQuit() {
        files.makeFile(home + "/Library/Caches/C/x", size: 1)
        files.makeDirectory(EnginePaths.auditLog(home: home))
        apps.running = [chrome.bundleID]
        let items = [item("c", tier: .suggested, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [chrome]))]
        XCTAssertEqual(executor().quitPhase(items, consentedApps: [chrome.bundleID]), [])
        XCTAssertEqual(apps.quitRequests, [])
        executor().forceQuit([chrome])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func serviceItem() -> CleanItem {
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp", stop: ["svc", "stop"], start: ["svc", "start"])
        return item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                    preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"], pausableServices: [service]))
    }

    func testQuitPhaseReturnsAppsThatDidNotQuit() {
        files.makeFile(home + "/Library/Caches/C/x", size: 1)
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let pycharm = QuitApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm", mayQuitForUser: false)
        apps.running = [chrome.bundleID, pycharm.bundleID]
        apps.quitSucceeds = false
        let items = [item("c", tier: .suggested, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [chrome, pycharm]))]
        let stuck = executor().quitPhase(items, consentedApps: [chrome.bundleID, pycharm.bundleID])
        XCTAssertEqual(stuck, [chrome])
        XCTAssertEqual(apps.quitRequests, [chrome.bundleID])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func testQuitPhaseSkipsUnconsentedAppsAndItemsThatWillNotRun() {
        files.makeFile(home + "/Library/Caches/C/x", size: 1)
        let other = QuitApp(name: "Other", bundleID: "com.example.other")
        apps.running = [chrome.bundleID, other.bundleID]
        let items = [item("c", tier: .suggested, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [chrome])),
                     item("gone", paths: [home + "/Library/Caches/Gone"], preconditions: RulePreconditions(quitApps: [other])),
                     item("show", tier: .displayOnly, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [other]))]
        XCTAssertEqual(executor().quitPhase(items, consentedApps: [other.bundleID]), [])
        XCTAssertEqual(apps.quitRequests, [])
    }

    func testQuitPhaseStopsQuittingAppsOnceCancelled() {
        files.makeFile(home + "/Library/Caches/C/x", size: 1)
        let slack = QuitApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        apps.running = [chrome.bundleID, slack.bundleID]
        apps.quitSucceeds = false
        let cancellation = OperationCancellation()
        apps.onRequestQuit = { _ in cancellation.cancel() }  // 等第一个应用退出时用户点了「停止」
        let items = [item("c", tier: .suggested, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [chrome, slack]))]
        let stuck = executor().quitPhase(items, consentedApps: [chrome.bundleID, slack.bundleID], cancellation: cancellation)
        XCTAssertEqual(stuck, [chrome])
        XCTAssertEqual(apps.quitRequests, [chrome.bundleID])
        let quitAudits = AuditLog(files: files, path: EnginePaths.auditLog(home: home)).readAll()
            .filter { $0.op == "run.app.quit" }.map(\.detail)
        XCTAssertEqual(quitAudits, [chrome.bundleID])
    }

    func testQuitPhaseReportsEachAppItQuits() {
        files.makeFile(home + "/Library/Caches/C/x", size: 1)
        let slack = QuitApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let other = QuitApp(name: "Other", bundleID: "com.example.other")
        apps.running = [chrome.bundleID, slack.bundleID, other.bundleID]
        var log: [String] = []
        apps.onRequestQuit = { log.append("quit " + $0) }
        let items = [item("c", tier: .suggested, paths: [home + "/Library/Caches/C"],
                          preconditions: RulePreconditions(quitApps: [chrome, other, slack]))]
        _ = executor().quitPhase(items, consentedApps: [chrome.bundleID, slack.bundleID], onApp: { log.append("app " + $0.name) })
        XCTAssertEqual(log, ["app Chrome", "quit " + chrome.bundleID, "app Slack", "quit " + slack.bundleID])
    }

    func testForceQuitOnlyQuittableRunningApps() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let pycharm = QuitApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm", mayQuitForUser: false)
        apps.running = [chrome.bundleID, pycharm.bundleID]
        executor().forceQuit([chrome, pycharm])
        XCTAssertEqual(apps.forceQuits, [chrome.bundleID])
    }

    func testRunReportsProgressAndStops() throws {
        files.makeFile(home + "/Library/Caches/A/x", size: 1)
        files.makeFile(home + "/Library/Caches/B/x", size: 1)
        let cancellation = OperationCancellation()
        var started: [Int] = []
        var finished: [String] = []
        let report = try executor().run(
            [item("a", paths: [home + "/Library/Caches/A"]), item("b", paths: [home + "/Library/Caches/B"])],
            cancellation: cancellation,
            onItemStart: { index, _ in started.append(index) },
            onItemFinish: { _, result in finished.append(result.itemID); cancellation.cancel() })
        XCTAssertEqual(started, [0])
        XCTAssertEqual(finished, ["a", "b"])
        XCTAssertEqual(report.results.map(\.reason), [nil, .cancelled])
        XCTAssertEqual(report.results[1].outcome, .skipped("已停止，未执行"))
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/B/x"))
        let intents = AuditLog(files: files, path: EnginePaths.auditLog(home: home)).readAll()
            .filter { $0.op == "run.item.intent" }.map(\.detail)
        XCTAssertEqual(intents, ["a"])
    }
}

/// 第一次查询应用是否运行时触发 onFirstCheck（此时 run.start 已写入），其余转发给内部的假实现。
final class AuditBreakingAppControl: AppControl {
    let inner: FakeAppControl
    var onFirstCheck: (() -> Void)?

    init(inner: FakeAppControl, onFirstCheck: @escaping () -> Void) {
        self.inner = inner
        self.onFirstCheck = onFirstCheck
    }

    func isRunning(bundleID: String) -> Bool {
        onFirstCheck?()
        onFirstCheck = nil
        return inner.isRunning(bundleID: bundleID)
    }

    func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool { inner.requestQuit(bundleID: bundleID, timeout: timeout) }
    func forceQuit(bundleID: String) -> Bool { inner.forceQuit(bundleID: bundleID) }
}
