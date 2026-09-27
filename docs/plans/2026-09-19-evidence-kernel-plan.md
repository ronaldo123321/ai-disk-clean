# 证据内核（阶段一）实施计划

> **后续验收更新**：真实目录只读对照通过（17 条规则、4 个计划条目，候选路径与动作一致）；全量 184 项、2 跳过、0 失败，另启用真机 smoke 4 项全通过。独立 GUI 应用启动并扫描成功，点击/截图验收受系统权限限制，仍未完成。详情见 `../v2/12-证据内核真机只读与GUI启动验收.md`。下面此前记录保留为历史。

> **2026-09-19 接续状态（以本段及验收记录为准）**：Tasks 1–16 对应的阶段一代码已实现，debug/release 构建通过；最终测试 183 项，跳过 2 项，0 失败。真实用户目录候选对照、GUI 交互验收、应用安装与 git 提交尚未执行。详细变更及偏差见 `../v2/11-证据内核阶段一接续与验证.md`。
>
> 下文保留原始实施配方，不表示逐条命令原样执行。实际实现沿用 `epochSeconds`；年龄证据已加入执行时重采集；路径日期需显式启用；外部规则证据不授予权限。原文“陈旧度只会增强”与“阶段一不重采集”不适用于本次实现。规则占位时间不可作为候选观测；资格矩阵由运行时边界强制，不是 Swift 类型系统本身保证。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用「证据强度 × 动作可逆性」推导出的处理资格，取代手写的 `Rule.risk` 红黄绿字段，且不改变任何规则的可处理性与执行动作。

**Architecture:** 新增 `Evidence`（四类可核验证据）与 `EligibilityEvaluator`（推导处理资格）。采用**并行运行后切换**：先让适配器在保留 `risk` 的同时产出证据，用等价性测试证明推导结果与现行行为一致，再逐个切换消费方，最后移除 `risk`。这样每个任务结束时构建都是绿的，且任何行为偏移都会被等价性测试当场抓住。

**Tech Stack:** Swift 5.10 / SwiftPM / XCTest。测试用 `InMemoryFileOperations` 假文件树与 `FakeProcessRunner`，均已存在于 `Tests/CleanerCoreTests/TestSupport.swift`。

**依据：** `docs/specs/2026-09-19-evidence-model-design.md`

---

## 范围说明

spec §5.2 列阶段一交付三个采集器。本计划只建**陈旧度**一个，理由是 YAGNI：

- `staleness` —— 阶段一必须有。`diagnostic-reports`（30 天）与 `downloaded-disk-images`（60 天）没有适配器，其唯一依据就是陈旧度。不建它，这两条规则会因无证据退为只读，属回退。
- `versionRedundancy` / `referenceUnreachable` —— 阶段一无任何规则使用（用到它们的四条新规则都在阶段二）。建了也没有真实使用者可验证，随阶段二一起交付。

`toolAuthority` 不需要独立采集器：适配器本身就是它的采集器，现有代码已在做版本查询与标记检查。

### `risk` 字段在本阶段只卸掉一半职责

写计划时发现 `Rule.risk` 实际身兼两职：

1. **表达信心**（red = 不可信 → 只读）—— 本阶段由证据取代
2. **选择动作**（yellow → quarantine，green → delete/command）—— 本阶段**保留**

只做第 1 项。原因：第 2 项需要一个独立的动作意图字段来接替，而这会牵动 `PlannerExecutorTests` 中以 `risk: .green` + `deleteDir` 表达「直接删除」的夹具。把两件事塞进同一阶段，等价性护栏就同时有两个变量在动，出问题无法定位。

因此阶段一结束时 `risk` 仍存在，但**只作为动作选择器**，不再参与任何资格判定。阶段二引入显式动作意图字段后再移除。

顺带记录一个观察：经 `V2Policy` 处理后，**生产环境中没有任何规则会产生 `.delete` 动作**——可处理的规则要么是 globAge/deleteDir 配 yellow（→ quarantine），要么是 command。`.delete` 只出现在测试夹具里。这条留给阶段二决定是否直接取消该动作类型。

### spec §4.3 的逐候选证据重采集延后

spec 要求 apply 前重采集证据。本阶段**只做规则级重评定**（Task 14），不做逐候选重采集，理由是本阶段在用的两类证据都不需要：

- `toolAuthority` —— `rulesProvider` 在 apply 时会重跑适配器，版本或标记消失自然失去证据
- `staleness` —— 时间单向前进，陈旧度只会增强，不会在计划与执行之间消失

逐候选重采集随 `referenceUnreachable` 一起在阶段二交付——「项目被恢复导致孤儿证据失效」正是它的动机场景。

## 文件结构

**新建**

| 文件 | 职责 |
|---|---|
| `Sources/CleanerCore/Evidence.swift` | `Evidence`、`Evidence.Strength`、`Eligibility`、`EligibilityEvaluator`。纯数据与纯函数，不碰文件系统 |
| `Sources/CleanerCore/Staleness.swift` | 陈旧度采集器。从路径编码日期或 mtime 得出日期并与阈值比较 |
| `Tests/CleanerCoreTests/EvidenceTests.swift` | 资格矩阵穷举、不可表达组合、证据强度 |
| `Tests/CleanerCoreTests/StalenessTests.swift` | 陈旧度采集器边界 |
| `Tests/CleanerCoreTests/EligibilityEquivalenceTests.swift` | 等价性护栏：推导资格 ≡ 现行 risk 行为 |

**修改**

| 文件 | 改动 |
|---|---|
| `Sources/CleanerCore/Models.swift` | `Rule` 加 `evidence`；`ReportEntry` 加 `eligibility`；`PlanItem` 加 `eligibility`；`PlanAction` 加 `isReversible`；删 `Strategy.isCompatible` |
| `Sources/CleanerCore/PipCacheAdapter.swift` | 产出 `toolAuthority(.enumeration)` |
| `Sources/CleanerCore/CommandCacheAdapters.swift` | uv / Homebrew 产出 `toolAuthority(.cleanupCommand)` |
| `Sources/CleanerCore/BrowserCacheAdapters.swift` | Playwright / Puppeteer 产出 `toolAuthority(.installationMarker)` |
| `Sources/CleanerCore/V2Policy.swift` | glob-age 规则产出 `staleness`；删除强制 `.red` 的迁移 hack |
| `Sources/CleanerCore/Scanner.swift` | 填充 `ReportEntry.eligibility` |
| `Sources/CleanerCore/Planner.swift` | 用 eligibility 取代 risk 判定，动作由可逆性推导 |
| `Sources/CleanerCore/Executor.swift` | 边界校验改用 eligibility |
| `Sources/DiskCleanerApp/ContentView.swift` | `category()` 按 eligibility 分类，补「推荐」分类 |
| `Sources/DiskCleanerApp/AppState.swift`、`ConfirmViews.swift` | 统计与确认单改用 eligibility |
| `Sources/dclean/main.swift` | 输出改用 eligibility |

---

### Task 1: Evidence 类型与强度

**Files:**
- Create: `Sources/CleanerCore/Evidence.swift`
- Test: `Tests/CleanerCoreTests/EvidenceTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/CleanerCoreTests/EvidenceTests.swift`：

```swift
import XCTest
@testable import CleanerCore

/// 证据模型：强度分级与资格推导矩阵（spec §2.2、§3）
final class EvidenceTests: XCTestCase {
    func testStrongEvidenceTypes() {
        XCTAssertEqual(Evidence.versionRedundancy(family: "chromium", version: "1187", newest: "1208").strength, .strong)
        XCTAssertEqual(Evidence.referenceUnreachable(referent: "/gone").strength, .strong)
        XCTAssertEqual(Evidence.toolAuthority(tool: "pip", version: "24.3.1",
                                              basis: .enumeration(interface: "cache list")).strength, .strong)
    }

    func testStalenessIsWeakRegardlessOfSource() {
        let path = Evidence.staleness(date: Date(timeIntervalSince1970: 0), source: .pathEncoded, thresholdDays: 90)
        let mtime = Evidence.staleness(date: Date(timeIntervalSince1970: 0), source: .modificationTime, thresholdDays: 90)
        XCTAssertEqual(path.strength, .weak)
        XCTAssertEqual(mtime.strength, .weak, "mtime 来源同样是弱证据，不因来源不同而升级")
    }

    func testEvidenceRoundTripsThroughCodable() throws {
        let original: [Evidence] = [
            .versionRedundancy(family: "claude-mem", version: "1.2.0", newest: "1.3.0"),
            .staleness(date: Date(timeIntervalSince1970: 1_700_000_000), source: .pathEncoded, thresholdDays: 90),
        ]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([Evidence].self, from: data), original)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter EvidenceTests 2>&1 | tail -5`
