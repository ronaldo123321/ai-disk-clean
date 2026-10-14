import Foundation
import CleanerCore

let usage = """
清理大师命令行（默认只读；clean 加 --apply 才执行）

用法:
  dclean scan [--json] [--no-projects] [--no-docker] [--no-space-map]
                              只读扫描，按档位列出清理项
  dclean clean [--tiers safe,suggested] [--only id1,id2] [--quit-apps] [--apply] [--json] [--space-map]
                              预览或执行清理方案；--quit-apps 允许工具正常退出应用（不会强制退出，也不会退出 IDE）
                              同时给出 --tiers 与 --only 时取二者交集；--space-map 额外扫描规则之外的大目录（默认不扫描）
  dclean recovery [list | restore <批次ID> | purge [--days 7] [--apply]]
                              恢复区：查看、还原；purge 默认只预览将被永久清空的批次，加 --apply 才真正删除
  dclean rules                查看已加载的规则与规则问题
"""

let arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { arguments.contains(name) }
func usageFail() -> Never {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
/// 取值旗标：值缺失或以 "--" 开头一律视为参数错误（usage、退出码 2）。旗标本身不存在则返回 nil（调用方决定默认值）。
func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { usageFail() }
    return arguments[index + 1]
}
/// 严格参数校验：args 是子命令之后的参数。只接受 flags 与 valueFlags 中的旗标（任何以 - 开头的其它参数都算未知旗标），
/// 取值旗标紧跟的下一个参数是它的值、不算位置参数；位置参数必须恰好 positionals 个。不合规一律 usage、退出码 2。
func checkArguments(_ args: ArraySlice<String>, flags: Set<String> = [], valueFlags: Set<String> = [], positionals: Int = 0) {
    var positionalCount = 0
    var index = args.startIndex
    while index < args.endIndex {
        let arg = args[index]
        if valueFlags.contains(arg) {
            guard index + 1 < args.endIndex, !args[index + 1].hasPrefix("--") else { usageFail() }
            index += 2
            continue
        }
        if arg.hasPrefix("-") {
            guard flags.contains(arg) else { usageFail() }
        } else {
            positionalCount += 1
        }
        index += 1
    }
    guard positionalCount == positionals else { usageFail() }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let files = RealFileOperations()
let home = files.homeDirectory()
let safety = PathSafety(home: home, files: files)
let probeRunner = RealProcessRunner(timeout: 30)
let commandRunner = RealProcessRunner(timeout: 900, outputLimit: 8 << 20)
let apps = RealAppControl()
let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: probeRunner), home: home)
let audit = AuditLog(files: files, path: EnginePaths.auditLog(home: home))
let recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files, audit: audit)

func human(_ bytes: Int64) -> String { ByteFormatting.human(bytes) }

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { fail("无法输出 JSON") }
    print(String(decoding: data, as: UTF8.self))
}

func loadRules() -> LoadedRules {
    guard let bundled = RulePack.bundledData() else { fail("找不到内置规则包") }
    return RulePack.load(bundled: bundled, user: files.readFile(atPath: EnginePaths.userRules(home: home)), safety: safety)
}

func scan(includeSpaceMap: Bool) -> ScanResult {
    let loaded = loadRules()
    for problem in loaded.problems { warn("规则问题：" + problem) }
    var detectors: [Detector] = [RuleDetector(rules: loaded.rules)]
    if !flag("--no-projects") { detectors.append(ProjectArtifactDetector()) }
    if !flag("--no-docker") { detectors.append(DockerDetector()) }
    let context = DetectContext(files: files, safety: safety, runner: probeRunner, now: Date())
    return EngineScanner(context: context, detectors: detectors,
                         spaceMap: includeSpaceMap ? SpaceMapDetector() : nil, checker: checker).scan()
}

