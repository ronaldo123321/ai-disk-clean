# DiskCleaner 实施计划（TDD）

日期：2026-09-17
状态：任务 1–13 已完成（74 项单测全绿 + 真机只读冒烟通过）；任务 14（GUI）已完成
关联设计：[2026-09-17-disk-cleaner-design.md](../specs/2026-09-17-disk-cleaner-design.md)

本计划覆盖设计文档 §11 交付顺序的 1–3 步（引擎、CLI、默认规则集）；GUI 壳（DiskCleanerApp）与 launchd 定时任务为下一阶段。

## 任务总览

| # | 任务 | 交付物 | 验收（对应 spec §10 用例表） |
|---|---|---|---|
| 1 | Package 骨架 | `Package.swift` | 三 target 可编译 |
| 2 | 数据模型 | `Sources/CleanerCore/Models.swift` | 规则校验、风险×策略互斥 |
| 3 | PathSafety 七层防护 | `Sources/CleanerCore/PathSafety.swift` | 围栏 / 禁区两分类 / 路径断言 |
| 4 | FileOperations | `Sources/CleanerCore/FileOperations.swift` | 只删链接不删目标；truncate 拒绝链接 |
| 5 | 占用守卫 | `GuardEvaluator.swift` + `ProcessRunner.swift` | lsof/pgrep 解析、注入阻塞 |
| 6 | Scanner | `Sources/CleanerCore/Scanner.swift` | 四策略遍历、符号链接不下钻、du 口径 |
| 7 | 隔离区 | `Sources/CleanerCore/Quarantine.swift` | 隔离往返逐字节一致、8 天清 6 天留 |
| 8 | Planner | `Sources/CleanerCore/Planner.swift` | 禁区命中整个计划 abort |
| 9 | Executor | `Sources/CleanerCore/Executor.swift` | TOCTOU skip、命令失败不回退 |
| 10 | 审计日志 | `Sources/CleanerCore/AuditLog.swift` | JSONL 追加、abort 入账 |
| 11 | RuleStore + 默认规则 | `RuleStore.swift` + `DefaultRules.json` | 首次落盘、绝不覆盖用户文件 |
| 12 | CLI | `Sources/dclean/main.swift` | scan/plan/apply/restore/purge |
| 13 | 冒烟测试 | `Tests/CleanerCoreTests/SmokeTests.swift` | 真机只读扫描 + report 可解析 |

## 设计修订落地点

- **禁区两分类**（spec §5 第 3 层修订）：`exactForbiddenPaths = ["/", "/Users", $HOME]` 精确匹配；`treeForbiddenRoots`（/System、~/Documents 等）整树匹配；`.git` 组件单独判定。回归用例：`testUsersDescendantsAreNotForbidden`、真机用例 `testRealHomePathsAreNotFalsePositiveForbidden`。
- **黄色与 command/truncate 互斥**（spec §4 修订）：`Strategy.isCompatible` 三处设卡——`validateRules`（载入报错）、Scanner（configError）、Planner（invalidRule 大声失败）。Docker 悬空镜像在默认规则中已为绿色 + command，explain 写明不可还原。

---

## 任务 1：Package 骨架

SwiftPM 三 target；工具链 swift-tools-version 5.10（Swift 5 语言模式，规避严格并发噪音）。默认规则 JSON 作为 CleanerCore 资源随二进制发布。

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DiskCleaner",
    platforms: [.macOS(.v13)],
    targets: [
        // 引擎（库）：规则加载、扫描、风险评级、计划、执行、隔离区、审计
        .target(
            name: "CleanerCore",
            resources: [.copy("DefaultRules.json")]
        ),
        // CLI：scan / plan / apply / restore / purge / quarantine / rules
        .executableTarget(
            name: "dclean",
            dependencies: ["CleanerCore"]
        ),
        // 引擎单测（GUI 壳 DiskCleanerApp 属下一阶段交付，见 spec §11）
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore"]
        ),
    ]
)
```

## 任务 2：数据模型

RiskLevel / Strategy / GuardSpec / Rule / Report / Plan / ExecutionResult 全部 Codable——GUI 与 CLI 通过 JSON 共享同一数据流（spec §3）。校验函数 `validateRules` 是规则文件合法性的唯一裁决点。

```swift
import Foundation

// MARK: - 风险分级（spec §6）

public enum RiskLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case green
    case yellow
    case red

    public var symbol: String {
        switch self {
        case .green: return "🟢"
        case .yellow: return "🟡"
        case .red: return "🔴"
        }
    }

    public var label: String {
        switch self {
        case .green: return "直接清理"
        case .yellow: return "隔离 7 天后删除"
        case .red: return "需手动处理（只看）"
        }
    }

    private var order: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .red: return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

// MARK: - 策略（spec §4）

public struct Strategy: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case command
        case deleteDir = "delete-dir"
        case globAge = "glob-age"
        case truncate
    }

    public var type: Kind
    public var cmd: [String]?
    public var glob: String?
    public var olderThanDays: Int?

    public init(type: Kind, cmd: [String]? = nil, glob: String? = nil, olderThanDays: Int? = nil) {
        self.type = type
        self.cmd = cmd
        self.glob = glob
        self.olderThanDays = olderThanDays
    }

    /// 返回配置错误描述，nil 表示合法。
    public func validate() -> String? {
        switch type {
        case .command:
            guard let cmd, !cmd.isEmpty, !cmd[0].isEmpty else { return "command 策略需要非空 cmd 数组" }
            return nil
        case .globAge:
            guard let glob, !glob.isEmpty else { return "glob-age 策略需要 glob 模式" }
            guard let days = olderThanDays, days >= 0 else { return "glob-age 策略需要 olderThanDays ≥ 0" }
            return nil
        case .deleteDir, .truncate:
            return nil
        }
    }

    /// 风险等级与策略的兼容性（spec §4 修正记录）：
    /// command / truncate 无法先移入隔离区、无法还原，只能配绿色；黄色只能配 delete-dir / glob-age。
    public static func isCompatible(risk: RiskLevel, type: Kind) -> Bool {
        switch risk {
        case .green:
            return true
        case .yellow:
            return type == .deleteDir || type == .globAge
        case .red:
            // 红色只读展示，不产生清理动作，策略仅用于文档说明
            return true
        }
    }
}

// MARK: - 守卫（spec §4）

public struct GuardSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case lockfile
        case process
    }

    public var type: Kind
    public var path: String?
    public var process: String?

    public init(type: Kind, path: String? = nil, process: String? = nil) {
        self.type = type
        self.path = path
        self.process = process
    }

    public func validate() -> String? {
        switch type {
        case .lockfile:
            guard let path, !path.isEmpty else { return "lockfile guard 需要 path" }
            return nil
        case .process:
            guard let process, !process.isEmpty else { return "process guard 需要 process" }
            return nil
        }
    }
}

// MARK: - 规则（spec §4）

public struct Rule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var risk: RiskLevel
    public var roots: [String]
    public var strategy: Strategy
    public var guards: [GuardSpec]?
    public var explain: String

    public init(id: String, name: String, risk: RiskLevel, roots: [String],
                strategy: Strategy, guards: [GuardSpec]? = nil, explain: String) {
        self.id = id
        self.name = name
        self.risk = risk
        self.roots = roots
        self.strategy = strategy
        self.guards = guards
        self.explain = explain
    }
}

public struct RulesFile: Codable, Equatable, Sendable {
    public var version: Int
    public var rules: [Rule]

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }
}

/// 规则集校验，返回所有错误描述（空数组 = 合法）。
public func validateRules(_ rules: [Rule]) -> [String] {
    var errors: [String] = []
    var seen = Set<String>()
    for rule in rules {
        if rule.id.isEmpty {
            errors.append("规则 id 不能为空")
        } else if !seen.insert(rule.id).inserted {
            errors.append("规则 id 重复：\(rule.id)")
        }
        if rule.roots.isEmpty {
            errors.append("规则 \(rule.id)：roots 不能为空")
        }
        if let e = rule.strategy.validate() {
            errors.append("规则 \(rule.id)：\(e)")
        }
        if !Strategy.isCompatible(risk: rule.risk, type: rule.strategy.type) {
            errors.append("规则 \(rule.id)：黄色规则只能配 delete-dir / glob-age，command / truncate 无法隔离还原")
        }
        if rule.explain.isEmpty {
            errors.append("规则 \(rule.id)：explain 不能为空")
        }
        for g in rule.guards ?? [] {
            if let e = g.validate() {
                errors.append("规则 \(rule.id)：\(e)")
            }
        }
    }
    return errors
}

// MARK: - 守卫评估结果

public struct Occupier: Codable, Equatable, Sendable {
    public var pid: Int32
    public var command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }

    public var description: String { "\(command)(\(pid))" }
}

public enum GuardStatus: Codable, Equatable, Sendable {
    case clear
    case blocked([Occupier])

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var occupierDescription: String? {
        guard case .blocked(let occ) = self else { return nil }
        return occ.map(\.description).joined(separator: ", ")
    }
}

// MARK: - 扫描报告（spec §3 数据流）

public enum EntryStatus: Codable, Equatable, Sendable {
    case ok
    case rootsMissing
    case configError(String)
}

public struct ReportEntry: Codable, Equatable, Sendable {
    public var ruleId: String
    public var ruleName: String
    public var risk: RiskLevel
    public var strategyType: Strategy.Kind
    public var sizeBytes: Int64
    public var candidateCount: Int
    public var candidates: [String]
    public var status: EntryStatus
    public var explain: String

    public init(ruleId: String, ruleName: String, risk: RiskLevel, strategyType: Strategy.Kind,
                sizeBytes: Int64, candidateCount: Int, candidates: [String],
                status: EntryStatus, explain: String) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.risk = risk
        self.strategyType = strategyType
        self.sizeBytes = sizeBytes
        self.candidateCount = candidateCount
        self.candidates = candidates
        self.status = status
        self.explain = explain
    }
}

public struct DiskSummary: Codable, Equatable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public struct Report: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var home: String
    public var disk: DiskSummary?
    public var entries: [ReportEntry]

    public init(generatedAt: Date, home: String, disk: DiskSummary?, entries: [ReportEntry]) {
        self.generatedAt = generatedAt
        self.home = home
        self.disk = disk
        self.entries = entries
    }

    public func entries(withRisk risk: RiskLevel) -> [ReportEntry] {
        entries.filter { $0.risk == risk && $0.status == .ok }
    }

    public func reclaimableBytes(risk: RiskLevel) -> Int64 {
        entries(withRisk: risk).reduce(0) { $0 + $1.sizeBytes }
    }
}

// MARK: - 计划与执行（spec §5 第 7 层）

public enum PlanAction: Codable, Equatable, Sendable {
    case delete
    case quarantine
    case truncate
    case runCommand([String])
}

public enum PlanItemStatus: Codable, Equatable, Sendable {
    case ready
    case blocked([Occupier])
}

public struct PlanItem: Codable, Equatable, Sendable {
    public var path: String
    public var ruleId: String
    public var ruleName: String
    public var risk: RiskLevel
    public var sizeBytes: Int64
    public var action: PlanAction
    public var status: PlanItemStatus
    /// 该项所属规则的 roots，apply 时重校验围栏用
    public var ruleRoots: [String]

