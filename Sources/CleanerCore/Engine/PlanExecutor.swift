import Foundation

public struct ExecutionOptions: Sendable {
    /// 用户同意由工具正常退出的应用
    public var quitApps: Set<String>
    /// 正常退出超时后，用户逐个同意强制退出的应用
    public var forceQuitApps: Set<String>
    public var quitTimeout: TimeInterval
    public var serviceWaitTimeout: TimeInterval

    public init(quitApps: Set<String> = [], forceQuitApps: Set<String> = [], quitTimeout: TimeInterval = 10,
                serviceWaitTimeout: TimeInterval = 20) {
        self.quitApps = quitApps
        self.forceQuitApps = forceQuitApps
        self.quitTimeout = quitTimeout
        self.serviceWaitTimeout = serviceWaitTimeout
    }
}

public enum RunOutcome: Codable, Equatable, Sendable {
    case done
    case skipped(String)
    case failed(String)
}

/// 跳过或失败的原因类别，供界面分组展示；完成的项为 nil。
public enum OutcomeReason: String, Codable, Equatable, Sendable, CaseIterable {
    case appRunning, occupied, unavailable, gone, protected, auditFailed, commandFailed, recoveryFailed, cancelled, other

    public var title: String {
        switch self {
        case .appRunning: return "应用仍在运行"
        case .occupied: return "被占用"
        case .unavailable: return "无法确认是否被占用"
        case .gone: return "已不存在或已被修改"
        case .protected: return "位于受保护位置"
        case .auditFailed: return "审计日志无法写入"
        case .commandFailed: return "清理命令失败"
        case .recoveryFailed: return "移入恢复区失败"
        case .cancelled: return "已停止"
        case .other: return "其他"
        }
    }
}

public struct ItemRunResult: Codable, Equatable, Sendable {
    public var itemID: String
    public var title: String
    public var outcome: RunOutcome
    public var estimatedBytes: Int64
    public var recoveredBytes: Int64
    public var reason: OutcomeReason?

    public init(itemID: String, title: String, outcome: RunOutcome, estimatedBytes: Int64, recoveredBytes: Int64,
                reason: OutcomeReason?) {
        self.itemID = itemID
        self.title = title
        self.outcome = outcome
        self.estimatedBytes = estimatedBytes
        self.recoveredBytes = recoveredBytes
        self.reason = reason
    }
}

public struct RunReport: Codable, Equatable, Sendable {
    public var batchID: String
    public var startedAt: Date
    public var finishedAt: Date
    public var freeBefore: Int64?
    public var freeAfter: Int64?
    public var results: [ItemRunResult]
    public var serviceIssues: [String]
    public var regrowNotes: [String]

    public init(batchID: String, startedAt: Date, finishedAt: Date, freeBefore: Int64?, freeAfter: Int64?,
                results: [ItemRunResult], serviceIssues: [String], regrowNotes: [String]) {
        self.batchID = batchID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.freeBefore = freeBefore
        self.freeAfter = freeAfter
        self.results = results
        self.serviceIssues = serviceIssues
        self.regrowNotes = regrowNotes
    }

    /// 按执行前后卷可用空间计算；移入恢复区（同卷 rename）不会增加可用空间。
    public var measuredFreedBytes: Int64? {
        guard let before = freeBefore, let after = freeAfter else { return nil }
        return after - before
    }

    public var recoveryBytes: Int64 { results.reduce(0) { $0 + $1.recoveredBytes } }
}

public enum ExecutorRunError: Error, CustomStringConvertible {
    case busy(String)
    case auditUnavailable(String)
    public var description: String {
        switch self {
        case .busy(let why): return "无法开始清理（可能已有清理任务在运行，或数据目录不可用）：\(why)"
        case .auditUnavailable(let why): return "审计日志无法写入，未执行任何清理：\(why)"
        }
    }
}

