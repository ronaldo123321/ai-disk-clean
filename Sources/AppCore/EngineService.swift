import Foundation
import CleanerCore

public enum EngineServiceError: Error, CustomStringConvertible {
    case rulesUnavailable
    public var description: String {
        switch self {
        case .rulesUnavailable: return "找不到内置规则，应用可能没有完整安装"
        }
    }
}

/// 界面调用引擎的唯一入口。方法都是同步阻塞的，应在后台线程调用；
/// 唯一例外是 `isAppRunning`：只查一下进程列表，开销很小，可在主线程调用。
public protocol EngineServicing: AnyObject {
    var isIsolated: Bool { get }
    var homeDirectory: String { get }
    func scan(onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult
    func scan(options: ScanOptions, onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult
    func isAppRunning(_ bundleID: String) -> Bool
    func quitPhase(_ items: [CleanItem], consentedApps: Set<String>, cancellation: OperationCancellation?,
                   onApp: @escaping (QuitApp) -> Void) -> [QuitApp]
    func forceQuit(_ apps: [QuitApp])
    func run(_ items: [CleanItem], cancellation: OperationCancellation,
             onItemStart: @escaping (Int) -> Void,
             onItemStep: @escaping (Int, String) -> Void,
             onItemFinish: @escaping (Int, ItemRunResult) -> Void) throws -> RunReport
    func recoveryBatches() -> [RecoveryBatch]
    func recoveryOrphans() -> [String]
    func recoveryOccupied(_ batch: RecoveryBatch) -> Int64
    func restore(batchID: String, itemIDs: Set<String>?) -> (restored: [String], errors: [String])
    func purge(batchID: String) -> [String]
    func purgeExpired(now: Date) -> (purged: [String], errors: [String])
    func history() -> [AuditEvent]
    func browseSpace(_ path: String, options: ScanOptions, cancellation: OperationCancellation) throws -> SpaceListing
    func restore(batchID: String, itemIDs: Set<String>?, destinationDirectory: String?) -> (restored: [String], errors: [String])
}

public extension EngineServicing {
    var isIsolated: Bool { false }
    func history() -> [AuditEvent] { [] }
    func browseSpace(_ path: String, options: ScanOptions, cancellation: OperationCancellation) throws -> SpaceListing { throw FileOpError.notFound(path) }
    func restore(batchID: String, itemIDs: Set<String>?, destinationDirectory: String?) -> (restored: [String], errors: [String]) {
        guard destinationDirectory == nil else { return ([], ["不支持另存恢复"]) }
        return restore(batchID: batchID, itemIDs: itemIDs)
    }
    var homeDirectory: String { NSHomeDirectory() }
    func scan(options: ScanOptions, onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult {
        try scan(onStep: onStep, cancellation: cancellation)
    }
}

public final class LiveEngineService: EngineServicing {
    private let files: RealFileOperations
    private let isolated: Bool
    public var isIsolated: Bool { isolated }
    public var homeDirectory: String { home }
    private let home: String
    private let probeRunner = RealProcessRunner(timeout: 30)
    private let commandRunner = RealProcessRunner(timeout: 900, outputLimit: 8 << 20)
    private let apps = RealAppControl()
    private let recovery: RecoveryStore
    private let audit: AuditLog

    public init(homeOverride: String? = nil) {
        files = RealFileOperations(home: homeOverride)
        isolated = homeOverride != nil
        home = files.homeDirectory()
        audit = AuditLog(files: files, path: EnginePaths.auditLog(home: home))
        recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files, audit: audit)
    }

    /// 每次操作用新的 PathSafety：它按实例缓存用户的保护位置。
    private func makeExecutor() -> PlanExecutor {
        PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: probeRunner,
                     commandRunner: commandRunner, apps: apps, recovery: recovery, audit: audit)
    }

    public func scan(onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult {
        try scan(options: ScanOptions(), onStep: onStep, cancellation: cancellation)
    }

    public func scan(options: ScanOptions, onStep: @escaping (ScanStep) -> Void, cancellation: OperationCancellation) throws -> ScanResult {
        guard let bundled = RulePack.bundledData() else { throw EngineServiceError.rulesUnavailable }
        let safety = PathSafety(home: home, files: files)
        let loaded = RulePack.load(bundled: bundled, user: files.readFile(atPath: EnginePaths.userRules(home: home)), safety: safety)
        let context = DetectContext(files: files, safety: safety, runner: probeRunner, now: Date(), cancellation: cancellation, options: options)
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: probeRunner), home: home)
        var detectors: [Detector] = [RuleDetector(rules: isolated ? loaded.rules.filter { $0.action.type != .command } : loaded.rules), ProjectArtifactDetector()]
        if !isolated { detectors.append(DockerDetector()) }
        return EngineScanner(context: context, detectors: detectors, spaceMap: SpaceMapDetector(), checker: checker)
            .scan(onStep: onStep)
    }

    public func isAppRunning(_ bundleID: String) -> Bool { apps.isRunning(bundleID: bundleID) }

    public func quitPhase(_ items: [CleanItem], consentedApps: Set<String>, cancellation: OperationCancellation?,
                          onApp: @escaping (QuitApp) -> Void) -> [QuitApp] {
        makeExecutor().quitPhase(items, consentedApps: consentedApps, cancellation: cancellation, onApp: onApp)
    }

    public func forceQuit(_ targets: [QuitApp]) { makeExecutor().forceQuit(targets) }

    public func run(_ items: [CleanItem], cancellation: OperationCancellation,
                    onItemStart: @escaping (Int) -> Void,
                    onItemStep: @escaping (Int, String) -> Void,
                    onItemFinish: @escaping (Int, ItemRunResult) -> Void) throws -> RunReport {
        try makeExecutor().run(items, cancellation: cancellation,
                               onItemStart: { index, _ in onItemStart(index) },
                               onItemStep: onItemStep,
                               onItemFinish: onItemFinish)
    }

    public func recoveryBatches() -> [RecoveryBatch] { recovery.list() }
    public func history() -> [AuditEvent] { audit.readAll().reversed() }
    public func browseSpace(_ path: String, options: ScanOptions, cancellation: OperationCancellation) throws -> SpaceListing {
        try SpaceBrowser(files: files).list(path, options: options, cancellation: cancellation)
    }
    public func restore(batchID: String, itemIDs: Set<String>?, destinationDirectory: String?) -> (restored: [String], errors: [String]) {
        recovery.restore(batchID: batchID, itemIDs: itemIDs, destinationDirectory: destinationDirectory)
    }
    public func recoveryOrphans() -> [String] { recovery.orphanBatches() }
    public func recoveryOccupied(_ batch: RecoveryBatch) -> Int64 { recovery.occupiedBytes(of: batch) }
    public func restore(batchID: String, itemIDs: Set<String>?) -> (restored: [String], errors: [String]) {
        recovery.restore(batchID: batchID, itemIDs: itemIDs)
    }
    public func purge(batchID: String) -> [String] { recovery.purge(batchID: batchID) }
    public func purgeExpired(now: Date) -> (purged: [String], errors: [String]) {
        recovery.purge(olderThanDays: RecoveryStore.retentionDays, now: now)
    }
}