    public init(path: String, ruleId: String, ruleName: String, risk: RiskLevel,
                sizeBytes: Int64, action: PlanAction, status: PlanItemStatus, ruleRoots: [String]) {
        self.path = path
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.risk = risk
        self.sizeBytes = sizeBytes
        self.action = action
        self.status = status
        self.ruleRoots = ruleRoots
    }

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    public var actionLabel: String {
        switch action {
        case .delete: return "删除"
        case .quarantine: return "隔离 7 天"
        case .truncate: return "清空内容"
        case .runCommand(let cmd): return "执行 " + cmd.joined(separator: " ")
        }
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var items: [PlanItem]

    public init(id: String, createdAt: Date, items: [PlanItem]) {
        self.id = id
        self.createdAt = createdAt
        self.items = items
    }

    public var executableItems: [PlanItem] { items.filter(\.isReady) }

    /// 绿色项将立即回收的空间
    public var reclaimableBytes: Int64 {
        executableItems.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// 黄色项将移入隔离区的空间（同卷移动不立即释放，spec §6）
    public var quarantinedBytes: Int64 {
        executableItems.filter { $0.risk == .yellow }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var blockedItems: [PlanItem] { items.filter { !$0.isReady } }
}

public enum OutcomeResult: String, Codable, Sendable {
    case done
    case skipped
    case failed
}

public struct ItemOutcome: Codable, Equatable, Sendable {
    public var path: String
    public var ruleId: String
    public var result: OutcomeResult
    public var sizeBytes: Int64
    public var detail: String

    public init(path: String, ruleId: String, result: OutcomeResult, sizeBytes: Int64, detail: String) {
        self.path = path
        self.ruleId = ruleId
        self.result = result
        self.sizeBytes = sizeBytes
        self.detail = detail
    }
}

public struct ExecutionResult: Codable, Equatable, Sendable {
    public var planID: String
    public var startedAt: Date
    public var finishedAt: Date
    public var outcomes: [ItemOutcome]
    public var quarantineBatchID: String?
    public var reclaimedBytes: Int64
    public var quarantinedBytes: Int64

    public init(planID: String, startedAt: Date, finishedAt: Date, outcomes: [ItemOutcome],
                quarantineBatchID: String?, reclaimedBytes: Int64, quarantinedBytes: Int64) {
        self.planID = planID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.quarantineBatchID = quarantineBatchID
        self.reclaimedBytes = reclaimedBytes
        self.quarantinedBytes = quarantinedBytes
    }
}

// MARK: - 错误

public enum PlannerError: Error, CustomStringConvertible, Equatable {
    /// 禁区命中 / 围栏逃逸 → 整个计划 abort（spec §5 第 3 层）
    case forbiddenZone(path: String, reason: String)
    case invalidRule(id: String, reason: String)

    public var description: String {
        switch self {
        case .forbiddenZone(let path, let reason):
            return "计划 abort：\(path) 命中安全红线（\(reason)），已取消整个计划，未执行任何条目"
        case .invalidRule(let id, let reason):
            return "规则配置错误 \(id)：\(reason)"
        }
    }
}

public enum ExecutorError: Error, CustomStringConvertible, Equatable {
    /// apply 时逐条重校验发现禁区命中 → 整个执行 abort（spec §5 第 3、7 层）
    case forbiddenZone(path: String, reason: String)
    case noExecutableItems

    public var description: String {
        switch self {
        case .forbiddenZone(let path, let reason):
            return "执行 abort：\(path) 命中安全红线（\(reason)），已取消整个执行，未改动任何条目"
        case .noExecutableItems:
            return "计划中没有可执行条目（可能全部被守卫阻断或已被清理）"
        }
    }
}
```

## 任务 3：PathSafety（第 2、3、4、5 层）

纯路径运算 + lstat/realpath，无写操作；plan 与 apply 各跑一遍。

- 第 3 层禁区：精确匹配（`/`、`/Users`、`$HOME`）与整树禁止（`/System`、`~/Documents` 等）分列表；`.git` 组件单独判。
- 第 5 层断言：非空 + 深度 ≥ 3，且禁区判定先于深度判定（报错信息更准确）。
- 第 2/4 层围栏：候选本身是符号链接 → 放行为 `symlinkLeaf`（只删链接）；否则 realpath 全量解析，中段目录链接逃逸 → 抛错。

```swift
import Foundation
import Darwin

// MARK: - PathSafety：spec §5 的第 2、3、4、5 层

public enum PathSafetyError: Error, CustomStringConvertible, Equatable {
    case forbiddenExact(String)
    case forbiddenTree(String)
    case escapedFence(candidate: String, resolvedRoot: String)
    case outsideAllRoots(candidate: String, roots: [String])
    case candidateMissing(String)
    case tooShallow(String, depth: Int)

    public var description: String {
        switch self {
        case .forbiddenExact(let p):
            return "\(p) 是硬编码禁区（精确匹配）"
        case .forbiddenTree(let p):
            return "\(p) 位于整棵树禁区或 .git 目录内"
        case .escapedFence(let c, let root):
            return "\(c) 经符号链接解析后逃逸出规则根 \(root)"
        case .outsideAllRoots(let c, let roots):
            return "\(c) 不在任何规则根 \(roots.joined(separator: ", ")) 之内"
        case .candidateMissing(let p):
            return "\(p) 已不存在"
        case .tooShallow(let p, let d):
            return "\(p) 路径深度仅 \(d) 层（要求 ≥ 3），疑似变量为空拼接"
        }
    }
}

public enum FenceResult: Equatable {
    /// 候选本身是符号链接：只删 link 本身，不触碰指向的目标（spec §5 第 4 层）
    case symlinkLeaf(resolved: String?)
    /// 常规路径，realpath 解析后仍在规则根内
    case insideRoot(resolved: String)
}

/// 全部为纯路径运算 + lstat/realpath，不产生任何写操作。
public final class PathSafety {
    public let home: String
    private let files: FileOperations

    public init(home: String, files: FileOperations) {
        self.home = PathSafety.normalize(home, home: home)
        self.files = files
    }

    // MARK: 禁区清单（spec §5 第 3 层，2026-09-17 修订：两分类匹配）

    /// 精确匹配：路径本身等于禁区才命中，后代不受影响。
    public var exactForbiddenPaths: [String] {
        ["/", "/Users", home]
    }

    /// 整棵树禁止：该目录及其所有后代都命中。
    public var treeForbiddenRoots: [String] {
        ["/System",
         home + "/Documents",
         home + "/Desktop",
         home + "/Pictures",
         home + "/.ssh",
         home + "/.gnupg",
         home + "/Library/Keychains"]
    }

    // MARK: 路径展开与规范化

    /// 展开 ~ 与 ~/（不支持 ~user）。
    public func expandTilde(_ raw: String) -> String {
        Self.expandTilde(raw, home: home)
    }

    /// 纯词法规范化：合并 `.`、解析 `..`、去掉多余斜杠。不解析符号链接。
    public func normalize(_ raw: String) -> String {
        Self.normalize(raw, home: home)
    }

    /// 路径组件数（不含根 "/"；"/" 为 0）。
    public func depth(of normalizedPath: String) -> Int {
        Self.depth(of: normalizedPath)
    }

    public func isInside(_ path: String, root: String) -> Bool {
        Self.isInside(path, root: root)
    }

    // MARK: 纯函数版本（无实例状态依赖）

    public static func expandTilde(_ raw: String, home: String) -> String {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + raw.dropFirst() }
        return raw
    }

    public static func normalize(_ raw: String, home: String) -> String {
        let expanded = expandTilde(raw, home: home)
        let isAbsolute = expanded.hasPrefix("/")
        var stack: [String] = []
        for comp in expanded.split(separator: "/") {
            switch comp {
            case ".":
                continue
            case "..":
                if !stack.isEmpty {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(String(comp))
                }
                // 绝对路径在根部再上跳仍留在根
            default:
                stack.append(String(comp))
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    public static func depth(of normalizedPath: String) -> Int {
        guard normalizedPath.hasPrefix("/") else { return 0 }
        return normalizedPath.split(separator: "/").count
    }

    public static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // MARK: 第 3 层：禁区断言（plan 与 apply 各跑一遍）

    /// 校验候选路径合法并返回规范化后的路径。命中禁区抛错（调用方据此 abort 整个计划）。
    @discardableResult
    public func assertAllowed(_ raw: String) throws -> String {
        let p = normalize(raw)
        if exactForbiddenPaths.contains(p) {
            throw PathSafetyError.forbiddenExact(p)
        }
        if treeForbiddenRoots.contains(where: { isInside(p, root: $0) }) {
            throw PathSafetyError.forbiddenTree(p)
        }
        if p.split(separator: "/").contains(".git") {
            throw PathSafetyError.forbiddenTree(p)
        }
        let d = depth(of: p)
        guard d >= 3 else {
            throw PathSafetyError.tooShallow(p, depth: d)
        }
        return p
    }

    // MARK: 第 2、4 层：围栏

    /// 候选必须词法上落在某个 root 内；随后：
    /// - 候选本身是符号链接 → 只删 link，放行（symlinkLeaf）；
    /// - 否则 realpath 全量解析（可暴露路径中段的目录符号链接），逃逸出根则抛错。
    public func checkFence(candidate: String, roots: [String]) throws -> FenceResult {
        let c = normalize(candidate)
        let normRoots = roots.map { normalize($0) }
        guard let root = normRoots.first(where: { isInside(c, root: $0) }) else {
            throw PathSafetyError.outsideAllRoots(candidate: c, roots: normRoots)
        }
        guard let attrs = files.attributesIfExist(atPath: c) else {
            throw PathSafetyError.candidateMissing(c)
        }
        if attrs.isSymbolicLink {
            return .symlinkLeaf(resolved: files.realPath(ofPath: c))
        }
        let resolvedCandidate = files.realPath(ofPath: c) ?? c
        let resolvedRoot = files.realPath(ofPath: root) ?? root
        guard isInside(resolvedCandidate, root: resolvedRoot) else {
            throw PathSafetyError.escapedFence(candidate: c, resolvedRoot: resolvedRoot)
        }
        return .insideRoot(resolved: resolvedCandidate)
    }
}
```

```swift
import XCTest
@testable import CleanerCore

/// spec §10 用例表：围栏（层 2、4）、禁区（层 3）、路径断言（层 5）
final class PathSafetyTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var safety: PathSafety!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-safety")
        files = RealFileOperations()
        safety = PathSafety(home: root, files: files)
    }

    override func tearDown() {
        TestEnv.remove(root!)
        root = nil
        files = nil
        safety = nil
    }

    // ---- 展开 / 规范化 / 深度 ----

    func testExpandTilde() {
        XCTAssertEqual(safety.expandTilde("~"), root)
        XCTAssertEqual(safety.expandTilde("~/.cache/uv"), root + "/.cache/uv")
        XCTAssertEqual(safety.expandTilde("/usr/bin"), "/usr/bin")
        XCTAssertEqual(safety.expandTilde("~other/x"), "~other/x") // 不支持 ~user，原样返回
    }

    func testNormalizeResolvesDotDotLexically() {
        XCTAssertEqual(safety.normalize("/a/b/../c"), "/a/c")
        XCTAssertEqual(safety.normalize("/a/./b/"), "/a/b")
        XCTAssertEqual(safety.normalize("a//b"), "a/b")
        XCTAssertEqual(safety.normalize("/..", ), "/")
        XCTAssertEqual(safety.normalize("~", ), root)
    }

    func testDepthCounting() {
        XCTAssertEqual(safety.depth(of: "/"), 0)
        XCTAssertEqual(safety.depth(of: "/Users"), 1)
        XCTAssertEqual(safety.depth(of: root), PathSafety.depth(of: root))
        XCTAssertGreaterThanOrEqual(safety.depth(of: root + "/a/b"), 3)
    }

    // ---- 第 3 层：禁区两分类（2026-09-17 修订） ----

    func testExactForbiddenHitsOnlyThePathItself() {
        // 精确匹配：/ 、/Users、$HOME 本身
        XCTAssertThrowsError(try safety.assertAllowed("/")) { error in
            guard case PathSafetyError.forbiddenExact("/") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try safety.assertAllowed("/Users")) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try safety.assertAllowed(root)) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
    }

    func testUsersDescendantsAreNotForbidden() {
        // 修正前缀匹配 bug 的回归用例：/Users 的后代不是禁区
        XCTAssertNoThrow(try safety.assertAllowed("/Users/me/.cache/uv"))
        XCTAssertNoThrow(try safety.assertAllowed(root + "/.cache/uv"))
    }

    func testTreeForbiddenCoversDescendants() {
        let forbidden: [String] = [
            "/System",
            "/System/Library/x",
            root + "/Documents",
            root + "/Documents/2024/report.pdf",
            root + "/.ssh",
            root + "/.ssh/id_rsa",
            root + "/Library/Keychains",
        ]
        for p in forbidden {
            XCTAssertThrowsError(try safety.assertAllowed(p), p) { error in
                guard case PathSafetyError.forbiddenTree = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testGitDirectoriesAreForbiddenAnywhere() {
        XCTAssertThrowsError(try safety.assertAllowed(root + "/proj/.git"))
        XCTAssertThrowsError(try safety.assertAllowed(root + "/proj/.git/objects/ab/cdef"))
        XCTAssertNoThrow(try safety.assertAllowed(root + "/proj/repo.git")) // .git 后缀不算
        XCTAssertNoThrow(try safety.assertAllowed(root + "/proj/.github/workflows/x.yml"))
    }

    // ---- 第 5 层：路径断言 ----

    func testTooShallowPathsAreRejected() {
        // "/h" 只有 1 层且不等于任何禁区 → 浅路径拒绝
        XCTAssertThrowsError(try safety.assertAllowed("/h")) { error in
            guard case PathSafetyError.tooShallow = error else { return XCTFail("\(error)") }
        }
        // 禁区判定先于深度判定：把 home 抬到浅层路径时，home 本身报精确禁区而非浅路径
        let shallowSafety = PathSafety(home: "/h", files: files)
        XCTAssertThrowsError(try shallowSafety.assertAllowed("/h")) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try shallowSafety.assertAllowed("/h/a")) { error in
            guard case PathSafetyError.tooShallow = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try shallowSafety.assertAllowed("/h/a/b"))
    }

    // ---- 第 2、4 层：围栏 ----

    func testFenceAllowsSymlinkLeafButFlagsIt() throws {
        let outside = root + "/outside-target"
        try TestEnv.write("precious", to: outside)
        let insideRoot = root + "/rule-root"
        let link = insideRoot + "/link"
        try FileManager.default.createDirectory(atPath: insideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        // macOS 的 /var → /private/var，所以与 realpath 结果比对
        let result = try safety.checkFence(candidate: link, roots: [insideRoot])
        XCTAssertEqual(result, .symlinkLeaf(resolved: files.realPath(ofPath: outside)))
    }

    func testFenceRejectsEscapeThroughIntermediateDirectorySymlink() throws {
        let realDir = root + "/real-dir"
        try FileManager.default.createDirectory(atPath: realDir + "/sub", withIntermediateDirectories: true)
        try TestEnv.write("x", to: realDir + "/sub/file.txt")

        let insideRoot = root + "/rule-root"
        try FileManager.default.createDirectory(atPath: insideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: insideRoot + "/dirlink", withDestinationPath: realDir)

        // 候选本身是常规文件，但路径中段穿过符号链接 → realpath 逃逸
        XCTAssertThrowsError(try safety.checkFence(candidate: insideRoot + "/dirlink/sub/file.txt",
                                                   roots: [insideRoot])) { error in
            guard case PathSafetyError.escapedFence = error else { return XCTFail("\(error)") }
        }
    }

    func testFenceRejectsCandidateOutsideAllRoots() throws {
        XCTAssertThrowsError(try safety.checkFence(candidate: root + "/elsewhere/file",
                                                   roots: [root + "/rule-root"])) { error in
            guard case PathSafetyError.outsideAllRoots = error else { return XCTFail("\(error)") }
        }
    }

    func testFenceReportsMissingCandidate() throws {
        XCTAssertThrowsError(try safety.checkFence(candidate: root + "/rule-root/ghost",
                                                   roots: [root + "/rule-root"])) { error in
            guard case PathSafetyError.candidateMissing = error else { return XCTFail("\(error)") }
        }
    }

    // ---- glob 编译 ----

    func testGlobSemantics() throws {
        func matches(_ glob: String, _ path: String) -> Bool {
            guard let re = Scanner.compileGlob(glob) else {
                XCTFail("glob 编译失败：\(glob)")
                return false
            }
            return re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
        XCTAssertTrue(matches("/logs/*.log", "/logs/a.log"))
        XCTAssertTrue(matches("/logs/*.log", "/logs/a.b.log"))
        XCTAssertFalse(matches("/logs/*.log", "/logs/sub/a.log")) // * 不跨目录
        XCTAssertFalse(matches("/logs/*.log", "/logs/a.txt"))
        XCTAssertTrue(matches("/jb/**", "/jb/x/y/z"))
        XCTAssertTrue(matches("/jb/**", "/jb/x"))
        XCTAssertFalse(matches("/jb/**", "/other/x"))
        XCTAssertTrue(matches("/l?gs", "/logs"))
        XCTAssertTrue(matches("/l?gs", "/lggs")) // ? 匹配任意单字符
        XCTAssertFalse(matches("/l?gs", "/l/gs")) // ? 不匹配 /
        XCTAssertFalse(matches("/l?gs", "/lgs")) // 长度不符
    }
}
```

## 任务 4：FileOperations

引擎唯一触碰文件系统的方式。真实实现走 lstat/unlink 语义；内存实现（spec §10）用于无副作用单测。

```swift
import Foundation
import Darwin

// MARK: - 文件操作抽象（spec §10：引擎可测性的关键）

public struct FileAttributes: Equatable, Sendable {
    public var isSymbolicLink: Bool
    public var isDirectory: Bool
    public var isRegularFile: Bool
    /// 逻辑大小（stat st_size；目录为 0，符号链接为链接路径长度）
    public var size: Int64
    /// 磁盘占用（st_blocks × 512，du 口径）。稀疏 / clonefile 文件以占用为准，避免 Docker.raw 这类
    /// 逻辑大小虚高到超过整盘的误导展示。
    public var allocatedSize: Int64
    public var modificationDate: Date?

    public init(isSymbolicLink: Bool, isDirectory: Bool, isRegularFile: Bool,
                size: Int64, allocatedSize: Int64? = nil, modificationDate: Date?) {
        self.isSymbolicLink = isSymbolicLink
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.size = size
        self.allocatedSize = allocatedSize ?? size
        self.modificationDate = modificationDate
    }
}

public enum FileOpError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case refuseSymlink(String)
    case posix(path: String, errno: Int32, context: String)

    public var description: String {
        switch self {
        case .notFound(let p): return "\(p) 不存在"
        case .refuseSymlink(let p): return "拒绝通过符号链接操作：\(p)"
        case .posix(let p, let e, let ctx): return "\(ctx) 失败：\(p)（errno \(e)）"
        }
    }
}

public protocol FileOperations: AnyObject {
    func homeDirectory() -> String

    /// lstat 语义：不解析符号链接；不存在返回 nil（坏链接返回其自身属性）。
    func attributesIfExist(atPath path: String) -> FileAttributes?
    func realPath(ofPath path: String) -> String?
    /// 直接子项的完整路径，按末段名排序。
    func childrenOfDirectory(atPath path: String) throws -> [String]
    /// lstat 语义的存在性（坏符号链接也算存在）。
    func fileExists(_ path: String) -> Bool

    /// 删除文件 / 符号链接（仅 unlink link 本身）/ 目录（递归，但目录内的符号链接同样只删链接）。
    func removeItem(atPath path: String) throws
    func moveItem(fromPath: String, toPath: String) throws
    func createDirectory(atPath path: String, intermediate: Bool) throws
    /// 清空文件内容。符号链接一律拒绝（truncate 会跟随链接改写目标，属于第 2 层围栏红线）。
    func truncateFile(atPath path: String) throws

    func writeFile(_ data: Data, toPath path: String) throws
    func readFile(atPath path: String) -> Data?
    /// 追加写入（审计日志用）；文件不存在则创建。
    func appendFile(_ data: Data, toPath path: String) throws

    /// 所在卷容量摘要；内存实现返回 nil。
    func volumeSummary(atPath path: String) -> DiskSummary?
}

extension FileOperations {
    /// 目录表观大小（du 口径）：递归累加文件磁盘占用；符号链接按 lstat 计，不跟随。
    func apparentSize(of path: String) -> Int64 {
        guard let attrs = attributesIfExist(atPath: path) else { return 0 }
        if !attrs.isDirectory || attrs.isSymbolicLink { return attrs.allocatedSize }
        var total: Int64 = 0
        var stack: [String] = [path]
        while let dir = stack.popLast() {
            guard let children = try? childrenOfDirectory(atPath: dir) else { continue }
            for child in children {
                guard let a = attributesIfExist(atPath: child) else { continue }
                if a.isDirectory && !a.isSymbolicLink {
                    stack.append(child)
                } else {
                    total += a.allocatedSize
                }
            }
        }
        return total
    }
}

// MARK: - 真实实现（lstat / realpath / unlink，绝不跟随符号链接删除）

public final class RealFileOperations: FileOperations {
    private let homeOverride: String?

    /// - Parameter home: 注入 home 供测试使用临时目录；默认取当前用户 home。
    public init(home: String? = nil) {
        self.homeOverride = home
    }

    public func homeDirectory() -> String { homeOverride ?? NSHomeDirectory() }

    private func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st
    }

    public func attributesIfExist(atPath path: String) -> FileAttributes? {
        guard let st = lstatInfo(path) else { return nil }
        let mode = st.st_mode
        let mtime = Date(timeIntervalSince1970:
            TimeInterval(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileAttributes(
            isSymbolicLink: (mode & S_IFMT) == S_IFLNK,
            isDirectory: (mode & S_IFMT) == S_IFDIR,
            isRegularFile: (mode & S_IFMT) == S_IFREG,
            size: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationDate: mtime)
    }

    public func realPath(ofPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func childrenOfDirectory(atPath path: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        return names.sorted().map { path.hasSuffix("/") ? path + $0 : path + "/" + $0 }
    }

    public func fileExists(_ path: String) -> Bool {
        lstatInfo(path) != nil
    }

    public func removeItem(atPath path: String) throws {
        // FileManager.removeItem 对符号链接只删链接本身，目录递归时同样不解析链接，符合第 4 层
        try FileManager.default.removeItem(atPath: path)
    }

    public func moveItem(fromPath: String, toPath: String) throws {
        try FileManager.default.moveItem(atPath: fromPath, toPath: toPath)
    }

    public func createDirectory(atPath path: String, intermediate: Bool) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: intermediate)
    }

    public func truncateFile(atPath path: String) throws {
        if let attrs = attributesIfExist(atPath: path), attrs.isSymbolicLink {
            throw FileOpError.refuseSymlink(path)
        }
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else {
            throw FileOpError.posix(path: path, errno: errno, context: "truncate")
        }
        close(fd)
    }

    public func writeFile(_ data: Data, toPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    public func readFile(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public func appendFile(_ data: Data, toPath path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try data.write(to: URL(fileURLWithPath: path))
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw FileOpError.posix(path: path, errno: errno, context: "append")
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func volumeSummary(atPath path: String) -> DiskSummary? {
        guard
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSummary(totalBytes: Int64(total), freeBytes: free)
    }
}

// MARK: - 内存实现（spec §10：单测用假文件树）

public final class InMemoryFileOperations: FileOperations {
    public struct Entry {
        public var isDirectory: Bool
        public var size: Int64
        public var modificationDate: Date
        public var symlinkTarget: String?
        public var content: Data?
    }

    private let home: String
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(home: String) {
        self.home = PathSafety.normalize(home, home: home)
        entries[self.home] = Entry(isDirectory: true, size: 0,
                                   modificationDate: Date(timeIntervalSince1970: 0),
                                   symlinkTarget: nil, content: nil)
    }

    public func homeDirectory() -> String { home }

    private func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // ---- 测试辅助：构造假文件树 ----

    @discardableResult
    public func makeDirectory(_ path: String) -> String {
        let p = PathSafety.normalize(path, home: home)
        var chain = p
        lock.lock(); defer { lock.unlock() }
        while chain != "/" && entries[chain] == nil {
            entries[chain] = Entry(isDirectory: true, size: 0,
                                   modificationDate: Date(timeIntervalSince1970: 0),
                                   symlinkTarget: nil, content: nil)
            chain = parent(of: chain)
        }
        return p
    }

    @discardableResult
    public func makeFile(_ path: String, size: Int64, modifiedAt: Date = Date(timeIntervalSince1970: 0),
                         content: Data? = nil) -> String {
        let p = PathSafety.normalize(path, home: home)
        _ = makeDirectory(parent(of: p))
        entries[p] = Entry(isDirectory: false, size: size, modificationDate: modifiedAt,
                           symlinkTarget: nil, content: content)
        return p
    }

    @discardableResult
    public func makeSymlink(at path: String, target: String) -> String {
        let p = PathSafety.normalize(path, home: home)
        _ = makeDirectory(parent(of: p))
        entries[p] = Entry(isDirectory: false, size: Int64(target.utf8.count),
                           modificationDate: Date(timeIntervalSince1970: 0),
                           symlinkTarget: target, content: nil)
        return p
    }

    public func allPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted()
    }

    public func entry(at path: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)]
    }

    // ---- FileOperations ----

    public func attributesIfExist(atPath path: String) -> FileAttributes? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[PathSafety.normalize(path, home: home)] else { return nil }
        return FileAttributes(isSymbolicLink: e.symlinkTarget != nil,
                              isDirectory: e.isDirectory && e.symlinkTarget == nil,
                              isRegularFile: !e.isDirectory && e.symlinkTarget == nil,
                              size: e.size,
                              modificationDate: e.modificationDate)
    }

    public func realPath(ofPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var current = PathSafety.normalize(path, home: home)
        var hops = 0
        while hops < 16 {
            guard let e = entries[current] else { return nil }
            guard let target = e.symlinkTarget else { return current }
            current = PathSafety.normalize(target, home: home)
            hops += 1
        }
        return nil
    }

    public func childrenOfDirectory(atPath path: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard let e = entries[p], e.isDirectory, e.symlinkTarget == nil else {
            throw FileOpError.notFound(p)
        }
        return entries.keys
            .filter { $0 != p && parent(of: $0) == p }
            .sorted()
    }

    public func fileExists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)] != nil
    }

    public func removeItem(atPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard entries[p] != nil else { throw FileOpError.notFound(p) }
        let prefix = p + "/"
        for key in entries.keys where key == p || key.hasPrefix(prefix) {
            entries.removeValue(forKey: key)
        }
    }

    public func moveItem(fromPath: String, toPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        let from = PathSafety.normalize(fromPath, home: home)
        let to = PathSafety.normalize(toPath, home: home)
        guard entries[from] != nil else { throw FileOpError.notFound(from) }
        guard entries[to] == nil else {
            throw FileOpError.posix(path: to, errno: Int32(EEXIST), context: "move 目标已存在")
        }
        let toParent = parent(of: to)
        if let pe = entries[toParent], !(pe.isDirectory && pe.symlinkTarget == nil) {
            throw FileOpError.posix(path: toParent, errno: Int32(ENOTDIR), context: "move 目标父级不是目录")
        }
        guard entries[toParent] != nil else { throw FileOpError.notFound(toParent) }
        let moved = entries.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
        for (key, value) in moved {
            entries.removeValue(forKey: key)
            entries[to + key.dropFirst(from.count)] = value
        }
    }

    public func createDirectory(atPath path: String, intermediate: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        if entries[p] != nil { return }
        let parentEntry = entries[parent(of: p)]
        if parentEntry == nil {
            guard intermediate || parent(of: p) == "/" else {
                throw FileOpError.posix(path: p, errno: Int32(ENOENT), context: "createDirectory")
            }
        }
        entries[p] = Entry(isDirectory: true, size: 0,
                           modificationDate: Date(timeIntervalSince1970: 0), symlinkTarget: nil)
    }

    public func truncateFile(atPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard var e = entries[p] else { throw FileOpError.notFound(p) }
        if e.symlinkTarget != nil { throw FileOpError.refuseSymlink(p) }
        e.size = 0
        e.content = Data() // 截断后仍是存在的 0 字节文件，readFile 应得到空 Data 而非 nil
        entries[p] = e
    }

    public func writeFile(_ data: Data, toPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        guard entries[p] != nil || entries[parent(of: p)] != nil else {
            throw FileOpError.posix(path: p, errno: Int32(ENOENT), context: "writeFile")
        }
        entries[p] = Entry(isDirectory: false, size: Int64(data.count),
                           modificationDate: Date(), symlinkTarget: nil, content: data)
    }

    public func readFile(atPath path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[PathSafety.normalize(path, home: home)]?.content
    }

    public func appendFile(_ data: Data, toPath path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let p = PathSafety.normalize(path, home: home)
        var existing = entries[p]?.content ?? Data()
        existing.append(data)
        entries[p] = Entry(isDirectory: false, size: Int64(existing.count),
                           modificationDate: Date(), symlinkTarget: nil, content: existing)
    }

    public func volumeSummary(atPath path: String) -> DiskSummary? { nil }
}
```

```swift
import XCTest
@testable import CleanerCore

/// spec §10：隔离往返、purge、命令委托等测试所依赖的文件层语义
final class FileOperationsTests: XCTestCase {
    private var root: String!

