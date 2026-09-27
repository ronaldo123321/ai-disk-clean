import XCTest
@testable import CleanerCore

/// 真实临时家目录上的端到端闭环：扫描 → 方案 → 执行（移入恢复区）→ 恢复区列表 → 还原。
final class EngineEndToEndTests: XCTestCase {
    var root: String!
    var home: String!
    var files: RealFileOperations!
    var recovery: RecoveryStore!
    var clock = Date()

    override func setUp() {
        root = TestEnv.makeTempDir("dclean-e2e")
        home = root + "/home"
        try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        files = RealFileOperations(home: home)
        recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
        clock = Date()
    }

    override func tearDown() { TestEnv.remove(root) }

    func executor() -> PlanExecutor {
        let runner = FakeProcessRunner()
        return PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner,
                            commandRunner: runner, apps: FakeAppControl(), recovery: recovery,
                            audit: AuditLog(files: files, path: EnginePaths.auditLog(home: home)),
                            now: { self.clock }, sleep: { self.clock += $0 })
    }

    /// 相对路径 → 文件内容（目录记为 "<dir>"），用来逐字节比对还原结果。
    func snapshot(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: dir)!
        while let rel = enumerator.nextObject() as? String {
            let path = dir + "/" + rel
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? Data("<dir>".utf8) : try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return out
    }

    func writeBytes(_ count: Int, seed: UInt8, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
        try data.write(to: URL(fileURLWithPath: path))
    }

    func testScanPlanExecuteListAndRestoreRoundTrip() throws {
        // 闲置 120 天的非 git Python 项目：requirements.txt + .venv（>1 MiB，过扫描阈值）。
        let project = home + "/code/oldproj"
        let venv = project + "/.venv"
        try writeBytes(700_000, seed: 1, to: venv + "/lib/site-packages/big.bin")
        try writeBytes(600_000, seed: 2, to: venv + "/bin/python")
        try TestEnv.write("requests==2.0\n", to: project + "/requirements.txt")
        try TestEnv.write("print(1)\n", to: project + "/main.py")
        // 规则目标
        let cache = home + "/Library/Caches/E2ETool"
        try writeBytes(1_200_000, seed: 3, to: cache + "/blob.bin")
        try TestEnv.write("idx", to: cache + "/sub/index")

        let old = TestEnv.daysAgo(120)
        for path in [venv + "/lib/site-packages/big.bin", venv + "/bin/python", venv + "/lib/site-packages",
                     venv + "/lib", venv + "/bin", venv, project + "/requirements.txt", project + "/main.py", project] {
            try TestEnv.setMTime(path, old)
        }
        let venvBefore = try snapshot(venv)
        let cacheBefore = try snapshot(cache)

        let pack = """
        {"version": 1, "platform": "macos", "rules": [
          {"id": "e2e-cache", "name": "E2E 缓存", "app": "E2ETool", "category": "dev", "tier": "safe",
           "targets": ["~/Library/Caches/E2ETool"], "action": {"type": "recover"},
           "copy": {"what": "测试缓存", "impact": "会重新生成"}}
        ]}
        """
        let safety = PathSafety(home: home, files: files)
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.rules.count, 1)

        let runner = FakeProcessRunner()
        let apps = FakeAppControl()
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: runner), home: home)
        let context = DetectContext(files: files, safety: safety, runner: runner, now: Date())
        let scan = EngineScanner(context: context, detectors: [RuleDetector(rules: loaded.rules), ProjectArtifactDetector()],
                                 spaceMap: nil, checker: checker).scan()
        let plan = PlanBuilder.build(from: scan)
        XCTAssertEqual(plan.selectedItems.map(\.id).sorted(), ["project:" + project, "rule:e2e-cache"])
        XCTAssertEqual(plan.selectedItems.first { $0.id == "project:" + project }?.paths, [venv])
        XCTAssertEqual(plan.selectedItems.first { $0.id == "rule:e2e-cache" }?.paths, [cache])

        let report = try executor().run(plan.selectedItems)
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done])
        XCTAssertFalse(FileManager.default.fileExists(atPath: venv))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/requirements.txt"))

        let batches = recovery.list()
        XCTAssertEqual(batches.map(\.id), [report.batchID])
        XCTAssertEqual(batches.first?.entries.map(\.originalPath).sorted(), [venv, cache].sorted())
        XCTAssertEqual(batches.first?.entries.map(\.state), [.stored, .stored])
        XCTAssertEqual(recovery.orphanBatches(), [])
        XCTAssertGreaterThan(recovery.occupiedBytes(), 0)
        XCTAssertEqual(recovery.occupiedBytes(), report.recoveryBytes)

        let restored = recovery.restore(batchID: report.batchID)
        XCTAssertEqual(restored.errors, [])
        XCTAssertEqual(restored.restored.sorted(), [venv, cache].sorted())
        XCTAssertEqual(try snapshot(venv), venvBefore)
        XCTAssertEqual(try snapshot(cache), cacheBefore)
        XCTAssertEqual(recovery.list(), [])
        XCTAssertEqual(recovery.occupiedBytes(), 0)
    }

    func testItemOutsideHomeFailsWithoutOrphaningTheBatch() throws {
        // 形如自定义规则的项，目标在临时根下、家目录外：绝不移动，也不能让同批次正常项变成读不出来的孤儿。
        let outside = root + "/outside/cache"
        try TestEnv.write("keep", to: outside + "/data")
        let inside = home + "/Library/Caches/Normal"
        try TestEnv.write("normal", to: inside + "/data")
        let insideBefore = try snapshot(inside)

        func item(_ id: String, _ path: String) -> CleanItem {
            CleanItem(id: id, app: id, category: .dev, tier: .confirm, title: id, paths: [path], action: .recover,
                      preconditions: .empty, copy: RuleCopy(what: "w", impact: "i", regrows: nil))
        }
        let report = try executor().run([item("rule:outside", outside), item("rule:inside", inside)])

        guard case .failed(let why) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(why.contains("只能把家目录内的内容移入恢复区"), why)
        XCTAssertEqual(report.results[1].outcome, .done)
        XCTAssertEqual(try String(contentsOfFile: outside + "/data"), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside))

        let batches = recovery.list()
        XCTAssertEqual(batches.map(\.id), [report.batchID])
        XCTAssertEqual(batches.first?.entries.map(\.originalPath), [inside])
        XCTAssertEqual(recovery.orphanBatches(), [])

        let restored = recovery.restore(batchID: report.batchID)
        XCTAssertEqual(restored.errors, [])
        XCTAssertEqual(try snapshot(inside), insideBefore)
        XCTAssertEqual(recovery.list(), [])
    }
}