Expected: 编译失败，`cannot find 'Evidence' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/CleanerCore/Evidence.swift`：

```swift
import Foundation

// MARK: - 证据（spec §3）

/// 可机械核验的清理证据。每条证据都能在扫描期与 apply 期各采集一次，
/// 采集失败一律视为无证据（失败关闭），绝不假定无问题。
public enum Evidence: Codable, Equatable, Sendable {
    /// 版本冗余：同一物件多版本并存，本候选不是最新（阶段二启用）
    case versionRedundancy(family: String, version: String, newest: String)
    /// 引用不可达：候选指涉的对象已不存在，且其所在卷已挂载（阶段二启用）
    case referenceUnreachable(referent: String)
    /// 工具权威：工具自身产出的可核验凭据
    case toolAuthority(tool: String, version: String, basis: AuthorityBasis)
    /// 陈旧度：日期早于阈值。弱证据，只能驱动可逆动作
    case staleness(date: Date, source: StalenessSource, thresholdDays: Int)

    /// 工具权威的三种依据（spec §3.4）。共同要求：凭据由工具自身产出且可复现获取，
    /// 不接受「目录名叫 Cache 所以能删」这类从命名推断的猜测。
    public enum AuthorityBasis: Codable, Equatable, Sendable {
        /// 工具公开接口枚举出的具体路径，如 pip cache list --format=abspath
        case enumeration(interface: String)
        /// 官方清理命令负责判定与执行，如 uv cache prune
        case cleanupCommand(command: [String])
        /// 官方布局 + 工具写入的完整性标记，且有官方下载源可重建
        case installationMarker(marker: String, layout: String)
    }

    /// 陈旧度的日期来源。路径编码比 mtime 可信（备份、同步、touch 都会改写 mtime），
    /// 但两者都是弱证据——差异如实记录并展示，不隐藏。
    public enum StalenessSource: String, Codable, Sendable {
        case pathEncoded
        case modificationTime
    }

    public enum Strength: String, Codable, Sendable {
        case strong
        case weak
    }

    /// 强证据可驱动不可逆动作；弱证据只能驱动可逆动作（spec §2.2）。
    public var strength: Strength {
        switch self {
        case .versionRedundancy, .referenceUnreachable, .toolAuthority:
            return .strong
        case .staleness:
            return .weak
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter EvidenceTests 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Evidence.swift Tests/CleanerCoreTests/EvidenceTests.swift
git commit -m "feat(evidence): 证据类型与强度分级"
```

---

### Task 2: 动作可逆性

**Files:**
- Modify: `Sources/CleanerCore/Models.swift`（`PlanAction` 定义在第 326-331 行附近）
- Test: `Tests/CleanerCoreTests/EvidenceTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/EvidenceTests.swift` 的 `EvidenceTests` 类内追加：

```swift
    func testOnlyQuarantineIsReversible() {
        XCTAssertTrue(PlanAction.quarantine.isReversible, "移废纸篓可还原")
        XCTAssertFalse(PlanAction.delete.isReversible)
        XCTAssertFalse(PlanAction.truncate.isReversible, "清空内容无法还原原始内容")
        XCTAssertFalse(PlanAction.runCommand(["uv", "cache", "prune"]).isReversible,
                       "命令的作用范围不由本工具控制，一律视为不可逆")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testOnlyQuarantineIsReversible 2>&1 | tail -5`