    override func setUp() {
        root = TestEnv.makeTempDir("dclean-files")
    }

    override func tearDown() {
        TestEnv.remove(root!)
        root = nil
    }

    // ---- 真实实现：符号链接语义（spec §5 第 4 层） ----

    func testRealRemoveSymlinkOnlyRemovesTheLink() throws {
        let target = root + "/target.txt"
        try TestEnv.write("precious", to: target)
        let link = root + "/nested/link"
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let files = RealFileOperations()
        try files.removeItem(atPath: link)

        XCTAssertFalse(files.fileExists(link))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "precious")
    }

    func testRealRemoveDirectoryDoesNotFollowSymlinksInside() throws {
        let outsideTarget = root + "/outside-target"
        try TestEnv.write("precious", to: outsideTarget)

        let dir = root + "/dir"
        try TestEnv.makeTree(root: dir, files: ["a.txt": "a", "sub/b.txt": "b"])
        try FileManager.default.createSymbolicLink(atPath: dir + "/sub/link",
                                                   withDestinationPath: outsideTarget)

        let files = RealFileOperations()
        try files.removeItem(atPath: dir)

        XCTAssertFalse(files.fileExists(dir))
        XCTAssertEqual(try String(contentsOfFile: outsideTarget, encoding: .utf8), "precious")
    }

    func testRealTruncateRefusesSymlink() throws {
        let target = root + "/target.txt"
        try TestEnv.write("precious", to: target)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let files = RealFileOperations()
        XCTAssertThrowsError(try files.truncateFile(atPath: link)) { error in
            guard case FileOpError.refuseSymlink = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "precious")
    }

    func testRealTruncateEmptiesRegularFile() throws {
        let file = root + "/deep/path/log.txt"
        try TestEnv.makeTree(root: root, files: ["deep/path/log.txt": "0123456789"])
        let files = RealFileOperations()
        try files.truncateFile(atPath: file)
        XCTAssertEqual(files.attributesIfExist(atPath: file)?.size, 0)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "")
    }

    func testRealAttributesUseLstatSemantics() throws {
        let target = root + "/t.txt"
        try TestEnv.write("12345", to: target)
        let link = root + "/l.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let files = RealFileOperations()

        let linkAttrs = try XCTUnwrap(files.attributesIfExist(atPath: link))
        XCTAssertTrue(linkAttrs.isSymbolicLink)
        XCTAssertFalse(linkAttrs.isDirectory)
        XCTAssertTrue(files.fileExists(link))

        try FileManager.default.createSymbolicLink(atPath: root + "/broken", withDestinationPath: "/nonexistent-xyz")
        XCTAssertTrue(files.fileExists(root + "/broken")) // 坏链接 lstat 仍存在
        XCTAssertNil(files.realPath(ofPath: root + "/broken"))
    }

    func testRealMoveAndChildren() throws {
        try TestEnv.makeTree(root: root, files: ["a/2.txt": "2", "a/1.txt": "1", "b/.keep": ""])
        let files = RealFileOperations()
        XCTAssertEqual(try files.childrenOfDirectory(atPath: root + "/a"),
                       [root + "/a/1.txt", root + "/a/2.txt"])
        try files.moveItem(fromPath: root + "/a/1.txt", toPath: root + "/b/1.txt")
        XCTAssertTrue(files.fileExists(root + "/b/1.txt"))
        XCTAssertFalse(files.fileExists(root + "/a/1.txt"))
    }

    func testRealVolumeSummary() {
        let files = RealFileOperations()
        let summary = files.volumeSummary(atPath: root)
        XCTAssertNotNil(summary)
        XCTAssertGreaterThan(summary!.totalBytes, 0)
    }

    func testRealAllocatedSizeIsReported() throws {
        // 稀疏大文件的逻辑大小会虚高（如 Docker.raw 标称 460G），报告必须用磁盘占用口径
        let file = root + "/f.bin"
        FileManager.default.createFile(atPath: file, contents: Data())
        let files = RealFileOperations()
        let attrs = try XCTUnwrap(files.attributesIfExist(atPath: file))
        XCTAssertEqual(attrs.size, 0)
        XCTAssertGreaterThanOrEqual(attrs.allocatedSize, 0)
        // 有内容的文件，占用 >= 逻辑大小所在块
        try TestEnv.write("0123456789", to: root + "/g.bin")
        let g = try XCTUnwrap(files.attributesIfExist(atPath: root + "/g.bin"))
        XCTAssertGreaterThan(g.allocatedSize, 0)
        XCTAssertEqual(g.size, 10)
    }

    // ---- 内存实现：等价语义（spec §10：单测用内存假文件树） ----

    func testInMemoryTreeAndSubtreeRemoval() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/data/store/a.txt", size: 3)
        mem.makeFile("/Users/t/data/store/sub/b.txt", size: 5)
        mem.makeFile("/Users/t/data/keep.txt", size: 1)

        XCTAssertEqual(mem.apparentSize(of: "/Users/t/data/store"), 8)
        try mem.removeItem(atPath: "/Users/t/data/store")
        XCTAssertFalse(mem.fileExists("/Users/t/data/store"))
        XCTAssertFalse(mem.fileExists("/Users/t/data/store/sub/b.txt"))
        XCTAssertTrue(mem.fileExists("/Users/t/data/keep.txt"))
    }

    func testInMemorySymlinkAndRealPath() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/outside.txt", size: 7)
        mem.makeSymlink(at: "/Users/t/data/link", target: "/Users/t/outside.txt")

        let attrs = try XCTUnwrap(mem.attributesIfExist(atPath: "/Users/t/data/link"))
        XCTAssertTrue(attrs.isSymbolicLink)
        XCTAssertEqual(mem.realPath(ofPath: "/Users/t/data/link"), "/Users/t/outside.txt")
        // 只删链接
        try mem.removeItem(atPath: "/Users/t/data/link")
        XCTAssertTrue(mem.fileExists("/Users/t/outside.txt"))
        XCTAssertNil(mem.entry(at: "/Users/t/data/link"))
    }

    func testInMemoryMoveRenamesSubtree() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/a/x.txt", size: 1)
        mem.makeFile("/Users/t/a/sub/y.txt", size: 2)
        mem.makeDirectory("/Users/t/b")

        try mem.moveItem(fromPath: "/Users/t/a", toPath: "/Users/t/b/a")
        XCTAssertTrue(mem.fileExists("/Users/t/b/a/x.txt"))
        XCTAssertTrue(mem.fileExists("/Users/t/b/a/sub/y.txt"))
        XCTAssertFalse(mem.fileExists("/Users/t/a"))
        // 目标已存在应报错
        XCTAssertThrowsError(try mem.moveItem(fromPath: "/Users/t/b/a", toPath: "/Users/t/b"))
    }

    func testInMemoryReadWriteAppend() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        try mem.writeFile(Data("line1\n".utf8), toPath: "/Users/t/log")
        try mem.appendFile(Data("line2\n".utf8), toPath: "/Users/t/log")
        XCTAssertEqual(mem.readFile(atPath: "/Users/t/log"), Data("line1\nline2\n".utf8))
        // truncate 后为 0 字节
        try mem.truncateFile(atPath: "/Users/t/log")
        XCTAssertEqual(mem.readFile(atPath: "/Users/t/log"), Data())
        // 符号链接拒绝 truncate
        mem.makeSymlink(at: "/Users/t/link", target: "/Users/t/log")
        XCTAssertThrowsError(try mem.truncateFile(atPath: "/Users/t/link"))
    }
}
```

## 任务 5：ProcessRunner + GuardEvaluator（第 6 层）

`lsof -F pcn0 -- <path>`（NUL 分隔防路径含空格）查锁持有者；`pgrep -x` 查进程。lsof 不可用视为 clear，由 command 策略自身失败兜底，不误报占用。

```swift
import Foundation

// MARK: - 进程执行抽象（guard 与 command 策略的单测注入点）

public struct ProcessResult: Equatable, Sendable {
    public var exitStatus: Int32
    public var stdout: String
    public var stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: AnyObject {
    /// launchPath 必须是完整路径；返回进程结果，启动失败（可执行文件不存在等）返回 nil。
    func run(launchPath: String, arguments: [String]) -> ProcessResult?
}

public final class RealProcessRunner: ProcessRunner {
    public init() {}

