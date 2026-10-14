import Foundation
import Combine
import CleanerCore

/// 界面唯一的状态。约定：所有 @Published 属性只在主线程修改（经 main 回调）；引擎调用经 background 在后台执行。
public final class AppModel: ObservableObject {
    public enum Phase: Equatable {
        case idle, scanning, ready, confirming, executing, finished
    }

    public struct ExecutionProgress: Equatable {
        public var total = 0
        public var finished: [ItemRunResult] = []
        public var currentTitle: String?
        /// 正在处理的项在本次运行中的下标
        public var currentIndex: Int?
        /// 子步骤说明：退出应用阶段为「正在退出 <应用名>…」，执行中为该项的「正在暂停 <服务名>…」等
        public var currentStep: String?
        public var stopping = false
    }

    /// 扫描结果超过这个时间就先重新扫描再弹确认单
    public static let staleAfter: TimeInterval = 600

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var scanStep: ScanStep?
    @Published public private(set) var scanResult: ScanResult?
    @Published public private(set) var selectedIDs: Set<String> = []
    @Published public private(set) var confirmation: ConfirmationSummary?
    @Published public private(set) var progress = ExecutionProgress()
    @Published public private(set) var stuckApps: [QuitApp] = []
    /// 用户对每个未退出应用的选择（bundleID → 是否强制退出）；全部选完才继续
    @Published public private(set) var stuckDecisions: [String: Bool] = [:]
    @Published public private(set) var report: RunReport?
    @Published public private(set) var recovery = RecoveryOverview.empty
    /// 还原或永久清空进行中：期间忽略其他恢复区操作，也不开始扫描或清理
    @Published public private(set) var recoveryBusy = false
    @Published public private(set) var message: String?
    @Published public private(set) var scanPreview: [CleanItem] = []
    @Published public private(set) var scanOptions: ScanOptions
    @Published public private(set) var history: [AuditEvent] = []
    @Published public private(set) var spaceListing: SpaceListing?
    @Published public private(set) var spaceBusy = false
    @Published public private(set) var spaceError: String?
    private var spaceCancellation: OperationCancellation?
    private let preferences: UserDefaults?

    private let engine: EngineServicing
    private let now: () -> Date
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    private var scanCancellation: OperationCancellation?
    private var runCancellation: OperationCancellation?
    private var confirmAfterScan = false
    /// 过期重扫后要沿用的用户手动勾选（nil 表示用默认方案）
    private var selectionAfterScan: Set<String>?
    private var runningItems: [CleanItem] = []
    /// 清理完成后置位：清理前的扫描结果不能再拿来确认或执行，直到一次未取消的扫描完成
    @Published public private(set) var rescanReason: String?
    private var needsRescan: Bool { rescanReason != nil }

    public init(engine: EngineServicing,
                now: @escaping () -> Date = { Date() },
                preferences: UserDefaults? = nil,
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
                main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.engine = engine
        self.now = now
        self.background = background
        self.main = main
        self.preferences = preferences
        self.scanOptions = preferences?.data(forKey: "scanOptions.v1")
            .flatMap { try? JSONDecoder().decode(ScanOptions.self, from: $0) } ?? ScanOptions()
    }

    public var plan: CleanPlan? { scanResult.map { CleanPlan(items: $0.items, selectedIDs: selectedIDs) } }
    public var defaultPlan: CleanPlan? {
        scanResult.map { result in
            var plan = PlanBuilder.build(from: result)
            plan.selectedIDs = Set(plan.selectedItems.filter { !isKept($0) }.map(\.id))
            return plan
        }
    }
    public var requiresRescan: Bool { needsRescan }
    public func selectionUnavailableReason(_ item: CleanItem) -> String? {
        if needsRescan { return "需重新扫描后才能勾选 · 见上方原因" }
        if phase != .ready { return "当前操作尚未完成，请等待完成后再选择" }
        if isKept(item) { return "已长期保留 · 请到「扫描范围」移除保留设置" }
        if !item.isSelectable {
            if let blocker = item.blockers.first { return "无法验证或受保护：\(blocker.message) · 请查看右侧详情" }
            return "仅展示占用，不提供清理 · 请查看右侧说明"
        }
        return nil
    }
    public var canEditScope: Bool { ![.scanning, .executing, .confirming].contains(phase) && !recoveryBusy }