Expected: 编译失败，`value of type 'PlanAction' has no member 'isReversible'`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Models.swift` 中 `public enum PlanAction` 的闭合大括号之后追加：

```swift
extension PlanAction {
    /// 仅移入废纸篓可还原。删除、清空、命令一律不可逆——命令的作用范围
    /// 由外部工具决定，本工具无法保证可还原（spec §2.2）。
    public var isReversible: Bool {
        if case .quarantine = self { return true }
        return false
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter testOnlyQuarantineIsReversible 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Models.swift Tests/CleanerCoreTests/EvidenceTests.swift
git commit -m "feat(evidence): PlanAction 可逆性判定"
```

---

### Task 3: 资格推导与不可表达组合

这是整个重构的核心不变量：**弱证据配不可逆动作在引擎里无法构造**。

**Files:**
- Modify: `Sources/CleanerCore/Evidence.swift`
- Test: `Tests/CleanerCoreTests/EvidenceTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/EvidenceTests.swift` 的 `EvidenceTests` 类内追加：

```swift
    private let strong = Evidence.toolAuthority(tool: "pip", version: "24.3.1",
                                                basis: .enumeration(interface: "cache list"))
    private let weak = Evidence.staleness(date: Date(timeIntervalSince1970: 0),
                                          source: .pathEncoded, thresholdDays: 90)

    func testStrongEvidenceWithReversibleActionIsRecommended() {
        XCTAssertEqual(EligibilityEvaluator.evaluate(evidence: [strong], action: .quarantine), .recommended)
    }

    func testStrongEvidenceWithIrreversibleActionNeedsConfirmation() {
        XCTAssertEqual(EligibilityEvaluator.evaluate(evidence: [strong], action: .delete), .needsConfirmation)
        XCTAssertEqual(EligibilityEvaluator.evaluate(evidence: [strong], action: .runCommand(["brew", "cleanup"])),
                       .needsConfirmation)
    }

    func testWeakEvidenceWithReversibleActionNeedsConfirmation() {
        XCTAssertEqual(EligibilityEvaluator.evaluate(evidence: [weak], action: .quarantine), .needsConfirmation)
    }

    func testWeakEvidenceWithIrreversibleActionIsNotExpressible() {
        // 核心不变量：不是提示，是根本无法构造。调用方拿到 nil 必须 abort。
        XCTAssertNil(EligibilityEvaluator.evaluate(evidence: [weak], action: .delete))
        XCTAssertNil(EligibilityEvaluator.evaluate(evidence: [weak], action: .truncate))
        XCTAssertNil(EligibilityEvaluator.evaluate(evidence: [weak], action: .runCommand(["uv", "cache", "prune"])))
    }

    func testMixedEvidenceUsesStrongest() {
        // 同时具备强弱证据时按强证据评定：弱证据不拖累已被强证据证明的候选
        XCTAssertEqual(EligibilityEvaluator.evaluate(evidence: [weak, strong], action: .delete), .needsConfirmation)
    }

    func testNoEvidenceIsDisplayOnly() {
        let result = EligibilityEvaluator.evaluate(evidence: [], action: .quarantine)
        guard case .displayOnly = result else { return XCTFail("无证据必须只读，实际：\(String(describing: result))") }
        XCTAssertTrue(result?.isDisplayOnly == true)
        XCTAssertFalse(result?.isActionable == true)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter EvidenceTests 2>&1 | tail -5`
Expected: 编译失败，`cannot find 'EligibilityEvaluator' in scope`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Evidence.swift` 末尾追加：

```swift
// MARK: - 处理资格（spec §2.2）

/// 由证据推导，不再手写。取代原 RiskLevel 的红黄绿。
public enum Eligibility: Codable, Equatable, Sendable {
    /// 强证据 + 可逆动作
    case recommended
    /// 强证据 + 不可逆动作，或 弱证据 + 可逆动作
    case needsConfirmation
    /// 无证据。附缺失说明，让用户知道为什么只能看
    case displayOnly(missing: String)

    public var isDisplayOnly: Bool {
        if case .displayOnly = self { return true }
        return false
    }

    public var isActionable: Bool { !isDisplayOnly }
}

/// 证据强度 × 动作可逆性 → 处理资格。纯函数，无副作用。
public enum EligibilityEvaluator {
    /// - Returns: nil 表示该组合**不可表达**（弱证据配不可逆动作）。调用方必须 abort，
    ///   不得降级处理——这是 spec §2.2 的核心不变量，保证「强制可逆」是类型层面的
    ///   保证而非文档约定。
    public static func evaluate(evidence: [Evidence], action: PlanAction) -> Eligibility? {
        guard !evidence.isEmpty else {
            return .displayOnly(missing: "尚无可核验证据：需要版本冗余、引用不可达、工具权威或陈旧度中的至少一项")
        }
        let strongest: Evidence.Strength = evidence.contains { $0.strength == .strong } ? .strong : .weak
        switch (strongest, action.isReversible) {
        case (.strong, true):
            return .recommended
        case (.strong, false), (.weak, true):
            return .needsConfirmation
        case (.weak, false):
            return nil
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter EvidenceTests 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Evidence.swift Tests/CleanerCoreTests/EvidenceTests.swift
git commit -m "feat(evidence): 资格推导与不可表达组合"
```

---

### Task 4: 陈旧度采集器

**Files:**
- Create: `Sources/CleanerCore/Staleness.swift`
- Test: `Tests/CleanerCoreTests/StalenessTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/CleanerCoreTests/StalenessTests.swift`：

```swift
import XCTest
@testable import CleanerCore

/// 陈旧度采集器（spec §3.3）：优先用路径编码日期，回退 mtime，来源如实记录。
final class StalenessTests: XCTestCase {
    private var files: InMemoryFileOperations!
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 附近

    override func setUp() {
        files = InMemoryFileOperations(home: "/Users/fixture")
    }

    func testPathEncodedDateIsPreferredOverModificationTime() {
        // 路径里的日期是 2026-06-07，而 mtime 被改写成「刚刚」——必须以路径为准
        let path = files.makeFile("/Users/fixture/.codex/sessions/2026/06/07/rollout-a.jsonl",
                                  size: 10, modifiedAt: now)
        let evidence = StalenessCollector.collect(path: path, thresholdDays: 90, now: now, files: files)
        guard case .staleness(let date, let source, let threshold)? = evidence else {
            return XCTFail("应产出陈旧度证据，实际：\(String(describing: evidence))")
        }
        XCTAssertEqual(source, .pathEncoded, "路径编码日期可信度高于 mtime，必须优先")
        XCTAssertEqual(threshold, 90)
        var components = DateComponents(); components.year = 2026; components.month = 6; components.day = 7
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date),
                       Calendar(identifier: .gregorian).dateComponents([.year, .month, .day],
                                                                       from: Calendar(identifier: .gregorian).date(from: components)!))
    }

    func testFallsBackToModificationTimeWhenPathHasNoDate() {
        let old = now.addingTimeInterval(-200 * 86_400)
        let path = files.makeFile("/Users/fixture/Downloads/installer.dmg", size: 10, modifiedAt: old)
        let evidence = StalenessCollector.collect(path: path, thresholdDays: 60, now: now, files: files)
        guard case .staleness(_, let source, _)? = evidence else {
            return XCTFail("应回退 mtime 并产出证据")
        }
        XCTAssertEqual(source, .modificationTime, "无路径日期时回退 mtime，且来源必须如实标记")
    }

    func testRecentFileProducesNoEvidence() {
        let path = files.makeFile("/Users/fixture/Downloads/fresh.dmg", size: 10,
                                  modifiedAt: now.addingTimeInterval(-10 * 86_400))
        XCTAssertNil(StalenessCollector.collect(path: path, thresholdDays: 60, now: now, files: files),
                     "未超过阈值不得产出证据")
    }

    func testMissingFileProducesNoEvidence() {
        XCTAssertNil(StalenessCollector.collect(path: "/Users/fixture/gone.dmg",
                                                thresholdDays: 60, now: now, files: files),
                     "采集失败一律视为无证据（失败关闭）")
    }

    func testImplausiblePathDateIsIgnoredAndFallsBack() {
        // 路径里是 2026/13/45 这种非法日期，不能当成日期用，必须回退 mtime
        let old = now.addingTimeInterval(-200 * 86_400)
        let path = files.makeFile("/Users/fixture/.codex/sessions/2026/13/45/rollout-b.jsonl",
                                  size: 10, modifiedAt: old)
        let evidence = StalenessCollector.collect(path: path, thresholdDays: 90, now: now, files: files)
        guard case .staleness(_, let source, _)? = evidence else { return XCTFail("应回退 mtime") }
        XCTAssertEqual(source, .modificationTime)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter StalenessTests 2>&1 | tail -5`
Expected: 编译失败，`cannot find 'StalenessCollector' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/CleanerCore/Staleness.swift`：

```swift
import Foundation

// MARK: - 陈旧度采集器（spec §3.3）

/// 弱证据。产出即意味着候选只能配可逆动作（由 EligibilityEvaluator 保证）。
public enum StalenessCollector {
    /// 从路径中连续的 `/YYYY/MM/DD/` 段解析日期。比 mtime 可信——备份、同步与 touch
    /// 都会改写 mtime，但不会重排目录结构。
    static func pathEncodedDate(_ path: String) -> Date? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        for index in 0...(segments.count - 3) {
            guard let year = Int(segments[index]), segments[index].count == 4, (2000...2100).contains(year),
                  let month = Int(segments[index + 1]), segments[index + 1].count == 2, (1...12).contains(month),
                  let day = Int(segments[index + 2]), segments[index + 2].count == 2, (1...31).contains(day)
            else { continue }
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            // date(from:) 对 2026/02/31 这类不存在的日期仍会换算，故用回读校验
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month else { continue }
            return date
        }
        return nil
    }

    /// 采集失败（文件不存在、无日期可得、未超阈值）一律返回 nil = 无证据。
    public static func collect(path: String, thresholdDays: Int, now: Date = Date(),
                               files: FileOperations) -> Evidence? {
        guard let attributes = files.attributesIfExist(atPath: path) else { return nil }
        let cutoff = now.addingTimeInterval(-Double(thresholdDays) * 86_400)
        if let encoded = pathEncodedDate(path) {
            guard encoded < cutoff else { return nil }
            return .staleness(date: encoded, source: .pathEncoded, thresholdDays: thresholdDays)
        }
        guard let modified = attributes.modificationDate, modified < cutoff else { return nil }
        return .staleness(date: modified, source: .modificationTime, thresholdDays: thresholdDays)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter StalenessTests 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Staleness.swift Tests/CleanerCoreTests/StalenessTests.swift
git commit -m "feat(evidence): 陈旧度采集器，路径编码日期优先于 mtime"
```

---

### Task 5: Rule 携带证据（纯追加，暂无消费方）

**Files:**
- Modify: `Sources/CleanerCore/Models.swift`（`public struct Rule` 第 121-142 行）
- Test: `Tests/CleanerCoreTests/EvidenceTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/EvidenceTests.swift` 的 `EvidenceTests` 类内追加：

```swift
    func testRuleCarriesEvidenceAndDefaultsToEmpty() throws {
        var rule = Rule(id: "r", name: "r", risk: .yellow, roots: ["~/x"],
                        strategy: Strategy(type: .deleteDir), explain: "e")
        XCTAssertEqual(rule.evidence, [], "默认无证据——规则必须显式证明自己")
        rule.evidence = [.staleness(date: Date(timeIntervalSince1970: 0), source: .pathEncoded, thresholdDays: 30)]
        let decoded = try JSONDecoder().decode(Rule.self, from: try JSONEncoder().encode(rule))
        XCTAssertEqual(decoded.evidence, rule.evidence)
    }

    func testLegacyRuleJSONWithoutEvidenceStillDecodes() throws {
        // 用户的 rules.json 没有 evidence 字段，必须照常解码（spec §4.1）
        let json = """
        {"id":"legacy","name":"旧规则","risk":"yellow","roots":["~/x"],
         "strategy":{"type":"delete-dir"},"explain":"e"}
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.id, "legacy")
        XCTAssertEqual(rule.evidence, [])
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testRuleCarriesEvidenceAndDefaultsToEmpty 2>&1 | tail -5`
Expected: 编译失败，`value of type 'Rule' has no member 'evidence'`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Models.swift` 的 `public struct Rule` 中，`adapterEvidence` 声明之后追加属性，并在 `init` 末尾保持默认值：

```swift
    /// 本规则为其候选产出的可核验证据。空数组 = 无证据 = 只读展示。
    /// 解码缺省为空，兼容用户已有的 rules.json（spec §4.1）。
    public var evidence: [Evidence] = []
```

`Rule` 已有的 `init` 不接受 `evidence` 参数，属性默认值即可；`Codable` 合成会把缺失字段填为默认值——**需确认 Swift 版本行为**：Swift 5.10 的合成 `init(from:)` 对有默认值的属性仍要求字段存在。因此必须显式实现解码。在 `Rule` 内追加：

```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, risk, roots, strategy, guards, explain, candidateAllowlist, adapterEvidence, evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        risk = try container.decode(RiskLevel.self, forKey: .risk)
        roots = try container.decode([String].self, forKey: .roots)
        strategy = try container.decode(Strategy.self, forKey: .strategy)
        guards = try container.decodeIfPresent([GuardSpec].self, forKey: .guards)
        explain = try container.decode(String.self, forKey: .explain)
        candidateAllowlist = try container.decodeIfPresent([String].self, forKey: .candidateAllowlist)
        adapterEvidence = try container.decodeIfPresent(String.self, forKey: .adapterEvidence)
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
    }
```

- [ ] **Step 4: 运行全量测试确认无回归**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: `Executed 165 tests, with 2 tests skipped and 0 failures`（159 原有 + 本任务累计新增；关键是 0 failures，不必逐字对数）

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Models.swift Tests/CleanerCoreTests/EvidenceTests.swift
git commit -m "feat(evidence): Rule 携带证据，兼容无该字段的用户规则文件"
```

---

### Task 6: pip 适配器产出工具权威证据

**Files:**
- Modify: `Sources/CleanerCore/PipCacheAdapter.swift:50-55`
- Test: `Tests/CleanerCoreTests/PipCacheAdapterTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/PipCacheAdapterTests.swift` 的测试类内追加：

```swift
    func testVerifiedPipProducesEnumerationEvidence() throws {
        // 复用本文件既有夹具构造「已验证 pip」场景后，断言证据形态
        let rule = verifiedPipRule()
        guard case .toolAuthority(let tool, let version, let basis)? = rule.evidence.first else {
            return XCTFail("已验证的 pip 必须产出工具权威证据，实际：\(rule.evidence)")
        }
        XCTAssertEqual(tool, "pip")
        XCTAssertEqual(version, "24.3.1")
        guard case .enumeration(let interface) = basis else {
            return XCTFail("pip 的依据是公开接口枚举，实际：\(basis)")
        }
        XCTAssertTrue(interface.contains("cache list"), interface)
        XCTAssertEqual(rule.evidence.first?.strength, .strong)
    }

    func testUnverifiedPipProducesNoEvidence() {
        let rule = PipCacheAdapter.rule(files: files, runner: runner, executable: nil)
        XCTAssertEqual(rule.evidence, [], "未发现 pip 时不得产出任何证据")
    }
```

在同一文件内新增辅助方法（放在测试类内、其他 helper 旁）：

```swift
    /// 构造「pip 24.3.1 已验证 + cache list 返回一个 wheel」的规则。
    /// 本测试类的 files 是 RealFileOperations + 临时 home，故用 TestEnv 造真实文件树。
    private func verifiedPipRule() throws -> Rule {
        let relative = "Library/Caches/pip/wheels/ab/cd/pkg-1.0-py3-none-any.whl"
        try TestEnv.makeTree(root: home, files: [relative: "wheel"])
        let cacheDir = home + "/Library/Caches/pip"
        let wheel = home + "/" + relative
        runner.handler = { _, args in
            if args.contains("--version") { return ProcessResult(exitStatus: 0, stdout: "pip 24.3.1", stderr: "") }
            if args.contains("dir") { return ProcessResult(exitStatus: 0, stdout: cacheDir, stderr: "") }
            if args.contains("list") { return ProcessResult(exitStatus: 0, stdout: wheel, stderr: "") }
            return nil
        }
        return PipCacheAdapter.rule(files: files, runner: runner, executable: "/usr/bin/pip3")
    }
```

`verifiedPipRule` 会抛错，故上面第一个测试的签名改为 `func testVerifiedPipProducesEnumerationEvidence() throws`，调用处写 `let rule = try verifiedPipRule()`。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testVerifiedPipProducesEnumerationEvidence 2>&1 | tail -5`
Expected: FAIL，`已验证的 pip 必须产出工具权威证据，实际：[]`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/PipCacheAdapter.swift` 第 54 行 `rule.risk = .yellow` 之前插入：

```swift
        rule.evidence = [.toolAuthority(tool: "pip", version: String(version),
                                        basis: .enumeration(interface: "pip cache list --format=abspath"))]
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter PipCacheAdapterTests 2>&1 | grep -E "error:|Executed"`
Expected: 全部通过，含新增 2 条

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/PipCacheAdapter.swift Tests/CleanerCoreTests/PipCacheAdapterTests.swift
git commit -m "feat(evidence): pip 适配器产出枚举型工具权威证据"
```

---

### Task 7: uv 与 Homebrew 适配器产出命令型证据

**Files:**
- Modify: `Sources/CleanerCore/CommandCacheAdapters.swift:57-60`（uv）、`:111-115`（Homebrew）
- Test: `Tests/CleanerCoreTests/CommandCacheAdapterTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/CommandCacheAdapterTests.swift` 的测试类内追加：

```swift
    func testVerifiedUVProducesCleanupCommandEvidence() {
        let rule = verifiedUVRule()
        guard case .toolAuthority(let tool, _, let basis)? = rule.evidence.first else {
            return XCTFail("已验证的 uv 必须产出工具权威证据，实际：\(rule.evidence)")
        }
        XCTAssertEqual(tool, "uv")
        guard case .cleanupCommand(let command) = basis else {
            return XCTFail("uv 的依据是官方清理命令，实际：\(basis)")
        }
        XCTAssertEqual(command.dropFirst().map(String.init), ["cache", "prune"],
                       "证据里的命令必须与规则实际执行的命令逐字一致")
        XCTAssertEqual(command, rule.strategy.cmd)
    }

    func testUntestedVersionProducesNoEvidence() {
        let rule = uvRule(version: "9.9.9")
        XCTAssertEqual(rule.evidence, [], "未验证版本不得产出证据，保持只读")
    }
```

在同一文件内新增两个辅助方法：

```swift
    /// 构造指定版本的 uv 规则（cache dir 指向已存在的目录）。
    /// 本测试类的 files 是 RealFileOperations + 临时 home，故直接建真实目录。
    private func uvRule(version: String) -> Rule {
        let cacheDir = home + "/.cache/uv"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        runner.handler = { _, args in
            if args == ["--version"] { return ProcessResult(exitStatus: 0, stdout: "uv \(version)", stderr: "") }
            if args == ["cache", "dir"] { return ProcessResult(exitStatus: 0, stdout: cacheDir, stderr: "") }
            return nil
        }
        return UVAdapter.rule(files: files, runner: runner, executable: "/opt/homebrew/bin/uv")
    }

    private func verifiedUVRule() -> Rule {
        uvRule(version: UVAdapter.testedVersions.sorted().first!)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testVerifiedUVProducesCleanupCommandEvidence 2>&1 | tail -5`
Expected: FAIL，`已验证的 uv 必须产出工具权威证据，实际：[]`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/CommandCacheAdapters.swift` 中，uv 的 `rule.risk = .green`（第 59 行）之前插入：

```swift
        rule.evidence = [.toolAuthority(tool: "uv", version: version,
                                        basis: .cleanupCommand(command: [executable, "cache", "prune"]))]
```

Homebrew 的 `rule.risk = .green`（第 114 行）之前插入：

```swift
        rule.evidence = [.toolAuthority(tool: "Homebrew", version: version,
                                        basis: .cleanupCommand(command: [executable, "cleanup", "-s"]))]
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter CommandCacheAdapterTests 2>&1 | grep -E "error:|Executed"`
Expected: 全部通过，含新增 2 条

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/CommandCacheAdapters.swift Tests/CleanerCoreTests/CommandCacheAdapterTests.swift
git commit -m "feat(evidence): uv 与 Homebrew 产出命令型工具权威证据"
```

---

### Task 8: 浏览器适配器产出标记型证据

**Files:**
- Modify: `Sources/CleanerCore/BrowserCacheAdapters.swift:52-54`（Playwright）、`:99-101`（Puppeteer）
- Test: `Tests/CleanerCoreTests/BrowserCacheAdapterTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/BrowserCacheAdapterTests.swift` 的测试类内追加：

```swift
    func testPlaywrightWithMarkerProducesInstallationMarkerEvidence() {
        let rule = playwrightRuleWithValidBrowser()
        guard case .toolAuthority(let tool, _, let basis)? = rule.evidence.first else {
            return XCTFail("带官方标记的 Playwright 必须产出工具权威证据，实际：\(rule.evidence)")
        }
        XCTAssertEqual(tool, "Playwright")
        guard case .installationMarker(let marker, _) = basis else {
            return XCTFail("Playwright 的依据是安装完成标记，实际：\(basis)")
        }
        XCTAssertEqual(marker, PlaywrightAdapter.installationMarker)
        XCTAssertEqual(rule.evidence.first?.strength, .strong)
    }

    func testPlaywrightWithoutMarkerProducesNoEvidence() {
        // 无标记目录既不该成为候选，也不该产出证据
        let rule = playwrightRuleWithoutMarker()
        XCTAssertEqual(rule.evidence, [])
        XCTAssertNil(rule.candidateAllowlist)
    }
```

在同一文件内新增辅助方法（`home` 为该测试类已有的临时目录属性）：

```swift
    private func playwrightRuleWithValidBrowser() -> Rule {
        try? TestEnv.makeTree(root: home, files: [
            "Library/Caches/ms-playwright/chromium-1187/\(PlaywrightAdapter.installationMarker)": "ok",
            "Library/Caches/ms-playwright/chromium-1187/chrome": "bin",
        ])
        return PlaywrightAdapter.rule(files: files, safety: safety)
    }

    private func playwrightRuleWithoutMarker() -> Rule {
        try? TestEnv.makeTree(root: home, files: ["Library/Caches/ms-playwright/chromium-1187/chrome": "bin"])
        return PlaywrightAdapter.rule(files: files, safety: safety)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testPlaywrightWithMarkerProducesInstallationMarkerEvidence 2>&1 | tail -5`
Expected: FAIL，`带官方标记的 Playwright 必须产出工具权威证据，实际：[]`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/BrowserCacheAdapters.swift` 中，Playwright 的 `rule.risk = .yellow`（第 53 行）之前插入：

```swift
        rule.evidence = [.toolAuthority(tool: "Playwright", version: "\(candidates.count) 个已验证安装",
                                        basis: .installationMarker(marker: Self.installationMarker,
                                                                   layout: "<浏览器名>-<构建号>"))]
```

Puppeteer 的 `rule.risk = .yellow`（第 100 行）之前插入：

```swift
        rule.evidence = [.toolAuthority(tool: "Puppeteer", version: "\(candidates.count) 个已验证安装",
                                        basis: .installationMarker(marker: "官方缓存布局",
                                                                   layout: "<browser>/<平台>-<版本>"))]
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter BrowserCacheAdapterTests 2>&1 | grep -E "error:|Executed"`
Expected: 全部通过，含新增 2 条

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/BrowserCacheAdapters.swift Tests/CleanerCoreTests/BrowserCacheAdapterTests.swift
git commit -m "feat(evidence): Playwright 与 Puppeteer 产出标记型工具权威证据"
```

---

### Task 9: glob-age 规则产出陈旧度证据

`diagnostic-reports`（30 天）与 `downloaded-disk-images`（60 天）没有适配器，唯一依据是陈旧度。不补这一步，它们会因无证据退为只读——属回退。

**Files:**
- Modify: `Sources/CleanerCore/V2Policy.swift:58-70`
- Test: `Tests/CleanerCoreTests/RuleStoreAuditTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/RuleStoreAuditTests.swift` 的 `RuleStoreTests` 类内追加：

```swift
    func testGlobAgeRulesCarryStalenessEvidence() throws {
        let files = InMemoryFileOperations(home: "/Users/fixture")
        let effective = V2Policy.discover(try RuleStore.decodeDefaults(from: try BundledRules.data()),
                                          files: files, runner: FakeProcessRunner())
        for id in ["diagnostic-reports", "downloaded-disk-images"] {
            let rule = try XCTUnwrap(effective.rules.first { $0.id == id })
            guard case .staleness(_, _, let threshold)? = rule.evidence.first else {
                return XCTFail("\(id) 的唯一依据是陈旧度，必须携带该证据，实际：\(rule.evidence)")
            }
            XCTAssertEqual(threshold, rule.strategy.olderThanDays,
                           "证据里的阈值必须与规则的 olderThanDays 一致")
            XCTAssertEqual(rule.evidence.first?.strength, .weak)
        }
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testGlobAgeRulesCarryStalenessEvidence 2>&1 | tail -5`
Expected: FAIL，`diagnostic-reports 的唯一依据是陈旧度，必须携带该证据，实际：[]`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/V2Policy.swift` 的 `apply(_:)` 中，`diagnostic-reports` 分支内 `rule.explain = "仅处理 30 天前..."` 之后追加：

```swift
                rule.evidence = [.staleness(date: Date(timeIntervalSince1970: 0),
                                            source: .pathEncoded, thresholdDays: 30)]
```

并在 `downloaded-disk-images` 的 `Rule(...)` 构造之后、`result.rules.append` 之前改为：

```swift
        var diskImages = Rule(id: "downloaded-disk-images", name: "下载目录磁盘映像（60 天前）", risk: .yellow,
            roots: ["~/Downloads"], strategy: Strategy(type: .globAge, glob: "~/Downloads/*.dmg", olderThanDays: 60),
            explain: "仅列出下载目录顶层的旧 .dmg 文件。文件名不能证明内容无用，可能是你仍需保留的安装介质或归档；请逐项确认。移入恢复中心暂不释放空间，不自动删除。")
        diskImages.evidence = [.staleness(date: Date(timeIntervalSince1970: 0),
                                          source: .modificationTime, thresholdDays: 60)]
        result.rules.append(diskImages)
```

> 规则层的证据是**该规则依赖陈旧度**的声明，具体日期在扫描期由 `StalenessCollector` 逐候选采集后覆盖（Task 12）。此处日期占位为 epoch，不参与判定。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter testGlobAgeRulesCarryStalenessEvidence 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/V2Policy.swift Tests/CleanerCoreTests/RuleStoreAuditTests.swift
git commit -m "feat(evidence): glob-age 规则声明陈旧度依赖"
```

---

### Task 10: 等价性护栏（切换前的关键闸门）

证明「推导出的资格」与「现行 risk 行为」一致。**此测试必须在切换任何消费方之前通过**，它是后续所有改动的安全网。

**Files:**
- Create: `Tests/CleanerCoreTests/EligibilityEquivalenceTests.swift`

- [ ] **Step 1: 写测试**

创建 `Tests/CleanerCoreTests/EligibilityEquivalenceTests.swift`：

```swift
import XCTest
@testable import CleanerCore

/// 切换护栏（spec §5.2）：推导资格必须与现行 risk 行为等价。
/// 安全不变量——可处理的规则集合与每条规则的动作都不得变化。
final class EligibilityEquivalenceTests: XCTestCase {
    /// 现行行为：red 只读，green / yellow 可进计划。
    private func legacyIsActionable(_ rule: Rule) -> Bool { rule.risk != .red }

    /// 现行行为：yellow 进废纸篓，其余按策略。
    private func legacyAction(_ rule: Rule) -> PlanAction {
        if rule.risk == .yellow { return .quarantine }
        if rule.strategy.type == .truncate { return .truncate }
        if rule.strategy.type == .command { return .runCommand(rule.strategy.cmd ?? []) }
        return .delete
    }

    private func effectiveRules() throws -> [Rule] {
        let files = InMemoryFileOperations(home: "/Users/fixture")
        return V2Policy.discover(try RuleStore.decodeDefaults(from: try BundledRules.data()),
                                 files: files, runner: FakeProcessRunner()).rules
    }

    func testActionableSetIsUnchanged() throws {
        for rule in try effectiveRules() {
            let derived = EligibilityEvaluator.evaluate(evidence: rule.evidence, action: legacyAction(rule))
            XCTAssertEqual(derived?.isActionable ?? false, legacyIsActionable(rule),
                           "规则 \(rule.id) 的可处理性发生变化：risk=\(rule.risk) evidence=\(rule.evidence)")
        }
    }

    func testNoRuleFallsIntoTheInexpressibleCombination() throws {
        for rule in try effectiveRules() where legacyIsActionable(rule) {
            XCTAssertNotNil(EligibilityEvaluator.evaluate(evidence: rule.evidence, action: legacyAction(rule)),
                            "规则 \(rule.id) 落入弱证据+不可逆的不可表达组合，需重新审视其证据或动作")
        }
    }

    func testEveryActionableRuleHasEvidence() throws {
        for rule in try effectiveRules() where legacyIsActionable(rule) {
            XCTAssertFalse(rule.evidence.isEmpty, "可处理的规则 \(rule.id) 必须有证据支撑")
        }
    }

    func testDisplayOnlyRulesHaveNoEvidence() throws {
        for rule in try effectiveRules() where !legacyIsActionable(rule) {
            XCTAssertTrue(rule.evidence.isEmpty, "只读规则 \(rule.id) 不应携带证据")
        }
    }
}
```

- [ ] **Step 2: 运行测试**

Run: `swift test --filter EligibilityEquivalenceTests 2>&1 | grep -E "error:|XCTAssert|Executed"`
Expected: `Executed 4 tests, with 0 failures`

若失败，**不要修改测试来迁就实现**——失败说明某条规则的证据没配齐（回到 Task 6-9 补），或其证据与动作组合本身就不成立（需回到 spec 重新讨论该规则）。

- [ ] **Step 3: 提交**

```bash
git add Tests/CleanerCoreTests/EligibilityEquivalenceTests.swift
git commit -m "test(evidence): 等价性护栏，锁定切换前后行为一致"
```

---

### Task 11: ReportEntry 与 PlanItem 携带资格

**Files:**
- Modify: `Sources/CleanerCore/Models.swift`（`ReportEntry` 第 254-289 行、`PlanItem` 第 339-379 行）
- Test: `Tests/CleanerCoreTests/EvidenceTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/EvidenceTests.swift` 的 `EvidenceTests` 类内追加：

```swift
    func testReportEntryAndPlanItemCarryEligibility() {
        var entry = ReportEntry(ruleId: "r", ruleName: "r", risk: .yellow, strategyType: .globAge,
                                sizeBytes: 1, candidateCount: 0, candidates: [], status: .ok, explain: "e")
        XCTAssertNil(entry.eligibility, "未评定前为 nil")
        entry.eligibility = .recommended
        XCTAssertEqual(entry.eligibility, .recommended)

        var item = PlanItem(path: "/a/b/c", ruleId: "r", ruleName: "r", risk: .yellow, sizeBytes: 1,
                            action: .quarantine, status: .ready, ruleRoots: ["/a"])
        item.eligibility = .needsConfirmation
        XCTAssertEqual(item.eligibility, .needsConfirmation)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testReportEntryAndPlanItemCarryEligibility 2>&1 | tail -5`
Expected: 编译失败，`value of type 'ReportEntry' has no member 'eligibility'`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Models.swift` 的 `ReportEntry` 中，`candidateSizes` 声明之后追加：

```swift
    /// 由证据推导的处理资格；nil 表示本次扫描未评定（旧格式报告）。
    public var eligibility: Eligibility?
    /// 逐候选证据。展示文案由此渲染，不再手写字符串。
    public var candidateEvidence: [String: [Evidence]]?
```

在 `PlanItem` 中，`guardSpecs` 声明之后追加：

```swift
    /// 生成计划时评定的资格；apply 期重新评定后须一致。
    public var eligibility: Eligibility?
```

- [ ] **Step 4: 运行全量测试**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Models.swift Tests/CleanerCoreTests/EvidenceTests.swift
git commit -m "feat(evidence): ReportEntry 与 PlanItem 携带处理资格"
```

---

### Task 12: Scanner 逐候选采集证据并评定资格

**Files:**
- Modify: `Sources/CleanerCore/Scanner.swift:86`（`base` 构造）、`:102`（`isCompatible` 检查）
- Test: `Tests/CleanerCoreTests/ScannerTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/ScannerTests.swift` 的测试类内追加：

```swift
    func testScannerAttachesStalenessEvidencePerCandidate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-120 * 86_400)
        try TestEnv.makeTree(root: home, files: ["Downloads/old.dmg": "x"])
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: home + "/Downloads/old.dmg")
        var rule = Rule(id: "dmg", name: "dmg", risk: .yellow, roots: [home + "/Downloads"],
                        strategy: Strategy(type: .globAge, glob: home + "/Downloads/*.dmg", olderThanDays: 60),
                        explain: "e")
        rule.evidence = [.staleness(date: Date(timeIntervalSince1970: 0),
                                    source: .modificationTime, thresholdDays: 60)]

        let entry = try XCTUnwrap(scanner.scan(rules: [rule], now: now).entries.first)
        let candidate = try XCTUnwrap(entry.candidates.first)
        let collected = try XCTUnwrap(entry.candidateEvidence?[candidate])
        guard case .staleness(_, _, let threshold)? = collected.first else {
            return XCTFail("候选必须带上实际采集到的陈旧度证据，实际：\(collected)")
        }
        XCTAssertEqual(threshold, 60)
        XCTAssertEqual(entry.eligibility, .needsConfirmation, "弱证据 + 可逆动作 = 需要确认")
    }

    func testRuleWithoutEvidenceIsDisplayOnly() throws {
        try TestEnv.makeTree(root: home, files: ["data/cache/a.txt": "x"])
        let rule = Rule(id: "noev", name: "noev", risk: .yellow, roots: [home + "/data/cache"],
                        strategy: Strategy(type: .deleteDir), explain: "e")
        let entry = try XCTUnwrap(scanner.scan(rules: [rule]).entries.first)
        XCTAssertEqual(entry.eligibility?.isDisplayOnly, true, "无证据的规则必须只读")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testScannerAttachesStalenessEvidencePerCandidate 2>&1 | tail -5`
Expected: FAIL，`entry.candidateEvidence` 为 nil

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Scanner.swift` 的 `entry(for:collector:)` 中，`return e` 之前（每个 `case` 分支的公共出口）插入资格评定。最小改法是在 `entry(for:collector:)` 末尾包一层：把现有函数改名为 `rawEntry(for:collector:)`，并新增：

```swift
    func entry(for rule: Rule, collector: ScanCollector) -> ReportEntry {
        var result = rawEntry(for: rule, collector: collector)
        guard !rule.evidence.isEmpty else {
            result.eligibility = .displayOnly(missing: "该规则尚未提供可核验证据")
            return result
        }
        // 逐候选采集：规则层证据声明依赖，候选层证据是实际核验结果
        var perCandidate: [String: [Evidence]] = [:]
        for candidate in result.candidates {
            var collected: [Evidence] = []
            for declared in rule.evidence {
                if case .staleness(_, _, let days) = declared {
                    if let actual = StalenessCollector.collect(path: candidate, thresholdDays: days,
                                                               now: collector.now, files: files) {
                        collected.append(actual)
                    }
                } else {
                    collected.append(declared) // 工具权威在适配器构造期已核验
                }
            }
            perCandidate[candidate] = collected
        }
        result.candidateEvidence = perCandidate
        let action = Self.plannedAction(for: rule)
        result.eligibility = EligibilityEvaluator.evaluate(evidence: rule.evidence, action: action)
            ?? .displayOnly(missing: "证据强度不足以支撑该动作")
        return result
    }

    /// 规则将产生的动作。与 Planner 共用同一判定，避免两处分叉。
    ///
    /// 本阶段 `risk` 仍是动作选择器（见「范围说明」）：它不再参与资格判定，
    /// 但仍决定文件级候选走废纸篓还是直接删除。阶段二引入显式动作意图字段后移除此依赖。
    static func plannedAction(for rule: Rule) -> PlanAction {
        if rule.risk == .yellow { return .quarantine }
        switch rule.strategy.type {
        case .truncate: return .truncate
        case .command: return .runCommand(rule.strategy.cmd ?? [])
        case .deleteDir, .globAge: return .delete
        }
    }
```

同时把原 `func entry(for rule: Rule, collector: ScanCollector) -> ReportEntry` 的签名改为 `func rawEntry(for rule: Rule, collector: ScanCollector) -> ReportEntry`（函数体不动）。

- [ ] **Step 4: 运行全量测试**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Scanner.swift Tests/CleanerCoreTests/ScannerTests.swift
git commit -m "feat(evidence): Scanner 逐候选采集证据并评定资格"
```

---

### Task 13: Planner 改用资格判定

**Files:**
- Modify: `Sources/CleanerCore/Planner.swift:49-51`、`:111-113`、`:131-137`、`:146-150`
- Test: `Tests/CleanerCoreTests/PlannerExecutorTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/PlannerExecutorTests.swift` 的测试类内追加：

```swift
    func testPlannerExcludesDisplayOnlyRules() throws {
        try TestEnv.makeTree(root: home, files: ["data/cache/a.txt": "x"])
        // 无证据 → 只读 → 不入计划
        let rule = deleteRule(id: "noev", roots: [home + "/data/cache"])
        let report = scanner.scan(rules: [rule], now: now)
        let plan = try planner.makePlan(report: report, rules: [rule], now: now)
        XCTAssertTrue(plan.items.isEmpty, "无证据的规则不得进入计划")
    }

    func testPlannerStampsEligibilityOnItems() throws {
        try TestEnv.makeTree(root: home, files: ["data/cache/a.txt": "x"])
        var rule = deleteRule(id: "ev", roots: [home + "/data/cache"], risk: .yellow)
        rule.evidence = [.toolAuthority(tool: "t", version: "1",
                                        basis: .enumeration(interface: "list"))]
        let report = scanner.scan(rules: [rule], now: now)
        let plan = try planner.makePlan(report: report, rules: [rule], now: now)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.eligibility, .recommended, "强证据 + 移废纸篓 = 推荐")
        XCTAssertEqual(item.action, .quarantine)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testPlannerStampsEligibilityOnItems 2>&1 | tail -5`
Expected: FAIL，`item.eligibility` 为 nil

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Planner.swift` 中：

将第 49-51 行

```swift
            if rule.risk == .red { continue } // 红色只读展示，永不入计划（spec §6）
            if !Strategy.isCompatible(risk: rule.risk, type: rule.strategy.type) {
                throw PlannerError.invalidRule(id: rule.id, reason: "黄色规则只能配 delete-dir / glob-age，command / truncate 无法隔离还原")
            }
```

替换为

```swift
            // 资格由证据推导：无证据或证据不足以支撑该动作 → 只读，不入计划（spec §2.2）
            let plannedAction = Scanner.plannedAction(for: rule)
            guard let ruleEligibility = EligibilityEvaluator.evaluate(evidence: rule.evidence, action: plannedAction) else {
                throw PlannerError.invalidRule(id: rule.id, reason: "弱证据无法支撑不可逆动作，该组合不成立")
            }
            if ruleEligibility.isDisplayOnly { continue }
```

在第 111-113 行的命令项 `PlanItem(...)` 构造之后追加：

```swift
                items[items.count - 1].eligibility = ruleEligibility
```

将第 131-137 行

```swift
                    let action: PlanAction
                    if rule.risk == .yellow {
                        action = .quarantine
                    } else if rule.strategy.type == .truncate {
                        action = .truncate
                    } else {
                        action = .delete
                    }
```

替换为

```swift
                    let action = plannedAction
```

在第 146-150 行的候选项 `PlanItem(...)` 构造之后追加：

```swift
                    items[items.count - 1].eligibility = ruleEligibility
```

- [ ] **Step 4: 运行全量测试**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过。若 `PlannerExecutorTests` 中原有断言依赖 `risk == .red` 被跳过的行为，改为给夹具规则补上或去掉 `evidence` 来表达同一意图，**不得放宽断言**。

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Planner.swift Tests/CleanerCoreTests/PlannerExecutorTests.swift
git commit -m "refactor(evidence): Planner 改用资格推导，动作由可逆性决定"
```

---

### Task 14: Executor 边界校验改用资格

**Files:**
- Modify: `Sources/CleanerCore/Executor.swift:41-42`、`:106`
- Test: `Tests/CleanerCoreTests/V2CompletionTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/CleanerCoreTests/V2CompletionTests.swift` 的测试类内追加：

```swift
    func testExecutorRejectsItemWhoseRuleLostEvidence() throws {
        // 计划生成后规则失去证据（例如工具被卸载）→ 整个执行 abort，不动任何文件
        let plan = try fixturePlan()
        var stripped = try XCTUnwrap(fixtureRules().first)
        stripped.evidence = []
        let engine = Executor(files: files, safety: PathSafety(home: home, files: files),
                              quarantine: QuarantineStore(recordsDirectory: home + "/recovery-records", files: files),
                              audit: AuditLog(files: files, path: home + "/audit.log"),
                              runner: FakeProcessRunner(), rulesProvider: { [stripped] })
        XCTAssertThrowsError(try engine.execute(plan))
        XCTAssertTrue(files.fileExists(home + "/cache/a"), "abort 时不得动任何文件")
    }
```

`fixtureRules()` 目前不存在，需先从 `V2CompletionTests.swift:18` 的 `fixturePlan()` 中提取。改为：

```swift
    /// fixturePlan 使用的规则，供需要改写规则的测试复用。
    func fixtureRules() -> [Rule] {
        [Rule(id: "fixture", name: "fixture", risk: .yellow, roots: [home + "/cache"],
              strategy: Strategy(type: .globAge, glob: home + "/cache/*", olderThanDays: 0),
              explain: "fixture")]
    }

    func fixturePlan() throws -> Plan {
        try TestEnv.makeTree(root: home, files: ["cache/a": "original", "cache/b": "keep"])
        let rules = fixtureRules()
        let report = Scanner(files: files, safety: PathSafety(home: home, files: files)).scan(rules: rules)
        return try planner().makePlan(report: report, rules: rules)
    }
```

注意：`fixtureRules()` 返回的规则在 Task 6-9 之后仍无证据，会导致 `fixturePlan()` 产出空计划。因此**同时**给它补上证据：

```swift
    func fixtureRules() -> [Rule] {
        var rule = Rule(id: "fixture", name: "fixture", risk: .yellow, roots: [home + "/cache"],
                        strategy: Strategy(type: .globAge, glob: home + "/cache/*", olderThanDays: 0),
                        explain: "fixture")
        rule.evidence = [.toolAuthority(tool: "fixture", version: "1",
                                        basis: .enumeration(interface: "test"))]
        return [rule]
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter testExecutorRejectsItemWhoseRuleLostEvidence 2>&1 | tail -5`
Expected: FAIL，`XCTAssertThrowsError failed: did not throw an error`

- [ ] **Step 3: 实现**

在 `Sources/CleanerCore/Executor.swift` 中，将第 41-42 行

```swift
                guard let rule = currentRules.first(where: { $0.id == item.ruleId }), rule.risk != .red,
                      item.risk == rule.risk else {
```

替换为

```swift
                guard let rule = currentRules.first(where: { $0.id == item.ruleId }),
                      let currentEligibility = EligibilityEvaluator.evaluate(evidence: rule.evidence, action: item.action),
                      currentEligibility.isActionable,
                      item.eligibility == currentEligibility else {
```

将第 106 行

```swift
        let yellowItems = ready.filter { $0.risk == .yellow }
```

替换为

```swift
        let yellowItems = ready.filter { $0.action == .quarantine }
```

- [ ] **Step 4: 运行全量测试**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/Executor.swift Tests/CleanerCoreTests/V2CompletionTests.swift
git commit -m "refactor(evidence): Executor 边界校验改用资格推导"
```

---

### Task 15: GUI 与 CLI 改用资格

**关键**：`ContentView.category()` 目前只把 `.yellow` 映射到「需要确认」，`.green` 没有任何分支会落到「暂不可处理」。不改这里，获得「推荐」资格的 pip / Playwright 会从界面消失且无法勾选（spec §5.2）。

**Files:**
- Modify: `Sources/DiskCleanerApp/ContentView.swift:192-197`（`category`）、`:200-202`（分类选择器）
- Modify: `Sources/DiskCleanerApp/AppState.swift:162-176`（选中统计）
- Modify: `Sources/DiskCleanerApp/ConfirmViews.swift`（风险展示）
- Modify: `Sources/dclean/main.swift`（输出）

- [ ] **Step 1: 改 GUI 分类**

将 `Sources/DiskCleanerApp/ContentView.swift` 的 `category` 替换为：

```swift
    private func category(_ entry: ReportEntry) -> String {
        if case .unavailable = entry.status { return "暂不可处理" }
        if state.isBlocked(entry.ruleId) { return "暂不可处理" }
        switch entry.eligibility {
        case .recommended: return "推荐"
        case .needsConfirmation: return "需要确认"
        case .displayOnly, .none:
            return V2Policy.protectedIDs.contains(entry.ruleId) ? "受保护" : "暂不可处理"
        }
    }
```

将分类选择器的 `ForEach(["需要确认", "暂不可处理", "受保护"], id: \.self)` 改为：

```swift
                ForEach(["推荐", "需要确认", "暂不可处理", "受保护"], id: \.self) { Text($0) }
```

并把 `@State private var filter = "需要确认"` 改为 `@State private var filter = "推荐"`。

- [ ] **Step 2: 改勾选禁用条件**

将 `ContentView.swift` 中 Toggle 的 `.disabled(entry.risk == .red || ...)` 改为：

```swift
                                    .disabled(entry.eligibility?.isActionable != true || entry.status != .ok || state.report?.isComplete == false || state.isBlocked(entry.ruleId) || state.loading)
```

将详情页的 `if entry.risk != .red {` 改为 `if entry.eligibility?.isActionable == true {`。

- [ ] **Step 3: 改 AppState 统计**

将 `Sources/DiskCleanerApp/AppState.swift` 的 `selectedEntries` 与两个统计属性改为：

```swift
    private func selectedEntries(of report: Report) -> [ReportEntry] {
        report.entries.filter { selectedRuleIDs.contains($0.ruleId) && $0.status == .ok
            && $0.eligibility?.isActionable == true }
    }

    /// 立即释放：动作不可逆的条目（命令、直接删除）
    var selectedImmediateBytes: Int64 {
        guard let report else { return 0 }
        return selectedEntries(of: report).filter { $0.strategyType == .command || $0.strategyType == .truncate }
            .reduce(0) { $0 + $1.includedBytes(excluded: excludedPaths) }
    }

    /// 移入废纸篓：可还原的条目
    var selectedQuarantineBytes: Int64 {
        guard let report else { return 0 }
        return selectedEntries(of: report).filter { $0.strategyType != .command && $0.strategyType != .truncate }
            .reduce(0) { $0 + $1.includedBytes(excluded: excludedPaths) }
    }
```

- [ ] **Step 4: 改确认单与 CLI 输出**

`Sources/DiskCleanerApp/ConfirmViews.swift` 第 13、16 行按动作可逆性分组，取代按 risk 分组：

```swift
        items.filter { !$0.action.isReversible }.reduce(0) { $0 + $1.sizeBytes }
```

```swift
        items.filter { $0.action.isReversible }.reduce(0) { $0 + $1.sizeBytes }
```

第 35 行 `Text(item.risk.symbol)` 改为：

```swift
                                Text(item.eligibility == .recommended ? "✅" : "⚠️")
```

`Sources/dclean/main.swift` 第 145 行改为：

```swift
        let tag = item.eligibility == .recommended ? "推荐" : "需确认"
        print("  [\(tag)] \(ByteFormatting.padded(item.actionLabel, to: 22)) \(ByteFormatting.padded(ByteFormatting.human(item.sizeBytes), to: 10))  \(item.path)\(status)")
```

第 116-119 行的 `report.entries(withRisk:)` 分组循环改为按资格分组：

```swift
    for (label, wanted) in [("推荐", Eligibility.recommended), ("需要确认", .needsConfirmation)] {
        let entries = report.entries.filter { $0.eligibility == wanted && $0.status == .ok }
        guard !entries.isEmpty else { continue }
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("\(label)  \(ByteFormatting.human(total))")
```

第 304 行 `rule.risk.symbol` 改为 `(rule.evidence.isEmpty ? "🔴" : "🟡")`。

- [ ] **Step 5: 构建并全量测试**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过

- [ ] **Step 6: 提交**

```bash
git add Sources/DiskCleanerApp/ Sources/dclean/main.swift
git commit -m "refactor(evidence): GUI 与 CLI 改用资格展示，补上缺失的推荐分类"
```

---

### Task 16: 移除兼容性公理与 .red 迁移补丁

> **本任务不移除 `Rule.risk`**。它仍是动作选择器（见「范围说明」），只是不再参与任何资格判定。彻底移除留给阶段二。

**Files:**
- Modify: `Sources/CleanerCore/Models.swift`（删 `Strategy.isCompatible`、`validateRules` 中的相关校验）
- Modify: `Sources/CleanerCore/V2Policy.swift:48-66`（删强制 `.red`）
- Modify: `Sources/CleanerCore/Scanner.swift:102`

- [ ] **Step 1: 删除兼容性公理**

删除 `Sources/CleanerCore/Models.swift` 中整个 `public static func isCompatible(risk:type:)` 方法，以及 `validateRules` 中引用它的那段：

```swift
        if !Strategy.isCompatible(risk: rule.risk, type: rule.strategy.type) {
            errors.append("规则 \(rule.id)：黄色规则只能配 delete-dir / glob-age，command / truncate 无法经废纸篓还原")
        }
```

删除 `Sources/CleanerCore/Scanner.swift` 第 102-105 行的 `isCompatible` 检查分支。

- [ ] **Step 2: 删除 V2Policy 的 .red 迁移 hack**

将 `Sources/CleanerCore/V2Policy.swift` 的 `apply(_:)` 中

```swift
            rule.risk = .red
            if protectedIDs.contains(rule.id) {
```

改为（保留 explain 改写，去掉 risk 赋值）：

```swift
            if protectedIDs.contains(rule.id) {
```

这些规则没有证据，因而自动只读——不再需要手写 `.red`。

**保留** `diagnostic-reports` 分支里的 `rule.risk = .yellow`：它此刻的职责是「该规则的候选走废纸篓」，属动作选择，不是资格声明。在其上方补一行注释说明这一点：

```swift
                rule.risk = .yellow // 动作选择器：候选走废纸篓。资格由 evidence 决定（阶段二改为显式动作字段）
```

- [ ] **Step 3: 运行全量测试**

Run: `swift test 2>&1 | grep -E "error:|Executed 1[0-9][0-9] tests" | tail -3`
Expected: 全部通过。等价性护栏（Task 10）此时仍在，它会抓住任何行为偏移。

- [ ] **Step 4: 真实数据核对**

```bash
swift build && ./.build/debug/dclean rules --json | python3 -c "
import json,sys
rules=json.load(sys.stdin).get('rules')
print('生效规则:', len(rules))
for r in rules: print(' ', r['id'], '| 证据数:', len(r.get('evidence',[])))
"
./.build/debug/dclean plan | tail -5
```

Expected: 仍为 17 条规则；可进计划的条目集合与本阶段开始前一致（对照 `git stash` 前保存的输出）。

- [ ] **Step 5: 提交**

```bash
git add Sources/CleanerCore/
git commit -m "refactor(evidence): 移除 risk 兼容性公理与 V2Policy 的 .red 迁移补丁"
```

---

## 阶段一完成标准

- [x] 全量测试通过，数量 ≥ 176（159 原有 + 约 17 新增）
- [x] 等价性护栏（Task 10）四条全部通过（另加强五个适配器既有夹具的证据断言）
- [x] `dclean plan` 产出的可执行条目集合与阶段一开始前逐条一致（开工前先存一份 `./.build/debug/dclean plan > /tmp/plan-before.txt` 作对照）
- [ ] GUI 四个分类都能正常显示与勾选，「推荐」分类下能看到 pip / Playwright
- [ ] `grep -rn "risk" Sources/CleanerCore/` 的结果中，**没有任何一处参与资格判定**——只剩 `Scanner.plannedAction` 的动作选择、`Rule` 的字段声明与解码、`V2Policy` 中带注释的动作选择器赋值

### 交给阶段二的尾巴

1. `Rule.risk` 的动作选择职责 → 换成显式动作意图字段后移除
2. 逐候选证据重采集（spec §4.3）→ 随 `referenceUnreachable` 一起交付
3. `versionRedundancy` / `referenceReachability` 两个采集器
4. 是否直接取消 `.delete` 动作类型（生产环境已无规则使用）