    public func run(launchPath: String, arguments: [String]) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // lsof/pgrep 及清理命令输出都很小；先读 stderr 再读 stdout，避免极端情况下管道写满阻塞
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

public enum ExecutableLocator {
    /// 按 PATH 解析裸命令名（launchd 环境下 PATH 可能不全，找不到返回原名由调用方报错）。
    public static func resolve(_ command: String, path env: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        guard !command.contains("/") else { return command }
        guard let env, !env.isEmpty else { return command }
        for dir in env.split(separator: ":") {
            let candidate = dir + "/" + command
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return command
    }
}
```

```swift
import Foundation

// MARK: - 占用守卫评估（spec §5 第 6 层）

/// lockfile 守卫：lsof 查锁文件持有者；process 守卫：pgrep 查进程是否运行中。
/// 评估不通过 → 该项 blocked，UI 禁用勾选，执行时跳过。无绕过入口。
public final class GuardEvaluator {
    private let files: FileOperations
    private let runner: ProcessRunner

    public init(files: FileOperations, runner: ProcessRunner) {
        self.files = files
        self.runner = runner
    }

    public static let lsofPath = "/usr/sbin/lsof"
    public static let pgrepPath = "/usr/bin/pgrep"

    /// 合并一条规则所有守卫：全部 clear 才 clear。
    public func status(of guards: [GuardSpec], home: String) -> GuardStatus {
        var all: [Occupier] = []
        for g in guards {
            switch evaluate(g, home: home) {
            case .clear:
                continue
            case .blocked(let occupiers):
                all.append(contentsOf: occupiers)
            }
        }
        return all.isEmpty ? .clear : .blocked(all)
    }

    public func evaluate(_ guardSpec: GuardSpec, home: String) -> GuardStatus {
        switch guardSpec.type {
        case .lockfile:
            return evaluateLockfile(guardSpec, home: home)
        case .process:
            return evaluateProcess(guardSpec)
        }
    }

    private func evaluateLockfile(_ guardSpec: GuardSpec, home: String) -> GuardStatus {
        guard let rawPath = guardSpec.path else { return .clear }
        let path = PathSafety.normalize(rawPath, home: home)
        // 锁文件不存在 → 无人持有
        guard files.fileExists(path) else { return .clear }
        // -F pcn0：以 NUL 分隔输出 pid(p)、命令名(c)、文件名(n)；-- 结束选项防路径被当参数
        guard let result = runner.run(launchPath: Self.lsofPath, arguments: ["-F", "pcn0", "--", path]) else {
            // lsof 不可用属于环境缺失；为不误报占用，视为 clear，但由 command 策略自身的失败兜底
            return .clear
        }
        let occupiers = parseLsofFields(result.stdout)
        return occupiers.isEmpty ? .clear : .blocked(occupiers)
    }

    /// 解析 `lsof -F pcn0` 输出：记录集以 p 开头，p 后跟 pid，c 后跟命令名。
    func parseLsofFields(_ output: String) -> [Occupier] {
        var occupiers: [Occupier] = []
        var currentPID: Int32?
        var currentCommand: String?
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let first = record.first else { continue }
            let value = String(record.dropFirst())
            switch first {
            case "p":
                currentPID = Int32(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "n":
                if let pid = currentPID {
                    occupiers.append(Occupier(pid: pid, command: currentCommand ?? "?"))
                }
                currentPID = nil
                currentCommand = nil
            default:
                continue
            }
        }
        // 去重（同一进程可能持有多把锁/多个 fd）
        var seen = Set<String>()
        return occupiers.filter { seen.insert($0.description).inserted }
    }

    private func evaluateProcess(_ guardSpec: GuardSpec) -> GuardStatus {
        guard let name = guardSpec.process, !name.isEmpty else { return .clear }
        guard let result = runner.run(launchPath: Self.pgrepPath, arguments: ["-x", name]) else {
            return .clear
        }
        guard result.exitStatus == 0 else { return .clear }
        let pids = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        guard !pids.isEmpty else { return .clear }
        return .blocked(pids.map { Occupier(pid: $0, command: name) })
    }
}
```

```swift
import XCTest
@testable import CleanerCore

/// spec §10：guard 用例（层 6）
final class GuardEvaluatorTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var runner: FakeProcessRunner!
    private var evaluator: GuardEvaluator!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-guards")
        files = RealFileOperations()
        runner = FakeProcessRunner()
        evaluator = GuardEvaluator(files: files, runner: runner)
    }

    override func tearDown() {
        TestEnv.remove(root!)
    }

    func testLockfileMissingMeansClear() {
        let guardSpec = GuardSpec(type: .lockfile, path: root + "/.lock")
        let status = evaluator.evaluate(guardSpec, home: root)
        XCTAssertEqual(status, .clear)
        XCTAssertEqual(runner.calls.count, 0) // 锁不存在，不启动 lsof
    }

    func testLockfileHeldByProcessIsBlocked() throws {
        let lock = root + "/.cache/uv/.lock"
        try TestEnv.makeTree(root: root, files: { () -> [String: String] in
            var f = [String: String]()
            f[".cache/uv/.lock"] = ""
            return f
        }())
        runner.handler = { launchPath, args in
            XCTAssertEqual(launchPath, GuardEvaluator.lsofPath)
            XCTAssertTrue(args.contains("--"))
            return ProcessResult(exitStatus: 0,
                                 stdout: "p123\0cchroma-mcp\0n\(lock)\0p123\0cchroma-mcp\0n\(lock)\0",
                                 stderr: "")
        }
        let status = evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 123, command: "chroma-mcp")])) // 同进程去重
    }

    func testLockfileWithNoHolderIsClear() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { _, _ in ProcessResult(exitStatus: 1, stdout: "", stderr: "") } // lsof 无持有者
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root), .clear)
    }

    func testLsofFieldParsing() {
        let output = "p10\0ccodex\0n/a\0p20\0cChrome Helper\0n/b\0junk\0"
        let occupiers = evaluator.parseLsofFields(output)
        XCTAssertEqual(occupiers, [Occupier(pid: 10, command: "codex"),
                                   Occupier(pid: 20, command: "Chrome Helper")])
        XCTAssertTrue(evaluator.parseLsofFields("").isEmpty)
    }

    func testProcessGuardBlockedWhenRunning() {
        runner.handler = { launchPath, args in
            XCTAssertEqual(launchPath, GuardEvaluator.pgrepPath)
            XCTAssertEqual(args, ["-x", "docker-daemon"])
            return ProcessResult(exitStatus: 0, stdout: "99\n100\n", stderr: "")
        }
        let status = evaluator.evaluate(GuardSpec(type: .process, process: "docker-daemon"), home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 99, command: "docker-daemon"),
                                         Occupier(pid: 100, command: "docker-daemon")]))
    }

    func testProcessGuardClearWhenNotRunning() {
        runner.handler = { _, _ in ProcessResult(exitStatus: 1, stdout: "", stderr: "") }
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .process, process: "docker-daemon"), home: root), .clear)
    }

    func testCombinedGuardsAnyBlockBlocksAll() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { launchPath, _ in
            launchPath == GuardEvaluator.pgrepPath
                ? ProcessResult(exitStatus: 1, stdout: "", stderr: "")
                : ProcessResult(exitStatus: 0, stdout: "p7\0cholder\0n\(lock)\0", stderr: "")
        }
        let status = evaluator.status(of: [GuardSpec(type: .process, process: "something"),
                                           GuardSpec(type: .lockfile, path: lock)],
                                      home: root)
        XCTAssertEqual(status, .blocked([Occupier(pid: 7, command: "holder")]))
    }

    func testLsofUnavailableTreatedAsClear() {
        let lock = root + "/.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        runner.handler = { _, _ in nil }
        XCTAssertEqual(evaluator.evaluate(GuardSpec(type: .lockfile, path: lock), home: root), .clear)
    }
}
```

## 任务 6：Scanner

仅遍历规则 roots；glob 编译为锚定正则（`**` 跨目录、`*`/`?` 不跨）；目录命中 glob 即整体为候选并停止下钻；符号链接永不下钻；olderThanDays=0 表示不限年龄。大小口径统一为磁盘占用（st_blocks，du 口径）——Docker.raw 这类稀疏文件逻辑大小 460G、实际占用 20.7G。

```swift
import Foundation

// MARK: - 扫描器（spec §3、§9：仅遍历规则声明的 roots，非全盘遍历，秒级）

public final class Scanner {
    private let files: FileOperations
    private let safety: PathSafety

    public init(files: FileOperations, safety: PathSafety) {
        self.files = files
        self.safety = safety
    }

    /// 纯只读：不写任何文件。purge 由 CLI 的 scan 子命令在调用本方法前完成。
    public func scan(rules: [Rule], now: Date = Date()) -> Report {
        let home = files.homeDirectory()
        let entries = rules.map { entry(for: $0, now: now) }
        let report = Report(
            generatedAt: now,
            home: home,
            disk: files.volumeSummary(atPath: home),
            entries: entries)
        return report
    }

    // MARK: 单规则扫描

    private func entry(for rule: Rule, now: Date) -> ReportEntry {
        let base = ReportEntry(
            ruleId: rule.id, ruleName: rule.name, risk: rule.risk,
            strategyType: rule.strategy.type, sizeBytes: 0, candidateCount: 0,
            candidates: [], status: .ok, explain: rule.explain)

        if let configError = rule.strategy.validate() {
            var e = base
            e.status = .configError(configError)
            return e
        }
        if !Strategy.isCompatible(risk: rule.risk, type: rule.strategy.type) {
            var e = base
            e.status = .configError("风险等级与策略不兼容（黄色只能配 delete-dir / glob-age）")
            return e
        }

        let roots = rule.roots.map { safety.normalize($0) }
        let existing = roots.filter { files.fileExists($0) }
        if existing.isEmpty {
            var e = base
            e.status = .rootsMissing
            return e
        }

        switch rule.strategy.type {
        case .command:
            // 委托命令无法预知可回收量；以 roots 表观大小作近似展示
            var e = base
            e.sizeBytes = existing.reduce(Int64(0)) { $0 + self.files.apparentSize(of: $1) }
            return e

        case .deleteDir:
            var e = base
            e.candidates = existing
            e.candidateCount = existing.count
            e.sizeBytes = existing.reduce(Int64(0)) { $0 + self.files.apparentSize(of: $1) }
            return e

        case .truncate:
            var e = base
            e.candidates = existing
            e.candidateCount = existing.count
            e.sizeBytes = existing.reduce(Int64(0)) {
                $0 + (self.files.attributesIfExist(atPath: $1)?.allocatedSize ?? 0)
            }
            return e

        case .globAge:
            guard let glob = rule.strategy.glob,
                  let regex = Self.compileGlob(safety.expandTilde(glob)) else {
                var e = base
                e.status = .configError("glob 模式无法编译")
                return e
            }
            // olderThanDays 为 0 表示不限年龄
            let cutoff = (rule.strategy.olderThanDays.flatMap { $0 > 0 ? $0 : nil })
                .map { now.addingTimeInterval(-Double($0) * 86_400) }
            var candidates: [(path: String, size: Int64)] = []
            for root in existing {
                collectMatches(under: root, regex: regex, cutoff: cutoff, now: now, into: &candidates)
            }
            var e = base
            e.candidates = candidates.map(\.path)
            e.candidateCount = candidates.count
            e.sizeBytes = candidates.reduce(Int64(0)) { $0 + $1.size }
            return e
        }
    }

    // MARK: glob 与遍历

    /// glob → 锚定正则：`**` 跨目录段，`*`、`?` 不跨 `/`。
    static func compileGlob(_ glob: String) -> NSRegularExpression? {
        var pattern = "^"
        var iterator = glob.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case "*":
                if iterator.next() == "*" {
                    pattern += ".*"
                } else {
                    pattern += "[^/]*"
                }
            case "?":
                pattern += "[^/]"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern)
    }

    private func passesAge(_ attrs: FileAttributes, cutoff: Date?, now: Date) -> Bool {
        guard let cutoff else { return true }
        guard let mtime = attrs.modificationDate else { return false }
        return mtime < cutoff
    }

    /// 深度优先；目录自身命中 glob 即整体作为一个候选并停止下钻；符号链接只作为叶候选，绝不下钻（spec §5 第 4 层）。
    private func collectMatches(under path: String, regex: NSRegularExpression, cutoff: Date?, now: Date,
                                into candidates: inout [(path: String, size: Int64)]) {
        guard let attrs = files.attributesIfExist(atPath: path) else { return }
        let range = NSRange(path.startIndex..., in: path)
        let matches = regex.firstMatch(in: path, range: range) != nil
        if matches, passesAge(attrs, cutoff: cutoff, now: now) {
            let size = attrs.isDirectory ? files.apparentSize(of: path) : attrs.allocatedSize
            candidates.append((path, size))
            return
        }
        guard attrs.isDirectory, !attrs.isSymbolicLink,
              let children = try? files.childrenOfDirectory(atPath: path) else { return }
        for child in children {
            collectMatches(under: child, regex: regex, cutoff: cutoff, now: now, into: &candidates)
        }
    }
}

// MARK: - 磁盘字节的人类可读格式

public enum ByteFormatting {
    public static func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units: [(String, Int64)] = [("B", 1), ("KB", 1 << 10), ("MB", 1 << 20), ("GB", 1 << 30), ("TB", 1 << 40)]
        var name = "B"
        var factor: Int64 = 1
        for unit in units where bytes >= unit.1 {
            name = unit.0
            factor = unit.1
        }
        let value = Double(bytes) / Double(factor)
        if factor == 1 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, name)
    }

    /// 按 East Asian Width 计算显示宽度（CJK 全角算 2），供终端对齐。
    public static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { width, scalar in
            width + ((0x2E80...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) ? 2 : 1)
        }
    }

    public static func padded(_ s: String, to width: Int) -> String {
        let w = displayWidth(s)
        return w >= width ? s : s + String(repeating: " ", count: width - w)
    }
}
```

```swift
import XCTest
@testable import CleanerCore