    public func isKept(_ item: CleanItem) -> Bool {
        item.paths.contains { path in scanOptions.keptPaths.contains { PathSafety.isInside(path, root: $0) || PathSafety.isInside($0, root: path) } }
    }

    public func setScanOptions(_ options: ScanOptions) {
        guard canEditScope else { return }
        guard !scanOptions.hasSameScope(as: options, home: homeDirectory) else { return }
        scanOptions = options
        if let data = try? JSONEncoder().encode(options) { preferences?.set(data, forKey: "scanOptions.v1") }
        rescanReason = "扫描范围或保留设置已更改，当前列表仍是更改前的结果。请重新扫描后再勾选。"
        selectedIDs = []
        confirmation = nil
    }

    public func keep(_ item: CleanItem) {
        guard canEditScope else { return }
        var options = scanOptions
        options.keptPaths = Array(Set(options.keptPaths + item.paths)).sorted()
        scanOptions = options
        if let data = try? JSONEncoder().encode(options) { preferences?.set(data, forKey: "scanOptions.v1") }
        selectedIDs.subtract(Set((scanResult?.items ?? []).filter { isKept($0) }.map(\.id)))
    }

    public func select(_ ids: Set<String>, selected: Bool) {
        guard phase == .ready, !needsRescan else { return }
        let allowed = Set((scanResult?.items ?? []).filter { ids.contains($0.id) && $0.isSelectable && !isKept($0) }.map(\.id))
        if selected { selectedIDs.formUnion(allowed) } else { selectedIDs.subtract(ids) }
    }
    public var isStale: Bool {
        guard let scanResult, !needsRescan else { return true }
        return now().timeIntervalSince(scanResult.generatedAt) > Self.staleAfter
    }
    /// 执行中不能退出：可能正停着用户的服务、还没写 run.finish 审计
    public var canTerminate: Bool { phase != .executing }
    /// 执行页：本次运行的每一项及其状态
    public var executionRows: [ExecutionRow] { ExecutionRow.make(items: runningItems, progress: progress) }
    /// 本次运行中需要退出该应用的项数（不强制退出它时这些项会被跳过）
    public func affectedItemCount(for app: QuitApp) -> Int {
        runningItems.filter { ($0.preconditions.quitApps ?? []).contains { $0.bundleID == app.bundleID } }.count
    }
    public var resultSummary: ResultSummary? {
        report.map { report in
            ResultSummary(report: report, commandItemIDs: Set(runningItems.filter { $0.action.type == .command }.map(\.id)))
        }
    }

    public func clearMessage() { message = nil }
    public var homeDirectory: String { engine.homeDirectory }
    public var isIsolated: Bool { engine.isIsolated }

    // MARK: 扫描

    public func startScan() {
        guard phase != .scanning, phase != .executing, phase != .confirming, !recoveryBusy else { return }
        // 结果页上的「重新扫描」：和「完成」一样先清掉上一次运行的状态
        if phase == .finished {
            report = nil
            runCancellation = nil
        }
        let cancellation = OperationCancellation()
        scanCancellation = cancellation
        phase = .scanning
        scanStep = nil
        scanPreview = []
        let options = scanOptions
        background { [engine] in
            do {
                let result = try engine.scan(options: options, onStep: { step in self.main {
                    guard self.phase == .scanning else { return }
                    if case .preview(let items) = step { self.scanPreview = items } else { self.scanStep = step }
                } }, cancellation: cancellation)
                self.main { self.finishScan(result) }
            } catch {
                self.main { self.failScan(error) }
            }
        }
    }

    public func cancelScan() { scanCancellation?.cancel() }

    private func finishScan(_ result: ScanResult) {
        scanCancellation = nil
        scanStep = nil
        if result.cancelled {
            rescanReason = "本次扫描已取消，当前列表保留上次结果，暂不能勾选。请重新扫描并等待完成。"
            selectedIDs = []
            message = "扫描已取消。部分结果不能执行，请重新扫描。"
            confirmAfterScan = false
            selectionAfterScan = nil
            phase = scanResult == nil ? .idle : .ready
            return
        }
        scanResult = result
        rescanReason = nil
        selectedIDs = defaultPlan?.selectedIDs ?? []
        if let kept = selectionAfterScan {
            selectionAfterScan = nil
            selectedIDs = Set(result.items.filter { $0.isSelectable && !isKept($0) && kept.contains($0.id) }.map(\.id))
        }
        phase = .ready
        if confirmAfterScan {
            confirmAfterScan = false
            presentConfirmation()
        }
    }