func printPlan(_ plan: CleanPlan, disk: DiskSummary?) {
    if let disk { print("磁盘：可用 \(human(disk.freeBytes)) / 共 \(human(disk.totalBytes))") }
    for tier in CleanTier.allCases {
        let items = plan.items(in: tier)
        guard !items.isEmpty else { continue }
        print("\n== \(tier.title)（\(items.count) 项）")
        for item in items {
            let mark = tier == .displayOnly ? "  " : (plan.selectedIDs.contains(item.id) ? "☑ " : "☐ ")
            let size = tier == .displayOnly
                ? human(item.apparentBytes)
                : item.action.type == .command ? "预计立即释放 \(human(item.reclaimableBytes))"
                : "移入恢复区 \(human(item.apparentBytes))（仍占空间）"
            print("\(mark)\(item.title)  \(size)  [\(item.id)]")
            for blocker in item.blockers { print("     ⚠ " + blocker.message) }
            for note in item.notes { print("     · " + note) }
        }
    }
    print("\n预计立即释放：\(human(plan.estimatedImmediateBytes))；移入恢复区：\(human(plan.recoveryMoveBytes))（仍占空间）")
    let quit = plan.appsToQuit
    let selfQuit = quit.filter { !$0.canQuitForUser }
    let toolQuit = quit.filter(\.canQuitForUser)
    if !selfQuit.isEmpty {
        print("其中需要你自己先退出的应用：" + selfQuit.map(\.name).joined(separator: "、") + "（不退出则这些项会被跳过）")
    }
    if !toolQuit.isEmpty { print("需要先退出：" + toolQuit.map(\.name).joined(separator: "、")) }
}

func printReport(_ report: RunReport) {
    for result in report.results {
        switch result.outcome {
        case .done: print("✓ \(result.title)")
        case .skipped(let why): print("– \(result.title)：跳过，\(why)")
        case .failed(let why): print("✗ \(result.title)：\(why)")
        }
    }
    if let freed = report.measuredFreedBytes { print("\n卷可用空间\(freed >= 0 ? "增加" : "减少")：\(human(abs(freed)))（前后观测值，受其他程序写入影响）") }
    if report.recoveryBytes > 0 {
        print("移入恢复区：\(human(report.recoveryBytes))，清空恢复区后才会释放（批次 \(report.batchID)）")
    }
    for issue in report.serviceIssues { print("⚠ " + issue) }
    for note in report.regrowNotes { print("↻ " + note) }
}

func hasFailure(_ report: RunReport) -> Bool {
    report.results.contains { if case .failed = $0.outcome { return true } else { return false } }
}

struct QuitAppJSON: Encodable {
    let name: String
    let bundleID: String
    let canQuitForUser: Bool
}

struct CleanPreviewJSON: Encodable {
    let items: [CleanItem]
    let selectedIDs: [String]
    let estimatedReclaimableBytes: Int64
    let estimatedImmediateBytes: Int64
    let recoveryMoveBytes: Int64
    let appsToQuit: [QuitAppJSON]
}

struct RunReportJSON: Encodable {
    let report: RunReport
    let measuredFreedBytes: Int64?
    let recoveryBytes: Int64
}