/// spec §10：四类策略的扫描、符号链接不下钻、缺根、JSON 可解析
final class ScannerTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var safety: PathSafety!
    private var scanner: CleanerCore.Scanner!
    private var now: Date!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-scan")
        files = RealFileOperations()
        safety = PathSafety(home: root, files: files)
        scanner = Scanner(files: files, safety: safety)
        now = Date()
    }

    override func tearDown() {
        TestEnv.remove(root!)
    }

    private func rule(id: String, risk: RiskLevel, roots: [String],
                      strategy: Strategy, guards: [GuardSpec]? = nil) -> Rule {
        Rule(id: id, name: id, risk: risk, roots: roots, strategy: strategy,
             guards: guards, explain: "测试规则 \(id)")
    }

    func testDeleteDirReportsSizeAndCandidates() throws {
        let store = root + "/data/store"
        try TestEnv.makeTree(root: root, files: ["data/store/a.txt": "123", "data/store/sub/b.txt": "12345"])
        let r = rule(id: "store", risk: .green, roots: ["~/data/store"], strategy: Strategy(type: .deleteDir))
        let report = scanner.scan(rules: [r], now: now)

        XCTAssertEqual(report.entries.count, 1)
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(entry.status, .ok)
        XCTAssertEqual(entry.candidates, [store])
        XCTAssertEqual(entry.sizeBytes, 8192) // 两个文件各占一个 4K 块
        XCTAssertEqual(report.entries(withRisk: .green).reduce(0) { $0 + $1.sizeBytes }, 8192)
    }

    func testGlobAgeFiltersByMTimeAndGlob() throws {
        try TestEnv.makeTree(root: root, files: [
            "logs/old.log": "old",
            "logs/new.log": "new",
            "logs/old.txt": "ignored-by-glob",
            "logs/sub/older.log": "nested-not-matched-by-single-star",
        ])
        try TestEnv.setMTime(root + "/logs/old.log", TestEnv.daysAgo(10, from: now))
        try TestEnv.setMTime(root + "/logs/new.log", now)
        try TestEnv.setMTime(root + "/logs/old.txt", TestEnv.daysAgo(10, from: now))
        try TestEnv.setMTime(root + "/logs/sub/older.log", TestEnv.daysAgo(10, from: now))

        let r = rule(id: "logs", risk: .green, roots: ["~/logs"],
                     strategy: Strategy(type: .globAge, glob: "~/logs/*.log", olderThanDays: 7))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)

        XCTAssertEqual(entry.candidates, [root + "/logs/old.log"])
        XCTAssertEqual(entry.sizeBytes, 4096)
    }

    func testGlobAgeMatchesOldDirectoriesAsWhole() throws {
        try TestEnv.makeTree(root: root, files: ["jb/old-idea/index/file": "abcdef"])
        try TestEnv.setMTime(root + "/jb/old-idea", TestEnv.daysAgo(100, from: now))

        let r = rule(id: "jb", risk: .yellow, roots: ["~/jb"],
                     strategy: Strategy(type: .globAge, glob: "~/jb/*", olderThanDays: 90))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)

        XCTAssertEqual(entry.candidates, [root + "/jb/old-idea"])
        XCTAssertEqual(entry.sizeBytes, 4096) // 整目录 du 口径
    }

    func testSymlinkInsideRootIsLeafCandidateAndNeverDescended() throws {
        let outside = root + "/outside"
        try TestEnv.makeTree(root: root, files: ["outside/deep/file": "0123456789"])
        let link = root + "/symroot/dirlink"
        try TestEnv.makeTree(root: root, files: ["symroot/real.txt": "123"])
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let r = rule(id: "sym", risk: .green, roots: ["~/symroot"], strategy: Strategy(type: .deleteDir))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)

        // du 口径：real.txt 的占用块 + 链接自身的占用块（APFS 链接内联存储，占块常为 0）；不含 outside 内容
        let expected = (files.attributesIfExist(atPath: root + "/symroot/real.txt")?.allocatedSize ?? 0)
            + (files.attributesIfExist(atPath: link)?.allocatedSize ?? 0)
        XCTAssertEqual(entry.sizeBytes, expected)
        XCTAssertLessThan(entry.sizeBytes, 100_000) // 远小于 outside 的内容量级，证明未下钻
        // glob 场景：链接本身可以是候选，但绝不产出 outside 下的路径
        let globRule = rule(id: "sym2", risk: .green, roots: ["~/symroot"],
                            strategy: Strategy(type: .globAge, glob: "~/symroot/**", olderThanDays: 0))
        let globEntry = try XCTUnwrap(scanner.scan(rules: [globRule], now: now).entries.first)
        XCTAssertFalse(globEntry.candidates.contains { $0.hasPrefix(outside) })
        XCTAssertTrue(globEntry.candidates.contains(link))
    }

    func testMissingRootsReportedAndZeroSized() {
        let r = rule(id: "ghost", risk: .green, roots: ["~/no-such-dir"], strategy: Strategy(type: .deleteDir))
        let entry = scanner.scan(rules: [r], now: now).entries.first
        let e = entry ?? ReportEntry(ruleId: "?", ruleName: "?", risk: .green, strategyType: .deleteDir,
                                     sizeBytes: -1, candidateCount: 0, candidates: [],
                                     status: .ok, explain: "")
        XCTAssertEqual(e.status, .rootsMissing)
        XCTAssertEqual(e.sizeBytes, 0)
        XCTAssertEqual(e.candidates, [])
    }

    func testCommandRuleApproximatesByRootSize() throws {
        try TestEnv.makeTree(root: root, files: ["cache/blob": "0123456789"])
        let r = rule(id: "cmd", risk: .green, roots: ["~/cache"],
                     strategy: Strategy(type: .command, cmd: ["uv", "cache", "prune"]))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)
        XCTAssertEqual(entry.status, .ok)
        XCTAssertEqual(entry.sizeBytes, 4096)
        XCTAssertEqual(entry.candidates, [])
    }

    func testRedRuleReportsSizeOnly() throws {
        try TestEnv.makeTree(root: root, files: ["big/Docker.raw": "0123456789"])
        let r = rule(id: "docker", risk: .red, roots: ["~/big"], strategy: Strategy(type: .deleteDir))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)
        XCTAssertEqual(entry.status, .ok)
        XCTAssertEqual(entry.sizeBytes, 4096)
    }

    func testIncompatibleRiskStrategyIsConfigError() {
        let r = rule(id: "bad", risk: .yellow,
                     roots: ["~/x"], strategy: Strategy(type: .command, cmd: ["docker", "image", "prune"]))
        let entry = scanner.scan(rules: [r], now: now).entries.first
        XCTAssertNotNil(entry)
        guard case .configError = entry!.status else { return XCTFail("应为配置错误") }
    }

    func testTruncateRuleCandidateIsFile() throws {
        try TestEnv.makeTree(root: root, files: ["var/log.txt": "0123456789"])
        let r = rule(id: "trunc", risk: .green, roots: ["~/var/log.txt"], strategy: Strategy(type: .truncate))
        let entry = try XCTUnwrap(scanner.scan(rules: [r], now: now).entries.first)
        XCTAssertEqual(entry.candidates, [root + "/var/log.txt"])
        XCTAssertEqual(entry.sizeBytes, 4096)
    }

    func testHumanByteFormatting() {
        XCTAssertEqual(ByteFormatting.human(0), "0 B")
        XCTAssertEqual(ByteFormatting.human(512), "512 B")
        XCTAssertEqual(ByteFormatting.human(1 << 10), "1.0 KB")
        XCTAssertEqual(ByteFormatting.human(3 * (1 << 30) + 100), "3.0 GB")
        XCTAssertEqual(ByteFormatting.human(21 * (1 << 30)), "21.0 GB")
        XCTAssertFalse(ByteFormatting.human(0).contains("nan"))
        // 对齐宽度按 CJK 双宽计算
        XCTAssertEqual(ByteFormatting.displayWidth("uv 缓存"), 7)
        XCTAssertGreaterThan(ByteFormatting.displayWidth("pip 缓存"), ByteFormatting.displayWidth("abc"))
    }

    func testReportJSONRoundTrip() throws {
        try TestEnv.makeTree(root: root, files: ["data/x": "abc"])
        let rules = [
            rule(id: "store", risk: .green, roots: ["~/data"], strategy: Strategy(type: .deleteDir)),
            rule(id: "bad", risk: .yellow, roots: ["~/data2"],
                 strategy: Strategy(type: .command, cmd: ["x"])),
        ]
        // ISO8601 为秒级精度，用整秒时间戳保证完整往返等价
        let wholeSecond = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let report = scanner.scan(rules: rules, now: TestEnv.daysAgo(1, from: wholeSecond))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Report.self, from: data)
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.entries.count, 2)
    }
}
```

## 任务 7：隔离区

批次目录 `~/.dclean/quarantine/<id>/`，storedName 带序号前缀天然无冲突；manifest.json 记录原路径映射；restore 冲突时保留批次只重写 manifest；purge 以 manifest 的 createdAt 为准，无法解析的目录一律不动。

```swift
import Foundation

// MARK: - 隔离区（spec §7）

public struct QuarantineManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var originalPath: String
        public var storedPath: String
        public var sizeBytes: Int64

        public init(originalPath: String, storedPath: String, sizeBytes: Int64) {
            self.originalPath = originalPath
            self.storedPath = storedPath
            self.sizeBytes = sizeBytes
        }
    }

    public var batchID: String
    public var createdAt: Date
    public var entries: [Entry]

    public init(batchID: String, createdAt: Date, entries: [Entry]) {
        self.batchID = batchID
        self.createdAt = createdAt
        self.entries = entries
    }
}

public enum QuarantineError: Error, CustomStringConvertible {
    case batchNotFound(String)
    case manifestUnreadable(String)

    public var description: String {
        switch self {
        case .batchNotFound(let id): return "隔离批次不存在：\(id)"
        case .manifestUnreadable(let path): return "manifest 无法读取：\(path)"
        }
    }
}

/// 单个隔离批次：逐条移入，结束时写 manifest.json。
public final class QuarantineBatch {
    public let id: String
    public let directory: String
    private let files: FileOperations
    private var entries: [QuarantineManifest.Entry] = []
    private var finished = false

    init(id: String, root: String, files: FileOperations) throws {
        self.id = id
        self.directory = root + "/" + id
        self.files = files
        try files.createDirectory(atPath: directory, intermediate: true)
    }

    /// 把目标移入批次目录。storedName 带序号前缀，天然无冲突；还原映射以 manifest 为准。
    public func admit(originalPath: String, sizeBytes: Int64) throws {
        let name = "\((originalPath as NSString).lastPathComponent)"
        let storedPath = directory + "/" + String(format: "%04d-", entries.count) + name
        try files.moveItem(fromPath: originalPath, toPath: storedPath)
        entries.append(QuarantineManifest.Entry(originalPath: originalPath, storedPath: storedPath, sizeBytes: sizeBytes))
    }

    public func finalize(now: Date = Date()) throws -> QuarantineManifest {
        guard !finished else {
            return QuarantineManifest(batchID: id, createdAt: now, entries: entries)
        }
        finished = true
        let manifest = QuarantineManifest(batchID: id, createdAt: now, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try files.writeFile(data, toPath: directory + "/manifest.json")
        return manifest
    }
}

public final class QuarantineStore {
    public let root: String
    private let files: FileOperations

    public init(root: String, files: FileOperations) {
        self.root = root
        self.files = files
    }

    public func beginBatch(id: String) throws -> QuarantineBatch {
        try QuarantineBatch(id: id, root: root, files: files)
    }

    public func listBatches() -> [QuarantineManifest] {
        guard let children = try? files.childrenOfDirectory(atPath: root) else { return [] }
        return children.compactMap { manifestOf(batchDir: $0) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func occupiedBytes() -> Int64 {
        listBatches().reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.sizeBytes } }
    }

    /// 按 manifest 逐条还原。目标已存在 → 该条报错跳过；全部成功后删除批次目录。
    public func restore(batchID: String) -> (restored: [String], errors: [String]) {
        let batchDir = root + "/" + batchID
        guard let manifest = manifestOf(batchDir: batchDir) else {
            return ([], files.fileExists(batchDir)
                    ? [QuarantineError.manifestUnreadable(batchDir + "/manifest.json").description]
                    : [QuarantineError.batchNotFound(batchID).description])
        }
        var restored: [String] = []
        var errors: [String] = []
        var remaining: [QuarantineManifest.Entry] = []
        for entry in manifest.entries {
            do {
                if files.fileExists(entry.originalPath) {
                    errors.append("还原失败：\(entry.originalPath) 已被占用（存在同名路径），跳过")
                    remaining.append(entry)
                    continue
                }
                let parent = (entry.originalPath as NSString).deletingLastPathComponent
                try files.createDirectory(atPath: parent, intermediate: true)
                try files.moveItem(fromPath: entry.storedPath, toPath: entry.originalPath)
                restored.append(entry.originalPath)
            } catch {
                errors.append("还原失败：\(entry.originalPath)（\(error)）")
                remaining.append(entry)
            }
        }
        if remaining.isEmpty {
            try? files.removeItem(atPath: batchDir)
        } else {
            rewriteManifest(manifest: QuarantineManifest(batchID: batchID, createdAt: manifest.createdAt, entries: remaining),
                            batchDir: batchDir)
        }
        return (restored, errors)
    }

    /// 清除超过 N 天的批次（以 manifest 的 createdAt 为准）。无法解析的目录一律不动。
    public func purge(olderThanDays days: Int, now: Date) -> (purged: [String], skippedUnknown: [String]) {
        guard let children = try? files.childrenOfDirectory(atPath: root) else { return ([], []) }
        var purged: [String] = []
        var skipped: [String] = []
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for batchDir in children {
            if let manifest = manifestOf(batchDir: batchDir) {
                if manifest.createdAt < cutoff {
                    try? files.removeItem(atPath: batchDir)
                    purged.append(manifest.batchID)
                }
            } else {
                skipped.append(batchDir)
            }
        }
        return (purged, skipped)
    }

    // MARK: manifest 读写

    private func manifestPath(batchDir: String) -> String { batchDir + "/manifest.json" }

    private func manifestOf(batchDir: String) -> QuarantineManifest? {
        guard let data = files.readFile(atPath: manifestPath(batchDir: batchDir)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QuarantineManifest.self, from: data)
    }

    private func rewriteManifest(manifest: QuarantineManifest, batchDir: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? files.writeFile(data, toPath: manifestPath(batchDir: batchDir))
        }
    }
}
```

```swift
import XCTest
@testable import CleanerCore

/// spec §10：隔离往返、名称冲突还原、purge 年龄
final class QuarantineTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var store: QuarantineStore!
    private var quarantineRoot: String!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-quarantine")
        files = RealFileOperations()
        quarantineRoot = root + "/.dclean/quarantine"
        store = QuarantineStore(root: quarantineRoot, files: files)
    }

    override func tearDown() {
        TestEnv.remove(root!)
    }

    func testRoundTripRestoresBytesExactly() throws {
        // spec §10：文件 → quarantine → restore，路径与内容逐字节一致
        let content = Data("会话内容 \u{1F600} binary-safe".utf8)
        let original = root + "/data/sessions"
        try TestEnv.makeTree(root: root, files: ["data/sessions/2026-01/session.json": "s1",
                                                 "data/sessions/2026-02/session.json": "s2"])
        try content.write(to: URL(fileURLWithPath: original + "/blob.bin"))

        let batch = try store.beginBatch(id: "q-test")
        try batch.admit(originalPath: original, sizeBytes: 100)
        try batch.finalize(now: Date())

        XCTAssertFalse(files.fileExists(original))
        XCTAssertEqual(store.listBatches().count, 1)

        let (restored, errors) = store.restore(batchID: "q-test")
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(restored, [original])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original + "/blob.bin")), content)
        XCTAssertEqual(try String(contentsOfFile: original + "/2026-01/session.json", encoding: .utf8), "s1")
        XCTAssertFalse(files.fileExists(quarantineRoot + "/q-test")) // 批次目录随之移除
    }

    func testSameNameFilesRestoreToTheirOriginalPaths() throws {
        let a = root + "/a/data.txt"
        let b = root + "/b/data.txt"
        try TestEnv.makeTree(root: root, files: ["a/data.txt": "AAA", "b/data.txt": "BBB"])

        let batch = try store.beginBatch(id: "q-dup")
        try batch.admit(originalPath: a, sizeBytes: 3)
        try batch.admit(originalPath: b, sizeBytes: 3)
        try batch.finalize(now: Date())

        let (restored, errors) = store.restore(batchID: "q-dup")
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(Set(restored), [a, b])
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "AAA")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "BBB")
    }

    func testRestoreSkipsWhenDestinationOccupied() throws {
        let original = root + "/data/file.txt"
        try TestEnv.makeTree(root: root, files: ["data/file.txt": "OLD"])
        let batch = try store.beginBatch(id: "q-conflict")
        try batch.admit(originalPath: original, sizeBytes: 3)
        try batch.finalize(now: Date())

        // 还原前原路径被新文件占用
        try TestEnv.write("NEW", to: original)

        let (restored, errors) = store.restore(batchID: "q-conflict")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(errors.count, 1)
        // 批次保留，manifest 只剩未还原条目
        XCTAssertEqual(store.listBatches().first?.entries.count, 1)
        XCTAssertEqual(store.listBatches().first?.batchID, "q-conflict")
    }

    func testPurgeByManifestAge() throws {
        // spec §10：8 天前的批次被清除，6 天前的保留
        let old8 = root + "/old8.txt"
        let old6 = root + "/old6.txt"
        try TestEnv.makeTree(root: root, files: ["old8.txt": "8", "old6.txt": "6"])

        let b8 = try store.beginBatch(id: "q-8d")
        try b8.admit(originalPath: old8, sizeBytes: 1)
        try b8.finalize(now: TestEnv.daysAgo(8))

        let b6 = try store.beginBatch(id: "q-6d")
        try b6.admit(originalPath: old6, sizeBytes: 1)
        try b6.finalize(now: TestEnv.daysAgo(6))

        let (purged, skippedUnknown) = store.purge(olderThanDays: 7, now: Date())
        XCTAssertEqual(purged, ["q-8d"])
        XCTAssertTrue(skippedUnknown.isEmpty)
        XCTAssertFalse(files.fileExists(quarantineRoot + "/q-8d"))
        XCTAssertEqual(store.listBatches().map(\.batchID), ["q-6d"])
        XCTAssertFalse(files.fileExists(old8))
        XCTAssertFalse(files.fileExists(old6)) // 6 天批次的条目仍在隔离区里
        XCTAssertTrue(files.fileExists(quarantineRoot + "/q-6d/0000-old6.txt"))
    }

    func testPurgeSkipsDirectoriesWithoutManifest() throws {
        try FileManager.default.createDirectory(atPath: quarantineRoot + "/not-a-batch",
                                                withIntermediateDirectories: true)
        let (purged, skippedUnknown) = store.purge(olderThanDays: 7, now: Date())
        XCTAssertTrue(purged.isEmpty)
        XCTAssertEqual(skippedUnknown, [quarantineRoot + "/not-a-batch"]) // 无法解析的一律不动
    }

    func testRestoreUnknownBatchReportsError() {
        let (restored, errors) = store.restore(batchID: "q-ghost")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    func testManifestIsJSONAndReadable() throws {
        let original = root + "/data/x.txt"
        try TestEnv.makeTree(root: root, files: ["data/x.txt": "x"])
        let batch = try store.beginBatch(id: "q-json")
        try batch.admit(originalPath: original, sizeBytes: 1)
        try batch.finalize(now: TestEnv.daysAgo(1))

        let manifest = try XCTUnwrap(store.listBatches().first)
        XCTAssertEqual(manifest.batchID, "q-json")
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries[0].originalPath, original)
        XCTAssertEqual(manifest.entries[0].storedPath, quarantineRoot + "/q-json/0000-x.txt")
        XCTAssertEqual(store.occupiedBytes(), 1)
    }
}
```

## 任务 8：Planner

汇集第 2、3、5、6 层：任一候选命中红线 → 抛 `forbiddenZone`，整个计划 abort。配置错误（黄色+command、缺 cmd、扫描 configError）同样大声失败而非静默跳过。红色只读永不入计划。

```swift
import Foundation

