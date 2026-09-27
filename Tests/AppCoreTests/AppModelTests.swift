import XCTest
import Combine
import CleanerCore
@testable import AppCore

final class AppModelTests: XCTestCase {
    var engine: FakeEngineService!
    var clock: Date!

    override func setUp() {
        engine = FakeEngineService()
        clock = FakeEngineService.scannedAt.addingTimeInterval(60)
    }

    func model() -> AppModel {
        AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { $0() }, main: { $0() })
    }

    func withItems(_ items: [CleanItem]) {
        engine.scanResult = ScanResult(generatedAt: FakeEngineService.scannedAt, disk: DiskSummary(totalBytes: 100, freeBytes: 40), items: items)
    }

    func testScanSelectsDefaultPlan() {
        withItems([makeItem("safe"), makeItem("confirm", tier: .confirm)])
        let m = model()
        m.startScan()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.selectedIDs, ["safe"])
    }

    func testScanErrorShowsMessage() {
        engine.scanError = EngineServiceError.rulesUnavailable
        let m = model()
        m.startScan()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.message, EngineServiceError.rulesUnavailable.description)
    }

    func testCancelledScanIsDiscarded() {
        withItems([makeItem("safe")])
        engine.cancelDuringScan = true
        let m = model()
        m.startScan()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.scanResult)
    }

    func testToggleIgnoresDisplayOnly() {
        withItems([makeItem("safe"), makeItem("show", tier: .displayOnly)])
        let m = model()
        m.startScan()
        m.toggle("show")
        m.toggle("safe")
        XCTAssertEqual(m.selectedIDs, [])
    }

    func testRequestCleanWhenFreshShowsConfirmation() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        withItems([makeItem("c", quitApps: [chrome])])
        engine.running = [chrome.bundleID]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        XCTAssertEqual(m.phase, .confirming)
        XCTAssertEqual(m.confirmation?.appsWeCanQuit, [chrome])
        XCTAssertEqual(engine.scanCount, 1)
    }

    func testRequestCleanWhenStaleRescansFirst() {
        withItems([makeItem("safe")])
        let m = model()
        m.startScan()
        clock = FakeEngineService.scannedAt.addingTimeInterval(AppModel.staleAfter + 1)
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertEqual(m.phase, .confirming)
    }

    func testStaleRescanKeepsManualSelection() {
        withItems([makeItem("a"), makeItem("b"), makeItem("c", tier: .confirm)])
        let m = model()
        m.startScan()
        m.toggle("a")
        m.toggle("c")
        clock = FakeEngineService.scannedAt.addingTimeInterval(AppModel.staleAfter + 1)
        m.requestClean(useDefaultSelection: false)
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertEqual(m.selectedIDs, ["b", "c"])
        XCTAssertEqual(m.confirmation?.items.map(\.id), ["b", "c"])
    }

    func testRepeatedStuckDecisionRunsOnce() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        var pending: [() -> Void] = []
        func drain() { while !pending.isEmpty { pending.removeFirst()() } }
        let m = AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { pending.append($0) }, main: { $0() })
        m.startScan(); drain()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: []); drain()
        m.resolveStuckApps(forceQuit: [])
        m.resolveStuckApps(forceQuit: [])  // 第一次选择后执行尚未开始时的重复点击
        drain()
        XCTAssertEqual(engine.ranItems.count, 1)
        XCTAssertEqual(m.phase, .finished)
    }

    func testEmptySelectionDoesNotConfirm() {
        withItems([makeItem("confirm", tier: .confirm)])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.message, "没有选中可执行的清理项")
    }

    func testStartCleanRunsAndFinishes() {
        withItems([makeItem("a"), makeItem("b")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: ["com.google.Chrome"])
        XCTAssertEqual(engine.quitCalls, [["com.google.Chrome"]])
        XCTAssertEqual(engine.ranItems.first?.map(\.id), ["a", "b"])
        XCTAssertEqual(m.phase, .finished)
        XCTAssertEqual(m.progress.finished.count, 2)
        XCTAssertEqual(m.report?.batchID, "run-fake")
    }

    func testStuckAppsWaitForDecisionThenForceOnlyChosen() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let edge = QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")
        withItems([makeItem("a")])
        engine.stuck = [chrome, edge]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .executing)
        XCTAssertEqual(m.stuckApps, [chrome, edge])
        XCTAssertTrue(engine.ranItems.isEmpty)
        m.resolveStuckApps(forceQuit: [chrome.bundleID])
        XCTAssertEqual(engine.forced, [[chrome]])
        XCTAssertEqual(m.phase, .finished)
    }

    func testStopBeforeRunSkipsEverything() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        m.stopClean()
        XCTAssertTrue(m.progress.stopping)
        m.resolveStuckApps(forceQuit: [])
        XCTAssertEqual(m.report?.results.map(\.reason), [.cancelled])
    }

    func testStopWhileStuckAppsPendingFinishesWithoutForceQuit() {
        withItems([makeItem("a"), makeItem("b")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertFalse(m.stuckApps.isEmpty)
        m.stopClean()
        XCTAssertTrue(engine.forced.isEmpty)
        XCTAssertTrue(m.stuckApps.isEmpty)
        XCTAssertEqual(m.phase, .finished)
        XCTAssertEqual(m.report?.results.map(\.reason), [.cancelled, .cancelled])
    }

    func testStopDuringQuitPhaseSkipsStuckDialog() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        var published: [[QuitApp]] = []
        let sub = m.$stuckApps.dropFirst().sink { published.append($0) }
        engine.duringQuitPhase = { m.stopClean() }
        m.startClean(consentedApps: [])
        sub.cancel()
        XCTAssertTrue(published.allSatisfy(\.isEmpty))
        XCTAssertEqual(engine.ranItems.count, 1)
        XCTAssertEqual(m.phase, .finished)
        XCTAssertEqual(m.report?.results.map(\.reason), [.cancelled])
    }

    func testCannotTerminateWhileExecuting() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        let m = model()
        XCTAssertTrue(m.canTerminate)
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .executing)
        XCTAssertFalse(m.canTerminate)
        m.resolveStuckApps(forceQuit: [])
        XCTAssertEqual(m.phase, .finished)
        XCTAssertTrue(m.canTerminate)
    }

    func testStopDuringQuitPhaseCancelsQuitPhase() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        var cancelledBeforeStop: Bool?
        engine.duringQuitPhase = { [unowned self] in
            cancelledBeforeStop = self.engine.quitCancellations.last??.isCancelled
            m.stopClean()
        }
        m.startClean(consentedApps: [])
        XCTAssertEqual(cancelledBeforeStop, false)
        XCTAssertEqual(engine.quitCancellations.count, 1)
        XCTAssertEqual(engine.quitCancellations.first??.isCancelled, true)  // 就是本次运行的 cancellation，停止后已取消
    }

    func testExecutionShowsEveryItemAndSubSteps() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        withItems([makeItem("a"), makeItem("b"), makeItem("c")])
        engine.quitting = [chrome]
        engine.itemSteps = ["b": "正在暂停 记忆服务…"]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        var duringQuit: (String?, [ExecutionRow.Status])?
        engine.duringQuitPhase = { duringQuit = (m.progress.currentStep, m.executionRows.map(\.status)) }
        var duringB: [ExecutionRow.Status] = []
        engine.duringItem = { index in if index == 1 { duringB = m.executionRows.map(\.status) } }
        m.startClean(consentedApps: [chrome.bundleID])
        XCTAssertEqual(duringQuit?.0, "正在退出 Chrome…")
        XCTAssertEqual(duringQuit?.1, [.waiting, .waiting, .waiting])
        XCTAssertEqual(duringB, [.done, .running(step: "正在暂停 记忆服务…"), .waiting])
        XCTAssertEqual(m.executionRows.map(\.status), [.done, .done, .done])
        XCTAssertNil(m.progress.currentStep)
    }

    func testStuckAppsDecidedOneByOne() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let edge = QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")
        withItems([makeItem("a", quitApps: [chrome]), makeItem("b", quitApps: [chrome, edge]), makeItem("c")])
        engine.stuck = [chrome, edge]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [chrome.bundleID, edge.bundleID])
        XCTAssertEqual(m.affectedItemCount(for: chrome), 2)
        XCTAssertEqual(m.affectedItemCount(for: edge), 1)
        m.decideStuckApp(chrome.bundleID, forceQuit: true)
        m.decideStuckApp("com.example.unknown", forceQuit: true)
        XCTAssertEqual(m.stuckDecisions, [chrome.bundleID: true])
        XCTAssertEqual(m.stuckApps, [chrome, edge])
        XCTAssertTrue(engine.ranItems.isEmpty)
        m.decideStuckApp(edge.bundleID, forceQuit: false)
        XCTAssertEqual(engine.forced, [[chrome]])
        XCTAssertEqual(engine.ranItems.count, 1)
        XCTAssertTrue(m.stuckDecisions.isEmpty)
        XCTAssertEqual(m.phase, .finished)
    }

    func testStopAfterQuitPhaseCheckButBeforeStuckPanelNeverForceQuits() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        var mainPending: [() -> Void] = []
        func drain() { while !mainPending.isEmpty { mainPending.removeFirst()() } }
        let m = AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { $0() }, main: { mainPending.append($0) })
        m.startScan(); drain()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])  // 后台已检查过 cancellation，显示面板的主线程回调尚未执行
        m.stopClean()
        drain()
        XCTAssertTrue(m.stuckApps.isEmpty)
        XCTAssertTrue(engine.forced.isEmpty)
        XCTAssertEqual(m.phase, .finished)
        XCTAssertEqual(m.report?.results.map(\.reason), [.cancelled])
    }

    func testStopAfterPartialStuckDecisionNeverForceQuits() {
        let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
        let edge = QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")
        withItems([makeItem("a", quitApps: [chrome]), makeItem("b", quitApps: [edge])])
        engine.stuck = [chrome, edge]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [chrome.bundleID, edge.bundleID])
        m.decideStuckApp(chrome.bundleID, forceQuit: true)
        m.stopClean()
        m.decideStuckApp(edge.bundleID, forceQuit: true)
        XCTAssertTrue(engine.forced.isEmpty)
        XCTAssertTrue(m.stuckDecisions.isEmpty)
        XCTAssertEqual(m.phase, .finished)
    }

    func testRunErrorReturnsToReadyWithMessage() {
        withItems([makeItem("a")])
        engine.runError = ExecutorRunError.busy("locked")
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.message, ExecutorRunError.busy("locked").description)
    }

    func testFinishRescans() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        m.finish()
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNil(m.report)
    }

    func testRequestCleanAfterFinishRescansFirst() {
        withItems([makeItem("a"), makeItem("b")])
        let m = model()
        m.startScan()
        m.toggle("a")
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .finished)
        m.requestClean(useDefaultSelection: false)
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertNil(m.report)
        XCTAssertEqual(m.phase, .confirming)
        XCTAssertEqual(m.confirmation?.items.map(\.id), ["b"])
    }

    func testCancelledRescanAfterFinishNeverReusesOldResult() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        engine.cancelDuringScan = true
        m.finish()
        XCTAssertEqual(m.phase, .ready)
        engine.cancelDuringScan = false
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(engine.scanCount, 3)  // 先重新扫描，而不是拿清理前的结果弹确认单
        XCTAssertEqual(m.phase, .confirming)
    }

    func testFailedRescanAfterFinishNeverReusesOldResult() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        engine.scanError = EngineServiceError.rulesUnavailable
        m.finish()
        XCTAssertEqual(m.phase, .ready)
        engine.scanError = nil
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(engine.scanCount, 3)
        XCTAssertEqual(m.phase, .confirming)
    }

    func testCancelledRescanFromResultPageNeverReusesOldResult() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .finished)
        engine.cancelDuringScan = true
        m.startScan()  // 结果页上的「重新扫描」
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNil(m.report)
        engine.cancelDuringScan = false
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(engine.scanCount, 3)
    }

    func testCancelledStaleRescanNeverConfirmsLater() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        clock = FakeEngineService.scannedAt.addingTimeInterval(AppModel.staleAfter + 1)
        engine.cancelDuringScan = true
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(m.phase, .ready)
        engine.cancelDuringScan = false
        m.startScan()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNil(m.confirmation)
    }

    func testScanErrorWithPreviousResultReturnsToReady() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        engine.scanError = EngineServiceError.rulesUnavailable
        m.startScan()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNotNil(m.scanResult)
        XCTAssertEqual(m.message, EngineServiceError.rulesUnavailable.description)
    }

    func testCommandlessSelectionDoesNotConfirm() {
        withItems([makeItem("n", action: .noAction)])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.message, "没有选中可执行的清理项")
    }

    func testRecoveryActionsIgnoredWhileExecuting() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        XCTAssertEqual(m.phase, .executing)
        m.restore(batchID: "b1", itemIDs: nil)
        m.purge(batchID: "b1")
        m.purgeExpired()
        XCTAssertTrue(engine.restoreCalls.isEmpty)
        XCTAssertTrue(engine.purgeCalls.isEmpty)
        XCTAssertEqual(engine.purgeExpiredCalls, 0)
    }

    func testRecoveryActionsIgnoredWhileScanning() {
        var pending: [() -> Void] = []
        let m = AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { pending.append($0) }, main: { $0() })
        m.startScan()
        XCTAssertEqual(m.phase, .scanning)
        m.restore(batchID: "b1", itemIDs: nil)
        m.purge(batchID: "b1")
        m.purgeExpired()
        XCTAssertEqual(pending.count, 1)  // 只有扫描本身
    }

    func testRunErrorResetsStopState() {
        withItems([makeItem("a")])
        engine.stuck = [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")]
        engine.runError = ExecutorRunError.busy("locked")
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        m.stopClean()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertFalse(m.progress.stopping)
    }

    func testRecoveryActionIgnoresOthersUntilItCompletes() {
        withItems([makeItem("a")])
        var pending: [() -> Void] = []
        func drain() { while !pending.isEmpty { pending.removeFirst()() } }
        let m = AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { pending.append($0) }, main: { $0() })
        m.startScan(); drain()
        m.restore(batchID: "b1", itemIDs: nil)  // 第一次还原尚在后台，未完成
        XCTAssertTrue(m.recoveryBusy)
        m.restore(batchID: "b1", itemIDs: nil)
        m.purge(batchID: "b1")
        m.purgeExpired()
        m.startScan()
        m.requestClean(useDefaultSelection: true)
        XCTAssertEqual(m.phase, .ready)
        drain()
        XCTAssertFalse(m.recoveryBusy)
        XCTAssertEqual(engine.restoreCalls.count, 1)
        XCTAssertTrue(engine.purgeCalls.isEmpty)
        XCTAssertEqual(engine.purgeExpiredCalls, 0)
        XCTAssertEqual(engine.scanCount, 1)
        m.purge(batchID: "b1"); drain()
        XCTAssertEqual(engine.purgeCalls, ["b1"])
    }

    func testFinishWaitsForRecoveryActionThenRescans() {
        withItems([makeItem("a")])
        var pending: [() -> Void] = []
        func drain() { while !pending.isEmpty { pending.removeFirst()() } }
        let m = AppModel(engine: engine, now: { [unowned self] in self.clock }, background: { pending.append($0) }, main: { $0() })
        m.startScan(); drain()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: []); drain()
        XCTAssertEqual(m.phase, .finished)
        m.restore(batchID: "b1", itemIDs: nil)  // 结果页上开始还原，尚未完成
        m.finish()
        XCTAssertEqual(m.phase, .finished)
        XCTAssertNotNil(m.report)
        drain()
        XCTAssertEqual(engine.scanCount, 1)  // 还原完成不自动扫描：仍停在结果页
        m.finish(); drain()
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertEqual(m.phase, .ready)
    }

    func testRecoveryActionDoesNotRestartCancelledRescan() {
        withItems([makeItem("a")])
        let m = model()
        m.startScan()
        m.requestClean(useDefaultSelection: false)
        m.startClean(consentedApps: [])
        engine.cancelDuringScan = true
        m.finish()  // 用户取消了重新扫描
        engine.cancelDuringScan = false
        m.restore(batchID: "b1", itemIDs: nil)
        XCTAssertEqual(engine.scanCount, 2)
        XCTAssertEqual(m.phase, .ready)
    }

    func testRecoveryActionsCallEngineAndRefresh() {
        engine.batches = [RecoveryBatch(id: "b1", createdAt: FakeEngineService.scannedAt, entries: [
            RecoveryEntry(originalPath: "/Users/t/x", storedPath: "/r/x", bytes: 5, state: .stored, identity: nil,
                          contentDigest: nil, itemID: "i", itemTitle: "X")])]
        let m = model()
        m.refreshRecovery()
        XCTAssertEqual(m.recovery.totalBytes, 5)
        m.restore(batchID: "b1", itemIDs: ["i"])
        XCTAssertEqual(engine.restoreCalls.first?.itemIDs, ["i"])
        m.purge(batchID: "b1")
        XCTAssertEqual(engine.purgeCalls, ["b1"])
        m.purgeExpired()
        XCTAssertEqual(engine.purgeExpiredCalls, 1)
    }
}