public final class PlanExecutor {
    private let files: FileOperations
    private let safety: PathSafety
    private let runner: ProcessRunner
    private let commandRunner: ProcessRunner
    private let apps: AppControl
    private let recovery: RecoveryStore
    private let audit: AuditLog
    private let checker: PreconditionChecker
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    /// - Parameters:
    ///   - runner: 短超时，用于 lsof / pgrep 检查
    ///   - commandRunner: 长超时，用于清理命令
    ///   - now: 等待服务启停用基于 now() 的截止时间，调用 sleep 后 now() 必须随之前进（测试注入时同样要求）
    public init(files: FileOperations, safety: PathSafety, runner: ProcessRunner, commandRunner: ProcessRunner,
                apps: AppControl, recovery: RecoveryStore, audit: AuditLog,
                now: @escaping () -> Date = { Date() },
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.files = files
        self.safety = safety
        self.runner = runner
        self.commandRunner = commandRunner
        self.apps = apps
        self.recovery = recovery
        self.audit = audit
        self.checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: runner),
                                           home: files.homeDirectory())
        self.now = now
        self.sleep = sleep
    }

    /// 只执行本进程刚扫描得到的清理项；不要执行从磁盘或跨进程解码的 CleanItem（命令参数与路径会被原样信任）。
    /// - Parameters:
    ///   - cancellation: 每项开始前检查；停止后剩余项不写 intent、不执行，结果为「已停止，未执行」。
    ///   - onItemStart: 只对真正开始处理的项调用。
    ///   - onItemStep: 某项进入耗时的子步骤时调用（「正在暂停 <服务名>…」→ 暂停成功后「正在清理…」→「正在恢复 <服务名>…」），
    ///     参数是该项下标与说明。
    ///   - onItemFinish: 每一项（含已停止的）得出结果后调用。
    ///
    /// 回调都在调用 run 的线程上同步调用，此时操作锁仍被持有：必须很快返回，不得阻塞等待主线程
    /// （不要用 DispatchQueue.main.sync），也不得重入执行器；界面应异步切回主线程更新。
    public func run(_ items: [CleanItem], options: ExecutionOptions = ExecutionOptions(),
                    cancellation: OperationCancellation? = nil,
                    onItemStart: ((Int, CleanItem) -> Void)? = nil,
                    onItemStep: ((Int, String) -> Void)? = nil,
                    onItemFinish: ((Int, ItemRunResult) -> Void)? = nil) throws -> RunReport {
        // 操作锁故意与 v2 界面（~/.dclean-v2/operation.lock）共用：新旧界面任何写操作都互斥。
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { throw ExecutorRunError.busy(String(describing: error)) }
        defer { withExtendedLifetime(lease) {} }
        let home = files.homeDirectory()
        let started = now()
        let batchID = Self.batchID(started)
        let freeBefore = files.volumeSummary(atPath: home)?.freeBytes
        // 审计先行：run.start 与每项 intent 写不进去就不做任何改动。
        do {
            try audit.appendRequired(AuditEvent(op: "run.start", detail: "\(batchID) \(items.count) 项"))
        } catch {
            throw ExecutorRunError.auditUnavailable(String(describing: error))
        }
        if !options.quitApps.isEmpty { quitApps(for: items.filter(willRun), options: options) }
        var writer: RecoveryBatchWriter?
        var writerError: String?
        var auditFailure: String?
        var results: [ItemRunResult] = []
        var serviceIssues: [String] = []
        var regrowNotes: [String] = []
        for (index, item) in items.enumerated() {
            if cancellation?.isCancelled == true {
                let outcome = RunOutcome.skipped("已停止，未执行")
                audit.append(AuditEvent(op: "run.item.result", detail: "\(item.id) \(outcome)", bytes: 0))
                let result = ItemRunResult(itemID: item.id, title: item.title, outcome: outcome,
                                           estimatedBytes: item.reclaimableBytes, recoveredBytes: 0, reason: .cancelled)
                results.append(result)
                onItemFinish?(index, result)
                continue
            }
            onItemStart?(index, item)
            var recovered: Int64 = 0
            if auditFailure == nil {
                do {
                    try audit.appendRequired(AuditEvent(op: "run.item.intent", detail: item.id))
                } catch {
                    auditFailure = String(describing: error)
                }
            }
            let outcome: RunOutcome
            let reason: OutcomeReason?
            if let auditFailure {
                outcome = .failed("审计日志无法写入，已停止：" + auditFailure)
                reason = .auditFailed
            } else {
                (outcome, reason) = execute(item, batchID: batchID, started: started, options: options, writer: &writer,
                                            writerError: &writerError, recovered: &recovered, serviceIssues: &serviceIssues,
                                            onStep: { onItemStep?(index, $0) })
            }
            // 命令项释放了多少执行器无从得知：记 nil，不记 0（0 读起来像「什么也没释放」）
            audit.append(AuditEvent(op: "run.item.result", detail: "\(item.id) \(outcome)",
                                    bytes: item.action.type == .command ? nil : recovered))
            if outcome == .done, let regrows = item.copy.regrows { regrowNotes.append("\(item.title)：\(regrows)") }
            let result = ItemRunResult(itemID: item.id, title: item.title, outcome: outcome,
                                       estimatedBytes: item.reclaimableBytes, recoveredBytes: recovered, reason: reason)
            results.append(result)
            onItemFinish?(index, result)
        }
        let report = RunReport(batchID: batchID, startedAt: started, finishedAt: now(), freeBefore: freeBefore,
                               freeAfter: files.volumeSummary(atPath: home)?.freeBytes, results: results,
                               serviceIssues: serviceIssues, regrowNotes: regrowNotes)
        audit.append(AuditEvent(op: "run.finish", detail: batchID, bytes: report.measuredFreedBytes))
        return report
    }

    static func batchID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "run-" + formatter.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: 退出应用

    /// 集中退出：每个应用只处理一次。只退出用户同意的；编辑器与 IDE 一律不代为退出；
    /// 正常退出超时后，只有用户对该应用单独同意才强制结束。审计写不进去就不退出（该项随后因应用仍在运行而跳过）。
    func quitApps(for items: [CleanItem], options: ExecutionOptions) {
        var seen = Set<String>()
        for app in items.flatMap({ $0.preconditions.quitApps ?? [] }) where seen.insert(app.bundleID).inserted {
            guard apps.isRunning(bundleID: app.bundleID), app.canQuitForUser,
                  options.quitApps.contains(app.bundleID) else { continue }
            guard (try? audit.appendRequired(AuditEvent(op: "run.app.quit", detail: app.bundleID))) != nil else { continue }
            if !apps.requestQuit(bundleID: app.bundleID, timeout: options.quitTimeout),
               options.forceQuitApps.contains(app.bundleID),
               (try? audit.appendRequired(AuditEvent(op: "run.app.force-quit", detail: app.bundleID))) != nil {
                _ = apps.forceQuit(bundleID: app.bundleID)
            }
        }
    }

    /// 界面用的退出应用阶段：对确实会执行的项所需、且用户同意代为退出的应用逐个正常退出（写审计），
    /// 返回超时仍未退出的应用，由界面逐个询问是否强制退出。编辑器与 IDE（canQuitForUser == false）一律不处理。
    /// 审计写不进去就不退出该应用（随后执行时该项因应用仍在运行而跳过）。
    /// 每个应用之前检查 cancellation：已停止就不再退出（也不再审计）其余应用，返回已收集到的未退出应用。
    /// onApp 在真正请求退出某个应用之前调用（界面显示「正在退出 <应用名>…」），与 run 的回调一样须很快返回。
    /// 不获取操作锁：之后的 run 仍可能以 .busy 失败，执行时也会重新检查每一项的全部前提条件。
    public func quitPhase(_ items: [CleanItem], consentedApps: Set<String>, timeout: TimeInterval = 10,
                          cancellation: OperationCancellation? = nil, onApp: ((QuitApp) -> Void)? = nil) -> [QuitApp] {
        var seen = Set<String>()
        var stuck: [QuitApp] = []
        for app in items.filter({ !($0.preconditions.quitApps ?? []).isEmpty }).filter(willRun).flatMap({ $0.preconditions.quitApps ?? [] }) where seen.insert(app.bundleID).inserted {
            if cancellation?.isCancelled == true { break }
            guard apps.isRunning(bundleID: app.bundleID), app.canQuitForUser, consentedApps.contains(app.bundleID) else { continue }
            guard (try? audit.appendRequired(AuditEvent(op: "run.app.quit", detail: app.bundleID))) != nil else { continue }
            onApp?(app)
            if !apps.requestQuit(bundleID: app.bundleID, timeout: timeout) { stuck.append(app) }
        }
        return stuck
    }

    /// 用户对这些应用逐个同意了强制退出（应为 quitPhase 返回的应用）。编辑器与 IDE 一律不处理。
    /// 不获取操作锁：之后的 run 仍可能以 .busy 失败，执行时也会重新检查每一项的全部前提条件。
    public func forceQuit(_ targets: [QuitApp]) {
        for app in targets where app.canQuitForUser && apps.isRunning(bundleID: app.bundleID) {
            guard (try? audit.appendRequired(AuditEvent(op: "run.app.force-quit", detail: app.bundleID))) != nil else { continue }
            _ = apps.forceQuit(bundleID: app.bundleID)
        }
    }

    /// 退出应用前的预判：只有这一项在应用退出后确实会执行，才值得为它退出应用。
    /// 逐项执行时仍会完整复查一遍。
    func willRun(_ item: CleanItem) -> Bool {
        if item.tier == .displayOnly || item.action.type == .noAction { return false }
        if case .failure = revalidate(item) { return false }
        let others = checker.blockers(for: item).filter { !$0.isAppRunning }
        return others.isEmpty || pausePlan(for: item, blockers: others) != nil
    }

    // MARK: 单项

    func execute(_ item: CleanItem, batchID: String, started: Date, options: ExecutionOptions,
                 writer: inout RecoveryBatchWriter?, writerError: inout String?, recovered: inout Int64,
                 serviceIssues: inout [String], onStep: (String) -> Void = { _ in }) -> (RunOutcome, OutcomeReason?) {
        if item.tier == .displayOnly || item.action.type == .noAction { return (.skipped("只展示项不可执行"), .other) }
        let paths: [String]
        switch revalidate(item) {
        case .success(let valid): paths = valid
        case .failure(let reason): return (.skipped(reason.message), reason.reason)
        }
        let blockers = checker.blockers(for: item)
        if let app = blockers.first(where: \.isAppRunning) { return (.skipped(app.message), .appRunning) }
        guard !blockers.isEmpty else {
            return perform(item, paths: paths, batchID: batchID, started: started, writer: &writer,
                           writerError: &writerError, recovered: &recovered)
        }
        // 只有占用者全部是登记的服务时才暂停；占用状态未知或有其他进程占用，照常跳过。
        guard let plan = pausePlan(for: item, blockers: blockers) else {
            return (.skipped(blockers.map(\.message).joined(separator: "；")), blockerReason(blockers))
        }
        // 暂停 → 复查 → 执行 → 恢复，在一次执行内连续完成，避免中途被其他程序重新拉起
        onStep("正在暂停 " + plan.map(\.service.name).joined(separator: "、") + "…")
        let paused = pause(plan, timeout: options.serviceWaitTimeout)
        let outcome: (RunOutcome, OutcomeReason?)
        if paused.isEmpty {
            outcome = (.skipped(blockers.map(\.message).joined(separator: "；")), .occupied)
        } else {
            let recheck = checker.blockers(for: item)
            if recheck.isEmpty {
                onStep("正在清理…")
                outcome = perform(item, paths: paths, batchID: batchID, started: started, writer: &writer,
                                  writerError: &writerError, recovered: &recovered)
            } else {
                outcome = (.skipped("暂停服务后仍被占用：" + recheck.map(\.message).joined(separator: "；")), .occupied)
            }
        }
        if !paused.isEmpty { onStep("正在恢复 " + paused.map(\.service.name).joined(separator: "、") + "…") }
        resume(paused, timeout: options.serviceWaitTimeout, issues: &serviceIssues)
        return outcome
    }

    /// 阻塞：无法暂停服务时，若任一阻塞为「未知」则原因是 unavailable，否则是 occupied。
    func blockerReason(_ blockers: [Blocker]) -> OutcomeReason {
        blockers.contains { if case .unavailable = $0 { return true } else { return false } } ? .unavailable : .occupied
    }

    struct SkipReason: Error { let message: String; let reason: OutcomeReason }

    /// 执行前复核：命令项的路径只用于估算，不要求存在；移入恢复区的项逐个核对（重复路径只算一次）。
    /// 任何一个路径命中禁区或是符号链接，整项跳过。recoverOlderThan 中不是普通文件或已不够旧的路径单独剔除；
    /// 剔除后（含已不存在的）一个都不剩才整项跳过。同一项里嵌套在另一路径内的路径只保留外层（外层移走时内层随之移走）。
    func revalidate(_ item: CleanItem) -> Result<[String], SkipReason> {
        guard item.action.type != .command else { return .success([]) }
        var valid: [String] = []
        var seen = Set<String>()
        let home = files.homeDirectory()
        let dataDirs = [V2Paths.dataDirectory(home: home), EnginePaths.dataDirectory(home: home)].map { $0.lowercased() }
        for path in item.paths where seen.insert(path).inserted {
            // 工具自己的数据目录（操作锁、恢复区、审计日志）：PathSafety 也把它们列为禁区，这里是执行器自己的一道防线。
            let lower = path.lowercased()
            if dataDirs.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") || $0.hasPrefix(lower + "/") }) {
                return .failure(SkipReason(message: "目标是清理工具自己的数据目录：" + path, reason: .protected))
            }
            guard let attributes = files.attributesIfExist(atPath: path) else { continue }
            if attributes.isSymbolicLink || !EnginePathChecks.isCanonical(path, files: files) {
                return .failure(SkipReason(message: "目标或其上级目录变成了符号链接：" + path, reason: .protected))
            }
            if (try? safety.assertAllowed(path)) == nil {
                return .failure(SkipReason(message: "目标位于受保护位置：" + path, reason: .protected))
            }
            if item.action.type == .recoverOlderThan {
                guard let days = item.action.olderThanDays, days > 0 else {
                    return .failure(SkipReason(message: "缺少有效的天数：" + path, reason: .other))
                }
                let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
                guard attributes.isRegularFile, let modified = attributes.modificationDate, modified < cutoff else { continue }
            }
            valid.append(path)
        }
        let outer = valid.filter { path in !valid.contains { $0 != path && PathSafety.isInside(path, root: $0) } }
        return outer.isEmpty ? .failure(SkipReason(message: "目标已不存在或已被修改", reason: .gone)) : .success(outer)
    }

    func perform(_ item: CleanItem, paths: [String], batchID: String, started: Date,
                 writer: inout RecoveryBatchWriter?, writerError: inout String?,
                 recovered: inout Int64) -> (RunOutcome, OutcomeReason?) {
        switch item.action.type {
        case .command:
            guard let argv = item.action.command, !argv.isEmpty else { return (.failed("缺少命令"), .commandFailed) }
            guard let result = runCommand(argv) else {
                return (.failed("找不到命令或命令无法启动、超时：" + argv[0]), .commandFailed)
            }
            guard result.exitStatus == 0 else {
                let last = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                return (.failed("命令失败（退出码 \(result.exitStatus)）：" + last), .commandFailed)
            }
            return (.done, nil)
        case .recover, .recoverOlderThan:
            // 恢复区建不起来就记住第一次的错误，后续项直接失败，不反复重试。
            if let writerError { return (.failed("无法创建恢复区：" + writerError), .recoveryFailed) }
            if writer == nil {
                do { writer = try recovery.begin(batchID: batchID, now: started) }
                catch {
                    writerError = String(describing: error)
                    return (.failed("无法创建恢复区：\(error)"), .recoveryFailed)
                }
            }
            var moved = 0
            var errors: [String] = []
            let sizer = Sizer(files: files)
            for path in paths {
                // 仅作防御：PathSafety 按实例缓存保护位置，这次复查通常与 revalidate 结果一致。
                if (try? safety.assertAllowed(path)) == nil {
                    errors.append("\(path)：目标位于受保护位置")
                    continue
                }
                let bytes = sizer.measure([path]).apparent
                do {
                    try writer!.admit(path: path, bytes: bytes, itemID: item.id, itemTitle: item.title)
                    recovered += bytes
                    moved += 1
                } catch {
                    errors.append("\(path)：\(error)")
                }
            }
            if errors.isEmpty { return (.done, nil) }
            return (.failed("\(moved) 个已移入恢复区，\(errors.count) 个失败：" + errors.joined(separator: "；")), .recoveryFailed)
        case .noAction:
            return (.skipped("只展示项不可执行"), .other)
        }
    }

    /// 用 /usr/bin/env 固定 PATH 运行：npm 等脚本需要同目录的 node，菜单栏应用继承的 PATH 不可靠。
    func runCommand(_ argv: [String]) -> ProcessResult? {
        guard let envArgs = envArguments(argv) else { return nil }
        return commandRunner.run(launchPath: "/usr/bin/env", arguments: envArgs)
    }

    /// 解析出交给 /usr/bin/env 的参数：[PATH=…, 可执行文件绝对路径, 参数…]。找不到命令或不安全时返回 nil。
    func envArguments(_ argv: [String]) -> [String]? {
        guard let first = argv.first, let executable = ExecutableResolver(files: files).resolve(first) else { return nil }
        let dir = (executable as NSString).deletingLastPathComponent
        // env 会把含 = 的参数当作变量赋值；PATH 里的 : 是分隔符。两者都会让实际运行的程序偏离预期。
        guard !executable.contains("="), !dir.contains(":") else { return nil }
        let path = "PATH=" + dir + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return [path, executable] + argv.dropFirst().map { safety.expandTilde($0) }
    }

    // MARK: 服务暂停与恢复

    /// 当前用户下匹配该服务的进程号；pgrep 无法启动或结果异常时返回 nil（状态未知）。
    func servicePIDs(_ service: PausableService) -> Set<Int32>? {
        guard let result = runner.run(launchPath: GuardEvaluator.pgrepPath,
                                      arguments: ["-u", String(getuid()), "-f", service.processPattern]) else { return nil }
        if result.exitStatus == 1 && result.stdout.isEmpty { return [] }
        guard result.exitStatus == 0 else { return nil }
        return Set(result.stdout.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    typealias PauseTarget = (service: PausableService, before: Set<Int32>, occupying: Set<Int32>)

    /// 要暂停的服务、暂停前的全部进程号、其中占用锁文件的进程号。只有全部阻塞都是「被占用」，
    /// 且每个占用进程都属于某个登记的服务时才返回；否则返回 nil（不暂停任何服务）。
    func pausePlan(for item: CleanItem, blockers: [Blocker]) -> [PauseTarget]? {
        let services = item.preconditions.pausableServices ?? []
        guard !services.isEmpty,
              blockers.allSatisfy({ if case .occupied = $0 { return true } else { return false } }) else { return nil }
        var occupiers = Set<Int32>()
        for lock in item.preconditions.lockfiles ?? [] {
            switch checker.guards.status(of: [GuardSpec(type: .lockfile, path: lock)], home: checker.home) {
            case .clear: continue
            case .blocked(let list): occupiers.formUnion(list.map(\.pid))
            case .unknown: return nil
            }
        }
        guard !occupiers.isEmpty else { return nil }
        var plan: [PauseTarget] = []
        var covered = Set<Int32>()
        for service in services {
            guard let pids = servicePIDs(service) else { continue }
            let occupying = pids.intersection(occupiers)
            guard !occupying.isEmpty else { continue }
            plan.append((service, pids, occupying))
            covered.formUnion(occupying)
        }
        guard !plan.isEmpty, occupiers.isSubset(of: covered) else { return nil }
        return plan
    }

    /// 返回已发出停止命令的服务及其暂停前进程号；这些服务之后都会交给 resume。审计写不进去就不再暂停后续服务。
    func pause(_ plan: [PauseTarget], timeout: TimeInterval) -> [(service: PausableService, before: Set<Int32>)] {
        var paused: [(service: PausableService, before: Set<Int32>)] = []
        for target in plan {
            guard (try? audit.appendRequired(AuditEvent(op: "run.service.stop", detail: target.service.name))) != nil else { break }
            if let envArgs = envArguments(target.service.stop) {
                _ = runner.run(launchPath: "/usr/bin/env", arguments: envArgs)
            }
            paused.append((target.service, target.before))
            // 只等占用锁文件的那些进程消失（同名匹配的无关进程可能一直在）；pgrep 状态未知时视为仍在运行。
            waitUntil(timeout) { (self.servicePIDs(target.service) ?? target.occupying).isDisjoint(with: target.occupying) }
        }
        return paused
    }

    /// 暂停前没有的新进程出现，才算服务重新运行。
    func isRunningAgain(_ service: PausableService, before: Set<Int32>) -> Bool? {
        servicePIDs(service).map { !$0.subtracting(before).isEmpty }
    }

    func resume(_ paused: [(service: PausableService, before: Set<Int32>)], timeout: TimeInterval, issues: inout [String]) {
        for (service, before) in paused {
            // 已经被别的程序重新拉起：不重复启动，也不算问题。
            // pgrep 状态未知（nil）时保守地照常启动，可能重复启动一次。
            if isRunningAgain(service, before: before) == true { continue }
            audit.append(AuditEvent(op: "run.service.start", detail: service.name))
            if let envArgs = envArguments(service.start) {
                // 后台启动并与本进程脱离：命令作为位置参数传给 sh，不拼接字符串；nohup 让它不随挂断信号退出。
                _ = runner.run(launchPath: "/bin/sh",
                               arguments: ["-c", "\"$@\" </dev/null >/dev/null 2>&1 &", "sh", "/usr/bin/nohup", "/usr/bin/env"]
                                   + envArgs)
            }
            if !waitUntil(timeout, { self.isRunningAgain(service, before: before) == true }) {
                issues.append("服务 \(service.name) 未能自动恢复，请手动运行：" + service.start.joined(separator: " "))
            }
        }
    }

    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        // 次数上限兜底：注入的时钟若不随 sleep 前进，也不会无限循环。
        let maxIterations = Int(max(timeout, 0) / 0.5) + 2
        for _ in 0..<maxIterations {
            if condition() { return true }
            if now() >= deadline { return false }
            sleep(0.5)
        }
        return condition()
    }
}
