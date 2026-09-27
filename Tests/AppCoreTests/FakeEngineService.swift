import Foundation
import CleanerCore
@testable import AppCore

final class FakeEngineService: EngineServicing {
    static let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var scanResult = ScanResult(generatedAt: FakeEngineService.scannedAt, disk: DiskSummary(totalBytes: 100, freeBytes: 40), items: [])
    var scanError: Error?
    var cancelDuringScan = false
    private(set) var scanCount = 0
    var running: Set<String> = []
    var stuck: [QuitApp] = []
    /// quitPhase 里逐个经 onApp 报告「正在退出」的应用
    var quitting: [QuitApp] = []
    /// 在 quitPhase 内部调用，用来模拟退出应用期间用户的操作
    var duringQuitPhase: (() -> Void)?
    private(set) var quitCalls: [Set<String>] = []
    private(set) var quitCancellations: [OperationCancellation?] = []
    private(set) var forced: [[QuitApp]] = []
    private(set) var ranItems: [[CleanItem]] = []
    var runError: Error?
    /// run 里某项开始后经 onItemStep 报告的子步骤（按 itemID）
    var itemSteps: [String: String] = [:]
    /// 在 run 里每项开始（并报告子步骤）之后、结束之前调用
    var duringItem: ((Int) -> Void)?
    var batches: [RecoveryBatch] = []
    var orphans: [String] = []
    private(set) var restoreCalls: [(batchID: String, itemIDs: Set<String>?)] = []
    private(set) var purgeCalls: [String] = []
    private(set) var purgeExpiredCalls = 0

    func scan(onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult {
        scanCount += 1
        onStep(.detecting("规则"))
        if cancelDuringScan { cancellation.cancel() }
        if let scanError { throw scanError }
        var result = scanResult
        result.cancelled = cancellation.isCancelled
        return result
    }

    func isAppRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }

    func quitPhase(_ items: [CleanItem], consentedApps: Set<String>, cancellation: OperationCancellation?,
                   onApp: @escaping (QuitApp) -> Void) -> [QuitApp] {
        quitCalls.append(consentedApps)
        quitCancellations.append(cancellation)
        quitting.forEach(onApp)
        duringQuitPhase?()
        return stuck
    }

    func forceQuit(_ apps: [QuitApp]) { forced.append(apps) }

    func run(_ items: [CleanItem], cancellation: OperationCancellation,
             onItemStart: @escaping (Int) -> Void,
             onItemStep: @escaping (Int, String) -> Void,
             onItemFinish: @escaping (Int, ItemRunResult) -> Void) throws -> RunReport {
        if let runError { throw runError }
        ranItems.append(items)
        var results: [ItemRunResult] = []
        for (index, item) in items.enumerated() {
            let stopped = cancellation.isCancelled
            if !stopped {
                onItemStart(index)
                if let step = itemSteps[item.id] { onItemStep(index, step) }
                duringItem?(index)
            }
            let result = ItemRunResult(itemID: item.id, title: item.title,
                                       outcome: stopped ? .skipped("已停止，未执行") : .done,
                                       estimatedBytes: item.reclaimableBytes, recoveredBytes: 0,
                                       reason: stopped ? .cancelled : nil)
            results.append(result)
            onItemFinish(index, result)
        }
        return RunReport(batchID: "run-fake", startedAt: FakeEngineService.scannedAt, finishedAt: FakeEngineService.scannedAt,
                         freeBefore: 40, freeAfter: 60, results: results, serviceIssues: [], regrowNotes: [])
    }

    func recoveryBatches() -> [RecoveryBatch] { batches }
    func recoveryOrphans() -> [String] { orphans }
    func recoveryOccupied(_ batch: RecoveryBatch) -> Int64 { batch.entries.reduce(0) { $0 + $1.bytes } }
    func restore(batchID: String, itemIDs: Set<String>?) -> (restored: [String], errors: [String]) {
        restoreCalls.append((batchID, itemIDs))
        return (["/restored"], [])
    }
    func purge(batchID: String) -> [String] {
        purgeCalls.append(batchID)
        return []
    }
    func purgeExpired(now: Date) -> (purged: [String], errors: [String]) {
        purgeExpiredCalls += 1
        return ([], [])
    }
}

/// 测试用清理项
func makeItem(_ id: String, tier: CleanTier = .safe, action: RuleAction = .recover, bytes: Int64 = 1 << 20,
              quitApps: [QuitApp]? = nil, blockers: [Blocker] = []) -> CleanItem {
    var item = CleanItem(id: id, app: id, category: .dev, tier: tier, title: id, paths: ["/Users/t/" + id],
                         action: tier == .displayOnly ? .noAction : action,
                         preconditions: RulePreconditions(quitApps: quitApps),
                         copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    item.apparentBytes = bytes
    item.reclaimableBytes = tier == .displayOnly ? 0 : bytes
    item.blockers = blockers
    return item
}
