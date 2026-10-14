import XCTest
import CleanerCore
@testable import AppCore

final class PriorityOneTests: XCTestCase {
    func testSavingSameOrEquivalentHomeScopePreservesSelection() {
        let engine = FakeEngineService(); engine.scanResult.items = [makeItem("a")]
        let model = model(engine); model.startScan()
        let selected = model.selectedIDs
        model.setScanOptions(model.scanOptions)
        model.setScanOptions(ScanOptions(projectRoots: [model.homeDirectory, model.homeDirectory + "/"]))
        XCTAssertFalse(model.requiresRescan)
        XCTAssertEqual(model.selectedIDs, selected)
        XCTAssertNil(model.selectionUnavailableReason(engine.scanResult.items[0]))
    }
    func testReasonChangesOnCancelFailureAndClearsOnSuccess() {
        let engine = FakeEngineService(); engine.scanResult.items = [makeItem("a")]
        let model = model(engine); model.startScan()
        model.setScanOptions(ScanOptions(projectRoots: []))
        XCTAssertTrue(model.rescanReason?.contains("范围") == true)
        XCTAssertTrue(model.selectionUnavailableReason(engine.scanResult.items[0])?.contains("重新扫描") == true)
        engine.cancelDuringScan = true; model.startScan()
        XCTAssertTrue(model.rescanReason?.contains("取消") == true)
        engine.cancelDuringScan = false; engine.scanError = NSError(domain: "test", code: 1); model.startScan()
        XCTAssertTrue(model.rescanReason?.contains("未成功") == true)
        engine.scanError = nil; model.startScan()
        XCTAssertNil(model.rescanReason)
    }
    func testAddingNestedRootStillInvalidatesBecauseScanDepthChanges() {
        let engine = FakeEngineService(); engine.scanResult.items = [makeItem("a")]
        let model = model(engine); model.startScan()
        model.setScanOptions(ScanOptions(projectRoots: [model.homeDirectory, model.homeDirectory + "/work"]))
        XCTAssertTrue(model.requiresRescan)
    }
    func testKeptAndDisplayOnlyReasonsExplainNextStep() {
        let engine = FakeEngineService()
        var a = makeItem("a"); a.paths = ["/work/cache"]
        let display = makeItem("display", tier: .displayOnly)
        engine.scanResult.items = [a, display]
        let model = model(engine); model.startScan(); model.keep(a)
        XCTAssertTrue(model.selectionUnavailableReason(a)?.contains("扫描范围") == true)
        XCTAssertTrue(model.selectionUnavailableReason(display)?.contains("仅展示") == true)
        XCTAssertFalse(model.requiresRescan)
    }
    func model(_ engine: FakeEngineService, preferences: UserDefaults? = nil) -> AppModel {
        AppModel(engine: engine, now: { FakeEngineService.scannedAt }, preferences: preferences, background: { $0() }, main: { $0() })
    }
    func testScopeChangeInvalidatesSelectionAndCancellationDoesNotReenableIt() {
        let engine = FakeEngineService()
        engine.scanResult.items = [makeItem("a")]
        let model = model(engine)
        model.startScan()
        model.setScanOptions(ScanOptions(projectRoots: []))
        XCTAssertTrue(model.requiresRescan)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        model.toggle("a")
        XCTAssertTrue(model.selectedIDs.isEmpty)
        engine.cancelDuringScan = true
        model.startScan()
        XCTAssertTrue(model.requiresRescan)
    }
    func testKeepPersistsAndNeverReturnsToDefaultSelection() throws {
        let name = "disk-cleaner-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let engine = FakeEngineService()
        var a = makeItem("a"); a.paths = ["/Users/tester/work/app/.next"]
        var b = makeItem("b"); b.paths = ["/Users/tester/work/app/node_modules"]
        engine.scanResult.items = [a, b]
        let model = model(engine, preferences: preferences)
        model.startScan(); model.keep(a)
        XCTAssertEqual(model.selectedIDs, ["b"])
        model.select(["a", "b"], selected: true)
        XCTAssertEqual(model.selectedIDs, ["b"])
        let reopened = self.model(engine, preferences: preferences)
        reopened.startScan()
        XCTAssertEqual(reopened.selectedIDs, ["b"])
        XCTAssertTrue(reopened.isKept(a))
    }
    func testSelectionCannotIncludeProtectedOrInvisibleSiblings() {
        let engine = FakeEngineService()
        var protected = makeItem("protected")
        protected.blockers = [.unavailable("密钥")]
        engine.scanResult.items = [makeItem("a", tier: .confirm), makeItem("b", tier: .confirm), protected]
        let model = model(engine); model.startScan()
        model.select(["a", "protected"], selected: true)
        XCTAssertEqual(model.selectedIDs, ["a"])
        model.toggle("protected")
        XCTAssertEqual(model.selectedIDs, ["a"])
    }
    func testSearchSortAndRiskFilter() {
        var a = makeItem("a"); a.projectRoot = "/work/a"; a.paths = ["/work/a/.next"]; a.apparentBytes = 2_000_000_000; a.notes = ["闲置 120 天"]
        var b = makeItem("b"); b.projectRoot = "/work/b"; b.paths = ["/work/b/target"]; b.blockers = [.unavailable("密钥")]
        XCTAssertEqual(PlanPresentation.visible([a, b], projects: true, query: ".next", filter: .all, sort: .size, isKept: { _ in false }).map(\.id), ["a"])
        XCTAssertEqual(PlanPresentation.visible([a, b], projects: true, query: "", filter: .idle, sort: .idle, isKept: { _ in false }).map(\.id), ["a"])
        XCTAssertEqual(PlanPresentation.visible([a, b], projects: true, query: "", filter: .protected, sort: .name, isKept: { _ in false }).map(\.id), ["b"])
    }
    func testRecoveryAndImmediateCountersAreSeparate() {
        var moved = makeItem("move", bytes: 2); moved.apparentBytes = 9
        let command = makeItem("command", action: RuleAction(type: .command, command: ["npm", "cache", "clean"]), bytes: 4)
        let plan = CleanPlan(items: [moved, command], selectedIDs: ["move", "command"])
        XCTAssertEqual(plan.estimatedImmediateBytes, 4)
        XCTAssertEqual(plan.recoveryMoveBytes, 9)
        let summary = ConfirmationSummary.make(items: plan.selectedItems, isRunning: { _ in false })
        XCTAssertEqual(summary.immediateBytes, 4)
        XCTAssertEqual(summary.recoveryBytes, 9)
    }
}