// MARK: - 计划器（spec §5 第 2、3、5、6 层的汇集点）

/// 生成不可变计划对象：逐条路径 + 大小 + 风险 + 动作。
/// 任一候选命中禁区或围栏逃逸 → 抛 `PlannerError.forbiddenZone`，整个计划 abort，而非静默跳过。
public final class Planner {
    private let files: FileOperations
    private let safety: PathSafety
    private let guards: GuardEvaluator

    public init(files: FileOperations, safety: PathSafety, guards: GuardEvaluator) {
        self.files = files
        self.safety = safety
        self.guards = guards
    }

    /// - Parameters:
    ///   - report: scan 产出的报告（candidates 已就绪）
    ///   - rules: 与 report 同源的规则表，提供 cmd / roots / guards 等执行细节
    ///   - selectedRuleIds: nil = 全部可执行规则（绿 + 黄）；红色只读永不入计划
    public func makePlan(report: Report, rules: [Rule], selectedRuleIds: Set<String>? = nil,
                         now: Date = Date()) throws -> Plan {
        let rulesById = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var items: [PlanItem] = []

        for entry in report.entries {
            if let selected = selectedRuleIds, !selected.contains(entry.ruleId) { continue }
            guard let rule = rulesById[entry.ruleId] else {
                throw PlannerError.invalidRule(id: entry.ruleId, reason: "报告中的条目找不到对应规则")
            }
            if rule.risk == .red { continue } // 红色只读展示，永不入计划（spec §6）
            if !Strategy.isCompatible(risk: rule.risk, type: rule.strategy.type) {
                throw PlannerError.invalidRule(id: rule.id, reason: "黄色规则只能配 delete-dir / glob-age，command / truncate 无法隔离还原")
            }
            switch entry.status {
            case .ok:
                break
            case .rootsMissing:
                continue // 没有可清理内容，属正常状态
            case .configError(let message):
                // 配置错误必须大声失败：静默跳过会让用户以为规则在生效
                throw PlannerError.invalidRule(id: rule.id, reason: message)
            }

            let normalizedRoots = rule.roots.map { safety.normalize($0) }
            let itemStatus: PlanItemStatus
            if let ruleGuards = rule.guards, !ruleGuards.isEmpty {
                if case .blocked(let occupiers) = guards.status(of: ruleGuards, home: report.home) {
                    itemStatus = .blocked(occupiers)
                } else {
                    itemStatus = .ready
                }
            } else {
                itemStatus = .ready
            }

            switch entry.strategyType {
            case .command:
                // 委托命令是单条动作：以第一个仍存在的 root 作为展示锚点
                guard let cmd = rule.strategy.cmd, !cmd.isEmpty else {
                    throw PlannerError.invalidRule(id: rule.id, reason: "command 策略缺少 cmd")
                }
                let anchor = normalizedRoots.first { files.fileExists($0) } ?? normalizedRoots.first ?? "/"
                items.append(PlanItem(
                    path: anchor, ruleId: rule.id, ruleName: rule.name, risk: rule.risk,
                    sizeBytes: entry.sizeBytes, action: .runCommand(cmd), status: itemStatus,
                    ruleRoots: normalizedRoots))

            case .deleteDir, .globAge, .truncate:
                for candidate in entry.candidates {
                    do {
                        // 第 3 层 + 第 5 层：禁区与路径断言
                        _ = try safety.assertAllowed(candidate)
                        // 第 2 层：围栏（符号链接叶放行；中段链接逃逸 → abort）
                        _ = try safety.checkFence(candidate: candidate, roots: normalizedRoots)
                    } catch let error as PathSafetyError {
                        throw PlannerError.forbiddenZone(path: candidate, reason: error.description)
                    }
                    let action: PlanAction
                    if rule.risk == .yellow {
                        action = .quarantine
                    } else if rule.strategy.type == .truncate {
                        action = .truncate
                    } else {
                        action = .delete
                    }
                    items.append(PlanItem(
                        path: candidate, ruleId: rule.id, ruleName: rule.name, risk: rule.risk,
                        sizeBytes: perItemSize(candidate), action: action, status: itemStatus,
                        ruleRoots: normalizedRoots))
                }
            }
        }

        return Plan(id: Self.planID(now: now), createdAt: now, items: items)
    }

    /// 逐条大小：目录按 du 口径重测，文件取磁盘占用。
    private func perItemSize(_ path: String) -> Int64 {
        guard let attrs = files.attributesIfExist(atPath: path) else { return 0 }
        return (attrs.isDirectory && !attrs.isSymbolicLink) ? files.apparentSize(of: path) : attrs.allocatedSize
    }

    static func planID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return "p-" + formatter.string(from: now)
    }
}
```

## 任务 9：Executor（第 7 层两段式）

第一阶段对全部条目重校验（存在性 / 禁区 / 围栏）——任一命中先写 `apply.abort` 审计再整体抛错，此时什么都没动过；第二阶段才逐条执行。目标消失 → skip 记账（TOCTOU）；command 非零退出 → failed，绝不 fallback 到自行 rm。

```swift
import Foundation

// MARK: - 执行器（spec §5 第 7 层：两段式执行 + 逐条重校验，防 TOCTOU）

/// 第一阶段：对全部待执行条目重校验（存在性 + 禁区 + 围栏）——任何一条命中红线则整个执行 abort，
/// 此时还什么都没动。第二阶段：逐条执行。计划生成到执行之间目标变化 → 该条 skip 并在结果中报告。
public final class Executor {
    private let files: FileOperations
    private let safety: PathSafety
    private let quarantine: QuarantineStore
    private let audit: AuditLog
    private let runner: ProcessRunner

    public init(files: FileOperations, safety: PathSafety, quarantine: QuarantineStore,
                audit: AuditLog, runner: ProcessRunner) {
        self.files = files
        self.safety = safety
        self.quarantine = quarantine
        self.audit = audit
        self.runner = runner
    }

    public func execute(_ plan: Plan, now: Date = Date()) throws -> ExecutionResult {
        let ready = plan.items.filter(\.isReady)
        guard !ready.isEmpty else { throw ExecutorError.noExecutableItems }

        var outcomes: [ItemOutcome] = []
        // 被守卫阻断的条目如实记账，但绝不执行
        for blocked in plan.items where !blocked.isReady {
            let reason: String
            if case .blocked(let occupiers) = blocked.status {
                reason = "被占用守卫阻断：" + occupiers.map(\.description).joined(separator: ", ")
            } else {
                reason = "不可执行状态"
            }
            outcomes.append(ItemOutcome(path: blocked.path, ruleId: blocked.ruleId,
                                        result: .skipped, sizeBytes: blocked.sizeBytes, detail: reason))
        }

        // ---- 第一阶段：全量重校验（spec §5 第 7 层） ----
        for item in ready {
            guard files.fileExists(item.path) else {
                outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .skipped,
                                            sizeBytes: item.sizeBytes, detail: "目标已不存在（计划生成后发生变化，TOCTOU 跳过）"))
                continue
            }
            do {
                _ = try safety.assertAllowed(item.path)
                _ = try safety.checkFence(candidate: item.path, roots: item.ruleRoots)
            } catch let error as PathSafetyError {
                audit.append(AuditEvent(op: "apply.abort", detail: "\(item.path): \(error)"))
                throw ExecutorError.forbiddenZone(path: item.path, reason: error.description)
            }
        }

        // ---- 第二阶段：执行 ----
        let yellowItems = ready.filter { $0.risk == .yellow }
        var batch: QuarantineBatch?
        if !yellowItems.isEmpty {
            batch = try quarantine.beginBatch(id: Self.batchID(now: now))
        }

        var reclaimed: Int64 = 0
        var quarantined: Int64 = 0

        for item in ready {
            // 重校验已通过的条目直接执行；执行期错误按条目记 failed，不中断其余条目
            switch item.action {
            case .delete:
                do {
                    try files.removeItem(atPath: item.path)
                    reclaimed += item.sizeBytes
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .done,
                                                sizeBytes: item.sizeBytes, detail: "已删除"))
                    audit.append(AuditEvent(op: "apply.item", detail: "delete \(item.path)", bytes: item.sizeBytes))
                } catch {
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .failed,
                                                sizeBytes: item.sizeBytes, detail: "删除失败：\(error)"))
                }

            case .truncate:
                do {
                    let currentSize = files.attributesIfExist(atPath: item.path)?.allocatedSize ?? item.sizeBytes
                    try files.truncateFile(atPath: item.path)
                    reclaimed += currentSize
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .done,
                                                sizeBytes: currentSize, detail: "已清空内容"))
                    audit.append(AuditEvent(op: "apply.item", detail: "truncate \(item.path)", bytes: currentSize))
                } catch {
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .failed,
                                                sizeBytes: item.sizeBytes, detail: "清空失败：\(error)"))
                }

            case .runCommand(let cmd):
                let resolved = ExecutableLocator.resolve(cmd[0])
                let result = runner.run(launchPath: resolved, arguments: Array(cmd.dropFirst()))
                guard let result else {
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .failed,
                                                sizeBytes: item.sizeBytes,
                                                detail: "命令无法启动：\(cmd[0])（不 fallback 到自行删除）"))
                    continue
                }
                if result.exitStatus == 0 {
                    reclaimed += item.sizeBytes
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .done,
                                                sizeBytes: item.sizeBytes, detail: "命令成功：\(cmd.joined(separator: " "))"))
                    audit.append(AuditEvent(op: "apply.item", detail: "command ok: \(cmd.joined(separator: " "))",
                                            bytes: item.sizeBytes))
                } else {
                    // spec §4：command 失败标记为失败，不 fallback 到自行 rm
                    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .failed,
                                                sizeBytes: item.sizeBytes,
                                                detail: "命令退出码 \(result.exitStatus)：\(String(stderr.prefix(200)))"))
                }

            case .quarantine:
                guard let batch else { continue }
                do {
                    try batch.admit(originalPath: item.path, sizeBytes: item.sizeBytes)
                    quarantined += item.sizeBytes
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .done,
                                                sizeBytes: item.sizeBytes, detail: "已移入隔离区（同卷移动暂不释放空间）"))
                    audit.append(AuditEvent(op: "apply.item", detail: "quarantine \(item.path)", bytes: item.sizeBytes))
                } catch {
                    outcomes.append(ItemOutcome(path: item.path, ruleId: item.ruleId, result: .failed,
                                                sizeBytes: item.sizeBytes, detail: "移入隔离区失败：\(error)"))
                }
            }
        }

        var batchID: String?
        if let batch {
            let manifest = try batch.finalize(now: now)
            batchID = manifest.batchID
            audit.append(AuditEvent(op: "apply.quarantine-batch",
                                    detail: "batch=\(manifest.batchID) items=\(manifest.entries.count)",
                                    bytes: quarantined))
        }

        let result = ExecutionResult(planID: plan.id, startedAt: now, finishedAt: Date(),
                                     outcomes: outcomes, quarantineBatchID: batchID,
                                     reclaimedBytes: reclaimed, quarantinedBytes: quarantined)
        let doneCount = outcomes.filter { $0.result == .done }.count
        let skippedCount = outcomes.filter { $0.result == .skipped }.count
        let failedCount = outcomes.filter { $0.result == .failed }.count
        audit.append(AuditEvent(op: "apply.summary",
                                detail: "plan=\(plan.id) done=\(doneCount) skipped=\(skippedCount) failed=\(failedCount)",
                                bytes: reclaimed))
        return result
    }

    static func batchID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return "q-" + formatter.string(from: now)
    }
}
```

## 任务 10：AuditLog

JSONL 追加写 `~/.dclean/audit.log`；op 取值 `apply.item` / `apply.quarantine-batch` / `apply.summary` / `apply.abort` / `restore` / `purge`。

```swift
import Foundation

// MARK: - 审计日志（spec §7：所有操作追加写入 ~/.dclean/audit.log，每次操作一行 JSON）

public struct AuditEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var op: String
    public var detail: String
    public var bytes: Int64?

    public init(ts: Date = Date(), op: String, detail: String, bytes: Int64? = nil) {
        self.ts = ts
        self.op = op
        self.detail = detail
        self.bytes = bytes
    }
}

public final class AuditLog {
    public let path: String
    private let files: FileOperations
    private let lock = NSLock()

    public init(files: FileOperations, path: String) {
        self.files = files
        self.path = path
    }

    public func append(_ event: AuditEvent) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let dir = (path as NSString).deletingLastPathComponent
        try? files.createDirectory(atPath: dir, intermediate: true)
        try? files.appendFile(line, toPath: path)
    }

    public func readAll() -> [AuditEvent] {
        guard let data = files.readFile(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(AuditEvent.self, from: Data(line))
        }
    }
}
```

## 任务 11：RuleStore + 内置默认规则

首次运行落盘默认规则；此后绝不覆盖；内置版本更新时提示手动合并。禁区在代码中，对用户编辑的规则同样生效（spec §4）。

```swift
import Foundation

// MARK: - 规则存储（spec §4：规则是数据不是代码）

/// 规则文件位于 ~/.dclean/rules.json：
/// - 首次运行写入内置默认规则集；
/// - 此后升级不覆盖用户文件；内置版本更新时以「有新规则可用」提示手动合并；
/// - 硬编码禁区在代码中，对用户编辑的规则同样生效。
public final class RuleStore {
    public static let bundledDefaultsVersion = 1

    public let path: String
    private let files: FileOperations
    private let defaultsProvider: () throws -> Data

    public init(files: FileOperations, path: String, defaultsProvider: @escaping () throws -> Data) {
        self.files = files
        self.path = path
        self.defaultsProvider = defaultsProvider
    }

    public enum EnsureOutcome: Equatable {
        case created
        case existed
    }

    /// 首次运行落盘默认规则；已存在则绝不覆盖。
    public func ensureRulesFile() throws -> EnsureOutcome {
        if files.fileExists(path) { return .existed }
        let data = try defaultsProvider()
        let dir = (path as NSString).deletingLastPathComponent
        try files.createDirectory(atPath: dir, intermediate: true)
        try files.writeFile(data, toPath: path)
        return .created
    }

    public func load() throws -> RulesFile {
        guard let data = files.readFile(atPath: path) else {
            throw FileOpError.notFound(path)
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(RulesFile.self, from: data)
        } catch {
            throw RuleStoreError.decodingFailed(path: path, underlying: error)
        }
    }

    /// 内置默认规则集（随二进制发布）。
    public static func decodeDefaults(from data: Data) throws -> RulesFile {
        let decoder = JSONDecoder()
        return try decoder.decode(RulesFile.self, from: data)
    }

    /// 用户文件版本落后于内置默认 → 提示手动合并，绝不覆盖。
    public func needsDefaultsUpgrade(_ userFile: RulesFile) -> Bool {
        userFile.version < Self.bundledDefaultsVersion
    }
}

