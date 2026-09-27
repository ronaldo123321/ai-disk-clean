import XCTest
@testable import CleanerCore

final class EngineScannerTests: XCTestCase {
    let home = EngineFixture.home

    func rule(_ id: String, tier: CleanTier, target: String, quit: [QuitApp]? = nil, locks: [String]? = nil) -> CleanRule {
        let action: RuleAction = tier == .displayOnly ? .noAction : .recover
        return CleanRule(id: id, name: id, app: id, category: .dev, tier: tier, detect: nil, targets: [target],
                         action: action, preconditions: RulePreconditions(quitApps: quit, lockfiles: locks),
                         copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    }

    func scan(_ files: InMemoryFileOperations, rules: [CleanRule], apps: FakeAppControl = FakeAppControl(),
              spaceMap: SpaceMapDetector? = nil, minimumItemBytes: Int64 = 1 << 20,
              extraDetectors: [Detector] = []) -> ScanResult {
        let context = EngineFixture.context(files)
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        return EngineScanner(context: context, detectors: [RuleDetector(rules: rules)] + extraDetectors, spaceMap: spaceMap,
                              checker: checker, minimumItemBytes: minimumItemBytes).scan()
    }

    func testItemsAreSizedSortedByTierThenBytes() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 100)
        files.makeFile(home + "/Library/Caches/B/x", size: 900)
        files.makeFile(home + "/Library/Caches/C/x", size: 500)
        let result = scan(files, rules: [rule("a", tier: .suggested, target: "~/Library/Caches/A"),
                                         rule("b", tier: .safe, target: "~/Library/Caches/B"),
                                         rule("c", tier: .suggested, target: "~/Library/Caches/C")],
                          minimumItemBytes: 0)
        XCTAssertEqual(result.items.map(\.id), ["rule:b", "rule:c", "rule:a"])
        XCTAssertEqual(result.items[0].reclaimableBytes, 900)
    }

    func testDisplayOnlyHasNoReclaimableBytesAndNoBlockers() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 100)
        let result = scan(files, rules: [rule("codex", tier: .displayOnly, target: "~/.codex/sessions")])
        XCTAssertEqual(result.items[0].apparentBytes, 100)
        XCTAssertEqual(result.items[0].reclaimableBytes, 0)
    }

    func testBlockersAreFilledAtScan() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/Chrome/x", size: 1)
        let apps = FakeAppControl()
        apps.running = ["com.google.Chrome"]
        let result = scan(files, rules: [rule("chrome", tier: .suggested, target: "~/Library/Caches/Chrome",
                                              quit: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")])], apps: apps,
                          minimumItemBytes: 0)
        XCTAssertEqual(result.items[0].blockers, [.appRunning(name: "Chrome", bundleID: "com.google.Chrome")])
    }

    func testSpaceMapSubtractsCoveredPaths() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 5_000)
        files.makeFile(home + "/.codex/other", size: 2_000)
        let result = scan(files, rules: [rule("codex", tier: .displayOnly, target: "~/.codex/sessions")],
                          spaceMap: SpaceMapDetector(threshold: 1_000))
        XCTAssertEqual(result.items.first { $0.id.hasPrefix("space:") }?.apparentBytes, 2_000)
    }

    func testDefaultSelectionFollowsTierAndIgnoresNonAppBlockers() {
        func item(_ id: String, _ tier: CleanTier, _ blockers: [Blocker] = [], bytes: Int64 = 10) -> CleanItem {
            var i = CleanItem(id: id, app: id, category: .dev, tier: tier, title: id, paths: [], action: .recover,
                              preconditions: .empty, copy: RuleCopy(what: "w", impact: "i", regrows: nil))
            i.blockers = blockers
            i.reclaimableBytes = bytes
            return i
        }
        let scanResult = ScanResult(generatedAt: Date(), disk: nil, items: [
            item("safe", .safe), item("suggested", .suggested, [.appRunning(name: "Chrome", bundleID: "c")]),
            item("busy", .safe, [.occupied("uv(1)")]), item("confirm", .confirm), item("show", .displayOnly)])
        let plan = PlanBuilder.build(from: scanResult)
        XCTAssertEqual(plan.selectedIDs, ["safe", "suggested"])
        XCTAssertEqual(plan.estimatedReclaimableBytes, 20)
        XCTAssertEqual(plan.appsToQuit, [QuitApp(name: "Chrome", bundleID: "c")])
    }

    /// 大小由识别器直接给出，扫描不再重新测量的测试用识别器。
    struct FakeSizedDetector: Detector {
        let item: CleanItem
        var name: String { "fake" }
        func detect(_ context: DetectContext) -> [CleanItem] { [item] }
    }

    func testActionableItemUnderThresholdIsDropped() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 100)
        let result = scan(files, rules: [rule("a", tier: .suggested, target: "~/Library/Caches/A")])
        XCTAssertTrue(result.items.isEmpty)
    }

    func testActionableItemAtThresholdIsKept() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 1 << 20)
        let result = scan(files, rules: [rule("a", tier: .suggested, target: "~/Library/Caches/A")])
        XCTAssertEqual(result.items.map(\.id), ["rule:a"])
    }

    func testDisplayOnlyItemUnderThresholdIsKept() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 100)
        let result = scan(files, rules: [rule("codex", tier: .displayOnly, target: "~/.codex/sessions")])
        XCTAssertEqual(result.items.map(\.id), ["rule:codex"])
    }

    /// 转发到内存文件系统，但对指定路径的 childrenOfDirectory 模拟「无法读取」（用于测试 Sizer 上报
    /// unreadable 时，体积过小的项仍应保留）。
    final class UnreadableDirFileOperations: FileOperations {
        let base: InMemoryFileOperations
        let blockedPath: String
        init(base: InMemoryFileOperations, blockedPath: String) {
            self.base = base
            self.blockedPath = blockedPath
        }
        func homeDirectory() -> String { base.homeDirectory() }
        func attributesIfExist(atPath path: String) -> FileAttributes? { base.attributesIfExist(atPath: path) }
        func realPath(ofPath path: String) -> String? { base.realPath(ofPath: path) }
        func childrenOfDirectory(atPath path: String) throws -> [String] {
            if path == blockedPath { throw FileOpError.posix(path: path, errno: EACCES, context: "测试模拟无法读取") }
            return try base.childrenOfDirectory(atPath: path)
        }
        func fileExists(_ path: String) -> Bool { base.fileExists(path) }
        func removeItem(atPath path: String) throws { try base.removeItem(atPath: path) }
        func moveItem(fromPath: String, toPath: String) throws { try base.moveItem(fromPath: fromPath, toPath: toPath) }
        func trashItem(atPath path: String) throws -> String { try base.trashItem(atPath: path) }
        func createDirectory(atPath path: String, intermediate: Bool) throws {
            try base.createDirectory(atPath: path, intermediate: intermediate)
        }
        func truncateFile(atPath path: String) throws { try base.truncateFile(atPath: path) }
        func writeFile(_ data: Data, toPath path: String) throws { try base.writeFile(data, toPath: path) }
        func readFile(atPath path: String) -> Data? { base.readFile(atPath: path) }
        func appendFile(_ data: Data, toPath path: String) throws { try base.appendFile(data, toPath: path) }
        func volumeSummary(atPath path: String) -> DiskSummary? { base.volumeSummary(atPath: path) }
    }

    func testUnderThresholdItemWithUnreadableNoteIsKept() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/locked/x", size: 1)
        let blocked = UnreadableDirFileOperations(base: files, blockedPath: home + "/Library/Caches/A/locked")
        let context = DetectContext(files: blocked, safety: PathSafety(home: home, files: blocked),
                                    runner: FakeProcessRunner(), now: EngineFixture.context(files).now)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: blocked, runner: FakeProcessRunner()), home: home)
        let result = EngineScanner(context: context, detectors: [RuleDetector(rules: [rule("a", tier: .suggested, target: "~/Library/Caches/A")])],
                                    spaceMap: nil, checker: checker).scan()
        XCTAssertEqual(result.items.map(\.id), ["rule:a"])
        XCTAssertTrue(result.items[0].notes.contains { $0.contains("无法读取") })
    }

    func testSizedByDetectorZeroBytesItemIsKept() {
        let files = InMemoryFileOperations(home: home)
        var zeroByteItem = CleanItem(id: "docker:dead", app: "Docker", category: .dev, tier: .suggested,
                                      title: "t", paths: [], action: .recover, preconditions: .empty,
                                      copy: RuleCopy(what: "w", impact: "i", regrows: nil))
        zeroByteItem.sizedByDetector = true
        zeroByteItem.apparentBytes = 0
        let result = scan(files, rules: [], extraDetectors: [FakeSizedDetector(item: zeroByteItem)])
        XCTAssertEqual(result.items.map(\.id), ["docker:dead"])
    }

    func testScanReportsStepsInOrder() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 2 << 20)
        var steps: [ScanStep] = []
        let context = EngineFixture.context(files)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        let scanner = EngineScanner(context: context, detectors: [RuleDetector(rules: [rule("a", tier: .safe, target: "~/Library/Caches/A")])],
                                    spaceMap: SpaceMapDetector(threshold: 1 << 40), checker: checker)
        let result = scanner.scan(onStep: { steps.append($0) })
        XCTAssertEqual(steps.first, .detecting("规则"))
        XCTAssertTrue(steps.contains(.spaceMap))
        XCTAssertEqual(steps.last, .checkingBlockers)
        XCTAssertFalse(result.cancelled)
    }

    func testCancelledScanStopsAndIsMarked() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 2 << 20)
        let cancellation = OperationCancellation()
        cancellation.cancel()
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: FakeProcessRunner(),
                                    now: Date(), cancellation: cancellation)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        let result = EngineScanner(context: context, detectors: [RuleDetector(rules: [rule("a", tier: .safe, target: "~/Library/Caches/A")])],
                                   spaceMap: nil, checker: checker).scan()
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.items, [])
    }

    func testCancelledScanProducesEmptyDefaultSelection() {
        let items = [CleanItem(id: "a", app: "a", category: .dev, tier: .safe, title: "a", paths: [],
                                action: .recover, preconditions: .empty, copy: RuleCopy(what: "w", impact: "i", regrows: nil))]
        let scanResult = ScanResult(generatedAt: Date(), disk: nil, items: items, cancelled: true)
        let plan = PlanBuilder.build(from: scanResult)
        XCTAssertEqual(plan.selectedIDs, [])
    }

    func testCancellingDuringSizingStepMarksResultCancelled() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 2 << 20)
        let cancellation = OperationCancellation()
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: FakeProcessRunner(),
                                    now: EngineFixture.context(files).now, cancellation: cancellation)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        let scanner = EngineScanner(context: context, detectors: [RuleDetector(rules: [rule("a", tier: .safe, target: "~/Library/Caches/A")])],
                                    spaceMap: SpaceMapDetector(threshold: 1 << 40), checker: checker)
        let result = scanner.scan(onStep: { step in
            if case .sizing = step { cancellation.cancel() }
        })
        XCTAssertTrue(result.cancelled)
    }

    func testCancellingDuringSpaceMapStepMarksResultCancelledAndOmitsSpaceItems() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 5_000)
        files.makeFile(home + "/.codex/other", size: 2_000)
        let cancellation = OperationCancellation()
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: FakeProcessRunner(),
                                    now: EngineFixture.context(files).now, cancellation: cancellation)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        let scanner = EngineScanner(context: context, detectors: [RuleDetector(rules: [rule("codex", tier: .displayOnly, target: "~/.codex/sessions")])],
                                    spaceMap: SpaceMapDetector(threshold: 1_000), checker: checker)
        let result = scanner.scan(onStep: { step in
            if step == .spaceMap { cancellation.cancel() }
        })
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.items.contains { $0.id.hasPrefix("space:") })
    }

    func testCancellingOnFirstDetectingStepOmitsSecondDetectorItems() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 2 << 20)
        let cancellation = OperationCancellation()
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: FakeProcessRunner(),
                                    now: EngineFixture.context(files).now, cancellation: cancellation)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        let scanner = EngineScanner(context: context, detectors: [
            RuleDetector(rules: [rule("a", tier: .safe, target: "~/Library/Caches/A")]),
            RuleDetector(rules: [rule("b", tier: .safe, target: "~/Library/Caches/A")]),
        ], spaceMap: nil, checker: checker)
        var detectingCount = 0
        let result = scanner.scan(onStep: { step in
            if case .detecting = step {
                detectingCount += 1
                if detectingCount == 1 { cancellation.cancel() }
            }
        })
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.items.contains { $0.id == "rule:b" })
    }

    func testByAppGroupsAndSortsByBytes() {
        func item(_ id: String, app: String, bytes: Int64) -> CleanItem {
            var i = CleanItem(id: id, app: app, category: .dev, tier: .safe, title: id, paths: [], action: .recover,
                              preconditions: .empty, copy: RuleCopy(what: "w", impact: "i", regrows: nil))
            i.apparentBytes = bytes
            return i
        }
        let plan = CleanPlan(items: [item("a", app: "Chrome", bytes: 5), item("b", app: "uv", bytes: 9),
                                     item("c", app: "Chrome", bytes: 6)], selectedIDs: [])
        XCTAssertEqual(plan.byApp.map(\.app), ["Chrome", "uv"])
        XCTAssertEqual(plan.byApp[0].bytes, 11)
    }
}