    private func failScan(_ error: Error) {
        scanCancellation = nil
        scanStep = nil
        confirmAfterScan = false
        selectionAfterScan = nil
        message = String(describing: error)
        rescanReason = "本次扫描未成功，当前列表保留上次结果。请查看错误后重新扫描：\(error)"
        selectedIDs = []
        phase = scanResult == nil ? .idle : .ready
    }

    // MARK: 方案与确认

    public func toggle(_ id: String) {
        guard phase == .ready, !needsRescan, let item = scanResult?.items.first(where: { $0.id == id }), item.isSelectable, !isKept(item) else { return }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    public func requestClean(useDefaultSelection: Bool) {
        guard phase == .ready || phase == .idle || phase == .finished, !recoveryBusy else { return }
        // 刚清理完的扫描结果已经过时，同样先重扫
        if isStale || phase == .finished {
            confirmAfterScan = true
            selectionAfterScan = useDefaultSelection || scanResult == nil ? nil : selectedIDs
            if phase == .finished {
                report = nil
                runCancellation = nil
                phase = .ready
            }
            startScan()
            return
        }
        if useDefaultSelection, let defaultPlan { selectedIDs = defaultPlan.selectedIDs }
        presentConfirmation()
    }

    private func presentConfirmation() {
        guard let plan, plan.selectedItems.contains(where: { $0.tier != .displayOnly && $0.action.type != .noAction }) else {
            message = "没有选中可执行的清理项"
            return
        }
        confirmation = ConfirmationSummary.make(items: plan.selectedItems, isRunning: engine.isAppRunning)
        phase = .confirming
    }

    public func cancelConfirmation() {
        guard phase == .confirming else { return }
        confirmation = nil
        phase = .ready
    }

    // MARK: 执行

    public func startClean(consentedApps: Set<String>) {
        guard phase == .confirming, let confirmation else { return }
        let items = confirmation.items
        runningItems = items
        self.confirmation = nil
        report = nil
        progress = ExecutionProgress(total: items.count)
        let cancellation = OperationCancellation()
        runCancellation = cancellation
        phase = .executing
        stuckDecisions = [:]
        background { [engine] in
            let stuck = engine.quitPhase(items, consentedApps: consentedApps, cancellation: cancellation,
                                         onApp: { app in self.main { self.progress.currentStep = "正在退出 \(app.name)…" } })
            self.main { self.progress.currentStep = nil }
            // 已按停止：不再询问，直接让执行器把各项记为已停止
            if stuck.isEmpty || cancellation.isCancelled {
                self.runItems(items, cancellation: cancellation)
            } else {
                self.main {
                    self.stuckApps = stuck
                    // 检查之后、面板出现之前按了停止：不再询问，全部不强制退出
                    if cancellation.isCancelled { self.resolveStuckApps(forceQuit: []) }
                }
            }
        }
    }

    /// 执行页上对单个未退出应用的选择；每个应用都选过之后按 resolveStuckApps 继续。
    public func decideStuckApp(_ bundleID: String, forceQuit: Bool) {
        // 已按停止：不再接受任何选择（停止时已按全部不强制退出继续）
        guard phase == .executing, !progress.stopping, stuckApps.contains(where: { $0.bundleID == bundleID }) else { return }
        stuckDecisions[bundleID] = forceQuit
        guard stuckApps.allSatisfy({ stuckDecisions[$0.bundleID] != nil }) else { return }
        resolveStuckApps(forceQuit: Set(stuckDecisions.filter(\.value).keys))
    }

    /// 用户对超时未退出的应用逐个做了选择：勾选的强制退出，其余跳过相关项。
    public func resolveStuckApps(forceQuit: Set<String>) {
        guard phase == .executing, !stuckApps.isEmpty, let cancellation = runCancellation else { return }
        let targets = stuckApps.filter { forceQuit.contains($0.bundleID) }
        stuckApps = []
        stuckDecisions = [:]
        let items = runningItems
        background { [engine] in
            if !targets.isEmpty { engine.forceQuit(targets) }
            self.runItems(items, cancellation: cancellation)
        }
    }

    /// 在后台线程调用
    private func runItems(_ items: [CleanItem], cancellation: OperationCancellation) {
        do {
            let report = try engine.run(items, cancellation: cancellation,
                                        onItemStart: { index in
                                            self.main {
                                                self.progress.currentTitle = items[index].title
                                                self.progress.currentIndex = index
                                                self.progress.currentStep = nil
                                            }
                                        },
                                        onItemStep: { _, step in self.main { self.progress.currentStep = step } },
                                        onItemFinish: { _, result in
                                            self.main {
                                                self.progress.finished.append(result)
                                                self.progress.currentIndex = nil
                                                self.progress.currentStep = nil
                                            }
                                        })
            main {
                self.report = report
                self.progress.currentTitle = nil
                self.rescanReason = "清理已改变文件状态，当前列表是清理前的结果。请重新扫描后再选择。"
                self.phase = .finished
                self.refreshRecovery()
            }
        } catch {
            main {
                self.message = String(describing: error)
                self.progress.currentTitle = nil
                self.progress.stopping = false
                self.runCancellation = nil
                self.phase = .ready
            }
        }
    }

    public func stopClean() {
        guard phase == .executing else { return }
        runCancellation?.cancel()
        progress.stopping = true
        // 正等用户决定是否强制退出：不再等，全部不强制退出，各项记为已停止
        if !stuckApps.isEmpty { resolveStuckApps(forceQuit: []) }
    }

    /// 结果页点「完成」：回到方案页并重新扫描。恢复区操作进行中时不处理（否则扫描会被忽略，停在过时的方案页）
    public func finish() {
        guard phase == .finished, !recoveryBusy else { return }
        report = nil
        runCancellation = nil
        phase = .ready
        startScan()
    }

    // MARK: 恢复区

    public func browseSpace(_ path: String) {
        guard canEditScope else { return }
        spaceCancellation?.cancel()
        let cancellation = OperationCancellation()
        spaceCancellation = cancellation
        spaceBusy = true
        spaceError = nil
        let options = scanOptions
        background { [engine] in
            do {
                let listing = try engine.browseSpace(path, options: options, cancellation: cancellation)
                self.main {
                    guard self.spaceCancellation === cancellation else { return }
                    self.spaceListing = listing
                    self.spaceBusy = false
                }
            } catch {
                self.main {
                    guard self.spaceCancellation === cancellation else { return }
                    self.spaceError = String(describing: error)
                    self.spaceBusy = false
                }
            }
        }
    }
    public func cancelSpaceBrowse() {
        spaceCancellation?.cancel()
        spaceCancellation = nil
        spaceBusy = false
    }

    public func refreshRecovery() {
        background { [engine, now] in
            let overview = RecoveryOverview.make(batches: engine.recoveryBatches(), orphans: engine.recoveryOrphans(),
                                                 occupied: engine.recoveryOccupied, now: now())
            let history = engine.history()
            self.main { self.recovery = overview; self.history = history }
        }
    }

    public func restore(batchID: String, itemIDs: Set<String>?, destinationDirectory: String? = nil) {
        guard phase != .executing, phase != .scanning, !recoveryBusy else { return }
        recoveryBusy = true
        background { [engine] in
            let result = engine.restore(batchID: batchID, itemIDs: itemIDs, destinationDirectory: destinationDirectory)
            self.main {
                self.recoveryBusy = false
                if !result.restored.isEmpty {
                    self.rescanReason = "文件已恢复，当前列表尚未更新。请重新扫描后再选择。"
                    self.selectedIDs = []
                }
                self.message = result.errors.isEmpty
                    ? "已还原 \(result.restored.count) 个位置"
                    : "部分未能还原：\n" + result.errors.joined(separator: "\n")
                self.refreshRecovery()
            }
        }
    }

    public func purge(batchID: String) {
        guard phase != .executing, phase != .scanning, !recoveryBusy else { return }
        recoveryBusy = true
        background { [engine] in
            let errors = engine.purge(batchID: batchID)
            self.main {
                self.recoveryBusy = false
                if !errors.isEmpty { self.message = errors.joined(separator: "\n") }
                self.refreshRecovery()
            }
        }
    }

    public func purgeExpired() {
        guard phase != .executing, phase != .scanning, !recoveryBusy else { return }
        recoveryBusy = true
        background { [engine, now] in
            let result = engine.purgeExpired(now: now())
            self.main {
                self.recoveryBusy = false
                if !result.errors.isEmpty { self.message = result.errors.joined(separator: "\n") }
                self.refreshRecovery()
            }
        }
    }
}