public enum RuleStoreError: Error, CustomStringConvertible {
    case decodingFailed(path: String, underlying: Error)

    public var description: String {
        switch self {
        case .decodingFailed(let path, let underlying):
            return "规则文件解析失败：\(path)（\(underlying)）。请修正或删除该文件后重试（删除会在下次运行时重建默认规则）。"
        }
    }
}

// MARK: - 内置默认规则（数据随二进制发布，见 Sources/CleanerCore/DefaultRules.json）

public enum BundledRules {
    /// 从 CleanerCore 资源包读取默认规则。
    public static func data(bundle: Bundle? = nil) throws -> Data {
        let bundle = bundle ?? Bundle.module
        guard let url = bundle.url(forResource: "DefaultRules", withExtension: "json") else {
            throw RuleStoreError.decodingFailed(path: "DefaultRules.json (bundled)",
                                                underlying: FileOpError.notFound("DefaultRules.json"))
        }
        return try Data(contentsOf: url)
    }
}
```

```json
{
  "version": 1,
  "rules": [
    {
      "id": "uv-cache",
      "name": "uv 包缓存",
      "risk": "green",
      "roots": ["~/.cache/uv"],
      "strategy": { "type": "command", "cmd": ["uv", "cache", "prune"] },
      "guards": [{ "type": "lockfile", "path": "~/.cache/uv/.lock" }],
      "explain": "删后下次装包需重新下载。APFS clonefile 写时复制，不影响已有 venv，但净回收会明显小于表观大小。被 chroma-mcp 等进程持锁时自动跳过。"
    },
    {
      "id": "pip-cache",
      "name": "pip 缓存",
      "risk": "green",
      "roots": ["~/Library/Caches/pip"],
      "strategy": { "type": "delete-dir" },
      "explain": "pip 下载缓存，删除后下次安装相同包需重新下载。"
    },
    {
      "id": "playwright-browsers",
      "name": "Playwright 浏览器",
      "risk": "green",
      "roots": ["~/Library/Caches/ms-playwright"],
      "strategy": { "type": "delete-dir" },
      "explain": "测试用浏览器二进制，可用 npx playwright install 按需重新拉取。"
    },
    {
      "id": "homebrew-cleanup",
      "name": "Homebrew 缓存与旧版本",
      "risk": "green",
      "roots": ["~/Library/Caches/Homebrew"],
      "strategy": { "type": "command", "cmd": ["brew", "cleanup", "-s"] },
      "explain": "委托 brew cleanup 清理过期下载缓存与旧版本；roots 仅作占用展示。brew 不在 PATH 时该条会失败，不会退化成自行删除。"
    },
    {
      "id": "puppeteer-cache",
      "name": "Puppeteer 浏览器",
      "risk": "green",
      "roots": ["~/.cache/puppeteer"],
      "strategy": { "type": "delete-dir" },
      "explain": "Puppeteer 下载的 Chromium，下次运行时按配置的版本重新下载。"
    },
    {
      "id": "camoufox-cache",
      "name": "Camoufox 浏览器",
      "risk": "green",
      "roots": ["~/.cache/camoufox"],
      "strategy": { "type": "delete-dir" },
      "explain": "Camoufox 指纹浏览器缓存，删除后下次使用重新下载。"
    },
    {
      "id": "docker-dangling-images",
      "name": "Docker 悬空镜像",
      "risk": "green",
      "roots": ["~/.docker"],
      "strategy": { "type": "command", "cmd": ["docker", "image", "prune", "-f"] },
      "explain": "仅清除悬空（dangling）镜像。不可还原，需重新拉取——悬空镜像本就符合绿色定义（可再生，代价是时间）。roots 仅作锚点展示；Docker.raw 的真实占用请到 Docker Desktop 调低磁盘镜像上限（见红色项）。"
    },
    {
      "id": "diagnostic-reports",
      "name": "系统崩溃转储（30 天前）",
      "risk": "green",
      "roots": ["~/Library/Logs/Diagnostic Reports"],
      "strategy": { "type": "glob-age", "glob": "~/Library/Logs/Diagnostic Reports/*", "olderThanDays": 30 },
      "explain": "只清 30 天前的 .ips/.panic 转储；近期的崩溃报告对排查问题有用，保留。"
    },
    {
      "id": "codex-sessions",
      "name": "Codex 会话记录",
      "risk": "yellow",
      "roots": ["~/.codex/sessions"],
      "strategy": { "type": "delete-dir" },
      "explain": "codex 历史会话。整体移入隔离区，7 天后自动清除；期间可在隔离区一键还原。"
    },
    {
      "id": "codex-logs",
      "name": "Codex sqlite/rollout 日志",
      "risk": "yellow",
      "roots": ["~/.codex/log"],
      "strategy": { "type": "delete-dir" },
      "explain": "codex 的 sqlite 与 rollout 日志，隔离 7 天后删除；如实际路径不同可直接编辑本文件的 roots。"
    },
    {
      "id": "jetbrains-old-caches",
      "name": "JetBrains 旧版本缓存",
      "risk": "yellow",
      "roots": ["~/Library/Caches/JetBrains"],
      "strategy": { "type": "glob-age", "glob": "~/Library/Caches/JetBrains/*", "olderThanDays": 90 },
      "explain": "仅隔离 mtime 超过 90 天的目录（通常是已卸载或升级前的旧版本 IDE 索引），在隔离区可还原。"
    },
    {
      "id": "claude-plugins-old",
      "name": "Claude 插件旧版本",
      "risk": "yellow",
      "roots": ["~/.claude/plugins"],
      "strategy": { "type": "glob-age", "glob": "~/.claude/plugins/*", "olderThanDays": 30 },
      "explain": "隔离 30 天未变动的插件目录（多为旧版本残留），7 天后删除，可还原；正在使用的插件近期 mtime 不会被匹配。"
    },
    {
      "id": "huggingface-hub",
      "name": "HuggingFace 模型权重",
      "risk": "yellow",
      "roots": ["~/.cache/huggingface"],
      "strategy": { "type": "delete-dir" },
      "explain": "已下载的模型权重可随时由 hub 重新拉取，但重新下载代价高，故先隔离 7 天；期间可还原。"
    },
    {
      "id": "claude-vm-bundles",
      "name": "Claude Desktop（含 vm_bundles）",
      "risk": "red",
      "roots": ["~/Library/Application Support/Claude"],
      "strategy": { "type": "delete-dir" },
      "explain": "vm_bundles 随应用版本更新会重新下载，但直接删除可能损坏应用状态。建议通过 Claude Desktop 自身升级/清理入口处理；确需手动清理时先完全退出应用再移除 vm_bundles 子目录。"
    },
    {
      "id": "docker-raw",
      "name": "Docker.raw 虚拟磁盘",
      "risk": "red",
      "roots": ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"],
      "strategy": { "type": "delete-dir" },
      "explain": "Docker.raw 是 Docker Desktop 的虚拟磁盘文件，删除会毁掉容器与镜像数据。正确做法：Docker Desktop → Resources → 调低 Disk image size，并用 docker system prune 回收内部空间。"
    },
    {
      "id": "chrome-service-worker",
      "name": "Chrome Service Worker 存储",
      "risk": "red",
      "roots": ["~/Library/Application Support/Google/Chrome/Default/Service Worker"],
      "strategy": { "type": "delete-dir" },
      "explain": "删除会破坏大量站点的离线数据与登录态。请在 Chrome 设置「清除浏览数据」中按站点处理；本工具永不触碰。"
    }
  ]
}
```

```swift
import XCTest
@testable import CleanerCore

/// 规则存储与默认规则集
final class RuleStoreTests: XCTestCase {
    private var home: String!
    private var files: RealFileOperations!
    private var rulesPath: String!

    override func setUpWithError() throws {
        home = TestEnv.makeTempDir("dclean-rules")
        files = RealFileOperations()
        rulesPath = home + "/.dclean/rules.json"
    }

    override func tearDown() {
        TestEnv.remove(home!)
    }

    private func makeStore() -> RuleStore {
        RuleStore(files: files, path: rulesPath, defaultsProvider: { try BundledRules.data() })
    }

    func testBundledDefaultsExistAndValidate() throws {
        // spec §11 交付 3：默认规则集基于 §6 清单；必须整体通过校验
        let rulesFile = try RuleStore.decodeDefaults(from: BundledRules.data())
        XCTAssertEqual(rulesFile.version, RuleStore.bundledDefaultsVersion)
        XCTAssertGreaterThanOrEqual(rulesFile.rules.count, 12)
        XCTAssertTrue(validateRules(rulesFile.rules).isEmpty,
                      "内置规则不应有配置错误：\(validateRules(rulesFile.rules))")

        let ids = Set(rulesFile.rules.map(\.id))
        // 关键规则点名校验（与 spec §1 实测清单对应）
        for required in ["uv-cache", "pip-cache", "playwright-browsers", "codex-sessions",
                         "claude-vm-bundles", "docker-raw", "chrome-service-worker",
                         "docker-dangling-images"] {
            XCTAssertTrue(ids.contains(required), "缺少规则 \(required)")
        }
        // 修正记录落地：Docker 悬空镜像必须是绿色 + command，且 explain 写明不可还原
        let docker = try XCTUnwrap(rulesFile.rules.first { $0.id == "docker-dangling-images" })
        XCTAssertEqual(docker.risk, .green)
        XCTAssertEqual(docker.strategy.type, .command)
        XCTAssertTrue(docker.explain.contains("不可还原"), "explain 需写明不可还原，需重新拉取")
        // 红色三项只读
        for redID in ["claude-vm-bundles", "docker-raw", "chrome-service-worker"] {
            XCTAssertEqual(rulesFile.rules.first { $0.id == redID }?.risk, .red)
        }
    }

    func testFirstRunWritesDefaultsAndNeverOverwritesAfterwards() throws {
        let store = makeStore()
        XCTAssertEqual(try store.ensureRulesFile(), .created)
        XCTAssertTrue(files.fileExists(rulesPath))
        XCTAssertEqual(try store.ensureRulesFile(), .existed)

        // 用户编辑后绝不覆盖（spec §4）
        try TestEnv.write("{\"version\":1,\"rules\":[]}", to: rulesPath)
        XCTAssertEqual(try store.ensureRulesFile(), .existed)
        XCTAssertEqual(try String(contentsOfFile: rulesPath, encoding: .utf8),
                       "{\"version\":1,\"rules\":[]}")
    }

    func testLoadDecodesUserFile() throws {
        try TestEnv.write(#"{"version":1,"rules":[{"id":"x","name":"x","risk":"green","roots":["~/.cache/uv"],"strategy":{"type":"delete-dir"},"explain":"e"}]}"#,
                          to: rulesPath)
        let loaded = try makeStore().load()
        XCTAssertEqual(loaded.rules.count, 1)
        XCTAssertEqual(loaded.rules[0].id, "x")
        XCTAssertFalse(makeStore().needsDefaultsUpgrade(loaded))
    }

    func testUpgradeHintWhenUserVersionOlder() throws {
        try TestEnv.write("{\"version\":0,\"rules\":[]}", to: rulesPath)
        let loaded = try makeStore().load()
        XCTAssertTrue(makeStore().needsDefaultsUpgrade(loaded))
    }

    func testCorruptUserFileProducesActionableError() throws {
        try TestEnv.write("{ not json", to: rulesPath)
        XCTAssertThrowsError(try makeStore().load()) { error in
            guard case RuleStoreError.decodingFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testValidateRulesCatchesCommonMistakes() {
        XCTAssertTrue(validateRules([]).isEmpty)
        XCTAssertEqual(validateRules([
            Rule(id: "", name: "n", risk: .green, roots: ["~/.cache/uv"],
                 strategy: Strategy(type: .deleteDir), explain: "e"),
        ]).count, 1) // 空 id
        XCTAssertEqual(validateRules([
            Rule(id: "a", name: "n", risk: .green, roots: [], strategy: Strategy(type: .deleteDir), explain: "e"),
        ]).count, 1) // 空 roots
        XCTAssertEqual(validateRules([
            Rule(id: "a", name: "n", risk: .green, roots: ["~/x"],
                 strategy: Strategy(type: .command, cmd: []), explain: "e"),
        ]).count, 1) // command 缺 cmd
        XCTAssertEqual(validateRules([
            Rule(id: "a", name: "n", risk: .yellow, roots: ["~/x"],
                 strategy: Strategy(type: .truncate), explain: "e"),
        ]).count, 1) // 黄色 truncate 互斥
    }
}

/// 审计日志
final class AuditLogTests: XCTestCase {
    private var root: String!

    override func setUp() {
        root = TestEnv.makeTempDir("dclean-audit")
    }

    override func tearDown() {
        TestEnv.remove(root!)
    }

    func testAppendAndReadRoundTrip() throws {
        let files = RealFileOperations()
        let log = AuditLog(files: files, path: root + "/.dclean/audit.log")
        log.append(AuditEvent(op: "apply.item", detail: "delete /a/b/c", bytes: 123))
        log.append(AuditEvent(op: "purge", detail: "batches=q-1"))

        let events = log.readAll()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].op, "apply.item")
        XCTAssertEqual(events[0].bytes, 123)
        XCTAssertEqual(events[1].detail, "batches=q-1")

        // 追加不覆盖
        log.append(AuditEvent(op: "restore", detail: "batch=q-1 restored=1 errors=0"))
        XCTAssertEqual(log.readAll().count, 3)
    }

    func testInMemoryAuditFile() {
        let mem = InMemoryFileOperations(home: "/Users/t")
        let log = AuditLog(files: mem, path: "/Users/t/.dclean/audit.log")
        log.append(AuditEvent(op: "purge", detail: "x"))
        XCTAssertEqual(log.readAll().count, 1)
    }
}
```

## 任务 12：dclean CLI

默认只读（scan/plan 是 dry-run），显式 `apply` 才执行；无 `--force`（spec 非目标）。

```swift
import Foundation
import CleanerCore

// MARK: - dclean CLI（spec §3：scan / plan / apply / restore / purge）
// 延续一次性脚本的习惯：默认只读（scan / plan 为 dry-run），显式 apply 才执行；无任何 --force。

let usage = """
DiskCleaner 命令行 — AI 工具产物与开发缓存清理（默认只读，无 --force）

用法:
  dclean scan [--json] [--write-report]   扫描（先自动清掉过期隔离批次），输出报告
  dclean plan [--ids id1,id2] [--json] [--out PATH]
                                          生成清理计划（dry-run，写 ~/.dclean/last-plan.json）
  dclean apply [--plan PATH] [--json]     执行计划：逐条重校验后删除/隔离/委托命令
  dclean restore <batchID>                按批次还原隔离区内容
  dclean quarantine                       列出隔离批次
  dclean purge                            立即清除超过 7 天的隔离批次
  dclean rules [--json]                   查看当前规则与校验结果
"""

let home = NSHomeDirectory()
let dcDir = home + "/.dclean"
let rulesPath = dcDir + "/rules.json"
let reportPath = dcDir + "/report.json"
let lastPlanPath = dcDir + "/last-plan.json"
let quarantineRoot = dcDir + "/quarantine"
let auditPath = dcDir + "/audit.log"

struct Core {
    let files: RealFileOperations
    let safety: PathSafety
    let runner: RealProcessRunner
    let guards: GuardEvaluator
    let scanner: CleanerCore.Scanner
    let planner: Planner
    let executor: Executor
    let quarantine: QuarantineStore
    let audit: AuditLog
    let store: RuleStore
}

func makeCore() -> Core {
    let files = RealFileOperations()
    let safety = PathSafety(home: home, files: files)
    let runner = RealProcessRunner()
    let guards = GuardEvaluator(files: files, runner: runner)
    let scanner = CleanerCore.Scanner(files: files, safety: safety)
    let planner = Planner(files: files, safety: safety, guards: guards)
    let executor = Executor(files: files, safety: safety,
                            quarantine: QuarantineStore(root: quarantineRoot, files: files),
                            audit: AuditLog(files: files, path: auditPath),
                            runner: runner)
    let store = RuleStore(files: files, path: rulesPath,
                          defaultsProvider: { try BundledRules.data() })
    return Core(files: files, safety: safety, runner: runner, guards: guards, scanner: scanner,
                planner: planner, executor: executor,
                quarantine: QuarantineStore(root: quarantineRoot, files: files),
                audit: AuditLog(files: files, path: auditPath), store: store)
}