switch arguments.first {
case nil, "help", "--help":
    print(usage)

case "scan":
    checkArguments(arguments.dropFirst(), flags: ["--json", "--no-projects", "--no-docker", "--no-space-map"])
    let result = scan(includeSpaceMap: !flag("--no-space-map"))
    if flag("--json") { printJSON(result) } else { printPlan(PlanBuilder.build(from: result), disk: result.disk) }

case "clean":
    checkArguments(arguments.dropFirst(),
                   flags: ["--quit-apps", "--apply", "--json", "--space-map", "--no-projects", "--no-docker"],
                   valueFlags: ["--tiers", "--only"])
    let result = scan(includeSpaceMap: flag("--space-map"))
    var plan = PlanBuilder.build(from: result)
    let itemsByID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0) })
    let actionable = Set(plan.items.filter { $0.tier != .displayOnly }.map(\.id))

    var tiersSelection: Set<String>?
    if let tiers = value("--tiers") {
        var wanted = Set<CleanTier>()
        for name in tiers.split(separator: ",").map(String.init) {
            if let tier = CleanTier(rawValue: name) {
                wanted.insert(tier)
            } else {
                warn("忽略未知档位：" + name)
            }
        }
        tiersSelection = Set(plan.items.filter { wanted.contains($0.tier) && $0.blockers.allSatisfy(\.isAppRunning) }.map(\.id))
            .intersection(actionable)
    }

    var onlySelection: Set<String>?
    if let only = value("--only") {
        var selected = Set<String>()
        for id in only.split(separator: ",").map(String.init) {
            guard let item = itemsByID[id] else {
                warn("忽略未知清理项：" + id)
                continue
            }
            guard item.tier != .displayOnly else {
                warn("忽略只展示项：" + id)
                continue
            }
            selected.insert(id)
        }
        onlySelection = selected
    }

    switch (tiersSelection, onlySelection) {
    case let (tiers?, only?): plan.selectedIDs = tiers.intersection(only)
    case let (tiers?, nil): plan.selectedIDs = tiers
    case let (nil, only?): plan.selectedIDs = only
    case (nil, nil): break
    }

    guard flag("--apply") else {
        if flag("--json") {
            let preview = CleanPreviewJSON(
                items: plan.items,
                selectedIDs: plan.selectedIDs.sorted(),
                estimatedReclaimableBytes: plan.estimatedReclaimableBytes,
                estimatedImmediateBytes: plan.estimatedImmediateBytes,
                recoveryMoveBytes: plan.recoveryMoveBytes,
                appsToQuit: plan.appsToQuit.map { QuitAppJSON(name: $0.name, bundleID: $0.bundleID, canQuitForUser: $0.canQuitForUser) })
            printJSON(preview)
        } else {
            printPlan(plan, disk: result.disk)
            print("\n这是预览，没有做任何改动。加 --apply 执行；需要工具帮忙正常退出应用时加 --quit-apps。")
        }
        exit(0)
    }

    guard !plan.selectedIDs.isEmpty else {
        print("没有选中可执行的清理项")
        exit(0)
    }

    let quit = flag("--quit-apps") ? Set(plan.appsToQuit.filter(\.canQuitForUser).map(\.bundleID)) : []
    let executor = PlanExecutor(files: files, safety: safety, runner: probeRunner, commandRunner: commandRunner,
                                apps: apps, recovery: recovery, audit: audit)
    do {
        let report = try executor.run(plan.selectedItems, options: ExecutionOptions(quitApps: quit))
        if flag("--json") {
            printJSON(RunReportJSON(report: report, measuredFreedBytes: report.measuredFreedBytes, recoveryBytes: report.recoveryBytes))
        } else {
            printReport(report)
        }
        if hasFailure(report) { exit(1) }
    } catch {
        fail(String(describing: error))
    }

case "recovery":
    switch arguments.dropFirst().first ?? "list" {
    case "list":
        checkArguments(arguments.dropFirst(2))
        for batch in recovery.list() {
            print("\(batch.id)  \(batch.createdAt)  \(human(recovery.occupiedBytes(of: batch)))  \(batch.entries.count) 项")
        }
        print("恢复区合计：\(human(recovery.occupiedBytes()))，保留 \(RecoveryStore.retentionDays) 天")
        for orphan in recovery.orphanBatches() { print("⚠ 恢复记录损坏，未计入也不会自动清空：" + orphan) }
    case "restore":
        checkArguments(arguments.dropFirst(2), positionals: 1)
        let result = recovery.restore(batchID: arguments[2])
        result.restored.forEach { print("✓ 已还原 " + $0) }
        result.errors.forEach { warn("✗ " + $0) }
        if !result.errors.isEmpty { exit(1) }
    case "purge":
        checkArguments(arguments.dropFirst(2), flags: ["--apply"], valueFlags: ["--days"])
        let days: Int
        if let daysArg = value("--days") {
            guard let parsed = Int(daysArg), parsed >= 0 else { usageFail() }
            days = parsed
        } else {
            days = RecoveryStore.retentionDays
        }
        if flag("--apply") {
            let result = recovery.purge(olderThanDays: days, now: Date())
            result.purged.forEach { print("已永久清空批次 " + $0) }
            result.errors.forEach { warn("✗ " + $0) }
            if !result.errors.isEmpty { exit(1) }
        } else {
            let now = Date()
            let due = recovery.list().filter { now.timeIntervalSince($0.createdAt) >= Double(days) * 86_400 }
            if due.isEmpty {
                print("没有超过 \(days) 天的批次")
            } else {
                for batch in due {
                    print("\(batch.id)  \(batch.createdAt)  \(human(recovery.occupiedBytes(of: batch)))")
                }
            }
            print("加 --apply 才会永久删除")
        }
    default:
        usageFail()
    }

case "rules":
    checkArguments(arguments.dropFirst())
    let loaded = loadRules()
    for rule in loaded.rules { print("\(rule.tier.title)\t\(rule.id)\t\(rule.name)") }
    for problem in loaded.problems { print("问题：" + problem) }

default:
    usageFail()
}