func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

func argValue(for flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

func loadRules(core: Core) -> RulesFile? {
    do {
        switch try core.store.ensureRulesFile() {
        case .created:
            print("首次运行：已写入默认规则到 \(rulesPath)")
        case .existed:
            break
        }
        let rulesFile = try core.store.load()
        let errors = validateRules(rulesFile.rules)
        if !errors.isEmpty {
            fputs("规则文件存在配置错误（已拒绝执行，请修正 \(rulesPath)）：\n", stderr)
            for e in errors { fputs("  - \(e)\n", stderr) }
            return nil
        }
        if core.store.needsDefaultsUpgrade(rulesFile) {
            print("提示：内置默认规则集有更新（当前文件 version=\(rulesFile.version)），可参考发布说明手动合并新规则。")
        }
        return rulesFile
    } catch {
        fputs("\(error)\n", stderr)
        return nil
    }
}

// MARK: 输出

func printReportTable(_ report: Report) {
    if let disk = report.disk {
        let usedPct = disk.totalBytes > 0
            ? Int(round((Double(disk.totalBytes - disk.freeBytes) / Double(disk.totalBytes)) * 100))
            : 0
        print("磁盘 \(ByteFormatting.human(disk.totalBytes - disk.freeBytes)) / \(ByteFormatting.human(disk.totalBytes)) · 可用 \(ByteFormatting.human(disk.freeBytes))（\(usedPct)% 已用）")
    }
    for risk in [RiskLevel.green, .yellow, .red] {
        let entries = report.entries(withRisk: risk)
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("\(risk.symbol) \(risk.label)  \(ByteFormatting.human(total))")
        for e in entries {
            let statusMark: String
            switch e.status {
            case .ok: statusMark = ""
            case .rootsMissing: statusMark = "  （目录不存在）"
            case .configError(let msg): statusMark = "  （配置错误：\(msg)）"
            }
            let note = e.strategyType == .command ? "  [命令委托]" : ""
            print("    \(ByteFormatting.padded(e.ruleName, to: 30))\(ByteFormatting.padded(ByteFormatting.human(e.sizeBytes), to: 10))  \(e.ruleId)\(note)\(statusMark)")
        }
    }
}

func printPlan(_ plan: Plan) {
    print("计划 \(plan.id)：\(plan.items.count) 项 · 立即回收 \(ByteFormatting.human(plan.reclaimableBytes)) · 移入隔离区 \(ByteFormatting.human(plan.quarantinedBytes))")
    for item in plan.items {
        let status: String
        switch item.status {
        case .ready: status = ""
        case .blocked(let occ): status = "  ⚠ 被 \(occ.map(\.description).joined(separator: ", ")) 占用，将跳过"
        }
        print("  [\(item.risk.rawValue)] \(ByteFormatting.padded(item.actionLabel, to: 22))\(ByteFormatting.padded(ByteFormatting.human(item.sizeBytes), to: 10))  \(item.path)\(status)")
    }
}

func printResult(_ result: ExecutionResult) {
    for o in result.outcomes {
        let mark: String
        switch o.result {
        case .done: mark = "✓"
        case .skipped: mark = "↷"
        case .failed: mark = "✗"
        }
        print("  \(mark) [\(o.ruleId)] \(o.path) — \(o.detail)")
    }
    let batch = result.quarantineBatchID.map { "（批次 \($0)，dclean restore \($0) 可还原）" } ?? ""
    print("完成：回收 \(ByteFormatting.human(result.reclaimedBytes))，隔离 \(ByteFormatting.human(result.quarantinedBytes))\(batch)")
}

// MARK: 子命令

func cmdScan(_ args: [String]) -> Int32 {
    let core = makeCore()
    guard let rulesFile = loadRules(core: core) else { return 2 }

    // spec §9：每日任务把过期隔离批次的 purge 并入扫描（扫描前先 purge）
    let (purged, skippedUnknown) = core.quarantine.purge(olderThanDays: 7, now: Date())
    if !purged.isEmpty {
        core.audit.append(AuditEvent(op: "purge", detail: "batches=\(purged.joined(separator: ","))"))
        print("已清除过期隔离批次：\(purged.joined(separator: ", "))")
    }
    for path in skippedUnknown { print("跳过无法解析的隔离目录（不会删除）：\(path)") }

    let report = core.scanner.scan(rules: rulesFile.rules)
    do {
        let data = try jsonEncoder().encode(report)
        if args.contains("--write-report") {
            try data.write(to: URL(fileURLWithPath: reportPath))
            print("报告已写入 \(reportPath)")
        }
        if args.contains("--json") {
            print(String(decoding: data, as: UTF8.self))
        } else {
            printReportTable(report)
        }
        return 0
    } catch {
        fputs("扫描输出失败：\(error)\n", stderr)
        return 1
    }
}

func cmdPlan(_ args: [String]) -> Int32 {
    let core = makeCore()
    guard let rulesFile = loadRules(core: core) else { return 2 }

    var selected: Set<String>?
    if let idsArg = argValue(for: "--ids", in: args) {
        selected = Set(idsArg.split(separator: ",").map(String.init))
    }

    let report = core.scanner.scan(rules: rulesFile.rules)
    do {
        let plan = try core.planner.makePlan(report: report, rules: rulesFile.rules, selectedRuleIds: selected)
        let data = try jsonEncoder().encode(plan)
        let outPath = argValue(for: "--out", in: args) ?? lastPlanPath
        try data.write(to: URL(fileURLWithPath: outPath))
        if args.contains("--json") {
            print(String(decoding: data, as: UTF8.self))
        } else {
            printPlan(plan)
            print("计划已写入 \(outPath)。确认无误后执行：dclean apply")
        }
        return 0
    } catch let error as PlannerError {
        fputs("\(error)\n", stderr)
        return 3
    } catch {
        fputs("计划生成失败：\(error)\n", stderr)
        return 1
    }
}

func cmdApply(_ args: [String]) -> Int32 {
    let core = makeCore()
    guard loadRules(core: core) != nil else { return 2 }

    let planPath = argValue(for: "--plan", in: args) ?? lastPlanPath
    guard let data = core.files.readFile(atPath: planPath) else {
        fputs("找不到计划文件 \(planPath)。先运行 dclean plan。\n", stderr)
        return 1
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let plan: Plan
    do {
        plan = try decoder.decode(Plan.self, from: data)
    } catch {
        fputs("计划文件解析失败：\(error)\n", stderr)
        return 1
    }

    do {
        let result = try core.executor.execute(plan)
        if args.contains("--json") {
            print(String(decoding: try jsonEncoder().encode(result), as: UTF8.self))
        } else {
            printResult(result)
        }
        return result.outcomes.contains { $0.result == .failed } ? 1 : 0
    } catch let error as ExecutorError {
        fputs("\(error)\n", stderr)
        core.audit.append(AuditEvent(op: "apply.abort", detail: error.description))
        return 3
    } catch {
        fputs("执行失败：\(error)\n", stderr)
        return 1
    }
}

func cmdRestore(_ args: [String]) -> Int32 {
    let core = makeCore()
    guard let batchID = args.first else {
        fputs("用法：dclean restore <batchID>（dclean quarantine 可查批次）\n", stderr)
        return 1
    }
    let (restored, errors) = core.quarantine.restore(batchID: batchID)
    for path in restored { print("✓ 已还原 \(path)") }
    for e in errors { fputs("✗ \(e)\n", stderr) }
    core.audit.append(AuditEvent(op: "restore", detail: "batch=\(batchID) restored=\(restored.count) errors=\(errors.count)"))
    if restored.isEmpty && !errors.isEmpty { return 1 }
    return errors.isEmpty ? 0 : 1
}

func cmdQuarantine() -> Int32 {
    let core = makeCore()
    let batches = core.quarantine.listBatches()
    if batches.isEmpty {
        print("隔离区为空")
        return 0
    }
    for batch in batches {
        let total = batch.entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let formatter = ISO8601DateFormatter()
        print("\(batch.batchID)  \(formatter.string(from: batch.createdAt))  \(batch.entries.count) 项  \(ByteFormatting.human(total))")
        for entry in batch.entries {
            print("    \(entry.originalPath)")
        }
    }
    print("合计占用 \(ByteFormatting.human(core.quarantine.occupiedBytes()))（同卷移动，空间在还原或清除后释放）")
    return 0
}

func cmdPurge() -> Int32 {
    let core = makeCore()
    let (purged, skippedUnknown) = core.quarantine.purge(olderThanDays: 7, now: Date())
    if purged.isEmpty {
        print("没有超过 7 天的隔离批次")
    } else {
        for id in purged { print("已清除批次 \(id)") }
        core.audit.append(AuditEvent(op: "purge", detail: "batches=\(purged.joined(separator: ","))"))
    }
    for path in skippedUnknown { print("跳过无法解析的隔离目录（不会删除）：\(path)") }
    return 0
}

func cmdRules(_ args: [String]) -> Int32 {
    let core = makeCore()
    guard let rulesFile = loadRules(core: core) else { return 2 }
    if args.contains("--json") {
        print(String(decoding: (try? jsonEncoder().encode(rulesFile)) ?? Data("{}".utf8), as: UTF8.self))
    } else {
        print("规则文件：\(rulesPath)（version \(rulesFile.version)，\(rulesFile.rules.count) 条）")
        for rule in rulesFile.rules {
            print("  \(rule.risk.symbol) \(ByteFormatting.padded(rule.name, to: 30))[\(rule.id)] \(rule.strategy.type.rawValue)")
            print("      \(rule.explain)")
        }
    }
    return 0
}

// MARK: 入口

let args = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32
if let command = args.first {
    let rest = Array(args.dropFirst())
    switch command {
    case "scan": exitCode = cmdScan(rest)
    case "plan": exitCode = cmdPlan(rest)
    case "apply": exitCode = cmdApply(rest)
    case "restore": exitCode = cmdRestore(rest)
    case "quarantine": exitCode = cmdQuarantine()
    case "purge": exitCode = cmdPurge()
    case "rules": exitCode = cmdRules(rest)
    case "help", "--help", "-h": print(usage); exitCode = 0
    default:
        fputs("未知命令：\(command)\n\n\(usage)\n", stderr)
        exitCode = 1
    }
} else {
    print(usage)
    exitCode = 0
}
exit(exitCode)
```

## 任务 13：冒烟测试

真机全量扫描耗时可控（本机 27.8s），但为保持 `swift test` 默认快速，真机用例以 `DCLEAN_SMOKE=1` 门控；快速回归用例（禁区误报回归、内置规则合法性）始终运行。

```swift
import XCTest
@testable import CleanerCore

/// 冒烟测试（spec §10 末行）：对真实 home 仅执行 scan（纯只读），断言不崩溃且 report.json 可解析。
/// 全量真实扫描较慢，设 DCLEAN_SMOKE=1 时才跑；快速回归用例始终运行。
final class SmokeTests: XCTestCase {
    func testRealHomePathsAreNotFalsePositiveForbidden() throws {
        // 修正「/Users 前缀匹配」bug 的真机回归：真实 home 下的缓存路径必须合法
        let files = RealFileOperations()
        let safety = PathSafety(home: NSHomeDirectory(), files: files)
        XCTAssertNoThrow(try safety.assertAllowed(NSHomeDirectory() + "/.cache/uv"))
        XCTAssertNoThrow(try safety.assertAllowed(NSHomeDirectory() + "/Library/Caches/pip"))
        XCTAssertThrowsError(try safety.assertAllowed("/Users"))
        XCTAssertThrowsError(try safety.assertAllowed(NSHomeDirectory() + "/Documents/x"))
    }

    func testBundledRulesDecodeOnThisMachine() throws {
        let rulesFile = try RuleStore.decodeDefaults(from: BundledRules.data())
        XCTAssertTrue(validateRules(rulesFile.rules).isEmpty)
    }

    func testRealHomeReadOnlyScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DCLEAN_SMOKE"] == "1",
                          "设 DCLEAN_SMOKE=1 运行真机全量扫描（纯只读）")
        let home = NSHomeDirectory()
        let files = RealFileOperations()
        let safety = PathSafety(home: home, files: files)
        let rulesFile = try RuleStore.decodeDefaults(from: BundledRules.data())
        let report = Scanner(files: files, safety: safety).scan(rules: rulesFile.rules)

        XCTAssertFalse(report.entries.isEmpty)
        for entry in report.entries {
            guard case .configError = entry.status else { continue }
            XCTFail("真机扫描不应出现配置错误：\(entry.ruleId)")
        }
        // report.json 可解析（写入临时目录，不污染 ~/.dclean）
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(Report.self, from: data))

        // 冒烟断言：真机上确实发现了可回收空间（规则覆盖到了实际存在的缓存）
        XCTAssertGreaterThan(report.entries(withRisk: .green).reduce(0) { $0 + $1.sizeBytes }, 0)
    }
}
```

```swift
import Foundation
import XCTest
@testable import CleanerCore

enum TestEnv {
    static func makeTempDir(_ label: String = "dclean") -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func write(_ content: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    /// 以 root 为根批量造文件；key 为相对路径。
    static func makeTree(root: String, files: [String: String]) throws {
        for (rel, content) in files {
            let p = root + "/" + rel
            try FileManager.default.createDirectory(
                atPath: (p as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try write(content, to: p)
        }
    }

    static func setMTime(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    static func daysAgo(_ n: Double, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-n * 86_400)
    }
}

/// guard 与 command 策略的单测注入点。
final class FakeProcessRunner: ProcessRunner {
    var handler: ((String, [String]) -> ProcessResult?)?
    private(set) var calls: [(launchPath: String, arguments: [String])] = []

    func run(launchPath: String, arguments: [String]) -> ProcessResult? {
        calls.append((launchPath, arguments))
        return handler?(launchPath, arguments)
    }
}
```

---

## 测试结果

```
Executed 74 tests, with 1 test skipped and 0 failures (0 unexpected)
```

真机（macOS 26.0, arm64, Swift 6.2.4）只读扫描实测：

```
磁盘 413.6 GB / 460.4 GB · 可用 46.8 GB（90% 已用）
🟢 直接清理  28.0 GB   （uv 19.4G · pip 3.1G · playwright 4.0G · brew 1.1G · …）
🟡 隔离 7 天后删除  7.4 GB（codex 会话 4.5G · claude 插件旧版本 2.8G · …）
🔴 需手动处理（只看）约 50.2 GB（Docker.raw 20.7G · Chrome SW 17.5G · Claude 12.0G；逻辑大小口径曾误报 489.9G，已修正为 du 口径）
```

## 任务 14：菜单栏 GUI（DiskCleanerApp）

MenuBarExtra 壳（macOS 13+，LSUIElement 不占 Dock）。GUI 不含任何删除逻辑：渲染 Report、收集勾选、调用 CleanerCore（spec §3）。

- `RingIcon.swift`：环形占用指示器，>20% 可用灰 / 10–20% 黄 / <10% 红（spec §8）
- `Engine.swift`：引擎装配与共享路径（与 CLI 同一套 ~/.dclean 数据流）
- `AppState.swift`：所有引擎调用都在后台 Task；扫描后跑一次计划预览拿守卫 blocked 状态驱动 UI 的 ⚠ 行
- `ContentView.swift`：磁盘概览 + 三风险分组（红组只读展示 explain）+ 隔离区（还原/清除已过期）+ 确认入口
- `ConfirmViews.swift`：确认单（完整路径 + 大小 + 立即删除/移入隔离区，仅 取消/确认 两按钮，无输入框摩擦）与执行结果页（✓/↷/✗）

打包：`Scripts/make-app.sh` → `build/DiskCleaner.app`（release 构建 + Info.plist + ad-hoc 签名）。

**与 spec 的一处偏差**：launchd 定时扫描暂缓期间，「重新扫描」按钮由 GUI 进程内后台 Task 直接跑 Scanner（utility QoS），并照常写 `~/.dclean/report.json`，与 CLI/后续 launchd 共用同一数据流；UI 不阻塞。launchd 落地后此按钮可切换为拉起 `dclean scan --write-report` 子进程。

## 下一阶段（不在本计划内）

1. launchd agent：`com.example.dclean.scan.plist`，每天 13:07 `dclean scan --write-report`（GUI 的 DispatchSource 文件监听刷新图标随此落地）
2. App 图标文件与 DMG 发布
