# 子项目 1：引擎重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/specs/2026-09-26-product-redesign-design.md` 建出新引擎：规则包、四种识别器、空间估算、方案生成、自管恢复区、执行器，并把 `dclean` 命令行换成新引擎，可在真机只读验证。

**Architecture:** 新代码放在 `Sources/CleanerCore/Engine/`，与旧引擎同一模块，类型名全部避开旧名（旧的 `Rule`、`Planner`、`Executor`、`Scanner`、`Plan` 不动）。旧菜单栏界面 `DiskCleanerApp` 继续用旧引擎，到子项目 2 再切换并删除旧代码。平台层与安全层直接复用：`FileOperations`、`SafeDirectory`、`ProcessRunner`、`GuardEvaluator`、`PathSafety`、`ProtectedLocations`、`AuditLog`、`OperationLease`。

**Tech Stack:** Swift 5.10 语言模式 / SwiftPM / XCTest / AppKit（仅 `RealAppControl`）。

---

## 约定

- 新数据目录 `~/.dclean-v3`：`recovery/`（恢复区）、`audit.log`、`user-rules.json`。用户保护位置与操作锁沿用 `~/.dclean-v2`（`ProtectedLocations`、`OperationLease`），新旧界面共用同一把锁互斥。
- 规则包是纯数据：`Sources/CleanerCore/Engine/RulePack.json`，`platform` 字段为 `macos`。Windows 版以后另出一份规则包，这就是设计文档「路径模板按平台区分」的落地方式。
- 单测：纯逻辑用 `InMemoryFileOperations` + `FakeProcessRunner`；硬链接、恢复区移动这类依赖真实 inode 的用 `RealFileOperations(home: 临时目录)`。
- 测试命令：`swift test --filter <测试类名>`。全量：`swift test`。
- `~/Documents` 等仍是写死的整树禁区，因此放在 `~/Documents` 下的项目不会出现在项目产物里。这是设计文档 2.2 的直接结果，不是遗漏。

## 文件结构

**新建（`Sources/CleanerCore/Engine/`）**

| 文件 | 职责 |
|---|---|
| `EnginePaths.swift` | 新数据目录路径 |
| `RuleModel.swift` | 档位、类别、规则、动作、前置条件、文案 |
| `RuleValidator.swift` | 单条规则校验、个人隐私区清单 |
| `RulePack.swift` | 读取内置与自定义规则包，丢弃不合格规则并报告 |
| `RulePack.json` | 内置规则（资源） |
| `CleanItem.swift` | 清理项、阻塞原因 |
| `ExecutableResolver.swift` | 在固定目录里查找命令，不依赖继承的 PATH |
| `Sizer.swift` | 表观大小与可释放量（硬链接去重） |
| `Detector.swift` | `DetectContext`、`Detector` 协议 |
| `RuleDetector.swift` | 按规则包识别 |
| `ProjectArtifactDetector.swift` | 项目依赖与构建产物 |
| `DockerDetector.swift` | Docker 构建缓存、失败容器、未用镜像 |
| `SpaceMapDetector.swift` | 规则之外的大目录 |
| `AppControl.swift` | 应用控制协议 |
| `RealAppControl.swift` | 基于 `NSRunningApplication` 的实现 |
| `PreconditionChecker.swift` | 应用运行、锁文件占用 |
| `EngineScanner.swift` | 串起识别、估算、阻塞检查 |
| `CleanPlan.swift` | 方案与默认勾选、按应用分组 |
| `RecoveryStore.swift` | 自管恢复区 |
| `PlanExecutor.swift` | 复核、退出应用、暂停服务、执行、测量 |

**修改**

| 文件 | 改动 |
|---|---|
| `Sources/CleanerCore/FileOperations.swift` | `FileAttributes` 增加 `linkCount` |
| `Package.swift` | 增加资源 `Engine/RulePack.json` |
| `Sources/dclean/main.swift` | 整体换成新引擎命令 |

**新建测试（`Tests/CleanerCoreTests/`）**：`EngineTestSupport.swift`、`EngineRuleModelTests.swift`、`EngineRulePackTests.swift`、`EngineSizerTests.swift`、`EngineRuleDetectorTests.swift`、`EngineProjectDetectorTests.swift`、`EngineDockerDetectorTests.swift`、`EngineSpaceMapTests.swift`、`EnginePreconditionTests.swift`、`EngineScannerTests.swift`、`EngineRecoveryStoreTests.swift`、`EngineExecutorTests.swift`。

---

### Task 1：`FileAttributes.linkCount` 与新数据目录

**Files:**
- Modify: `Sources/CleanerCore/FileOperations.swift`（`FileAttributes` 定义与 `RealFileOperations.attributesIfExist`）
- Create: `Sources/CleanerCore/Engine/EnginePaths.swift`
- Test: `Tests/CleanerCoreTests/EngineSizerTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineSizerTests.swift
import XCTest
@testable import CleanerCore

final class EngineSizerTests: XCTestCase {
    func testRealAttributesReportHardLinkCount() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write("hello", to: dir + "/a")
        try FileManager.default.linkItem(atPath: dir + "/a", toPath: dir + "/b")
        let files = RealFileOperations(home: dir)
        XCTAssertEqual(files.attributesIfExist(atPath: dir + "/a")?.linkCount, 2)
    }

    func testEnginePathsLiveUnderDcleanV3() {
        XCTAssertEqual(EnginePaths.recoveryDirectory(home: "/Users/t"), "/Users/t/.dclean-v3/recovery")
        XCTAssertEqual(EnginePaths.auditLog(home: "/Users/t"), "/Users/t/.dclean-v3/audit.log")
        XCTAssertEqual(EnginePaths.userRules(home: "/Users/t"), "/Users/t/.dclean-v3/user-rules.json")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineSizerTests`
Expected: 编译失败，`value of type 'FileAttributes' has no member 'linkCount'`、`cannot find 'EnginePaths'`。

- [ ] **Step 3: 实现**

在 `FileAttributes` 中 `public var modificationStamp: String?` 下一行加：

```swift
    /// 硬链接数（st_nlink）；内存实现为 nil。用于可释放量估算。
    public var linkCount: UInt32?
```

把 `FileAttributes.init` 改为（新增末尾参数，默认 nil，旧调用不受影响）：

```swift
    public init(isSymbolicLink: Bool, isDirectory: Bool, isRegularFile: Bool,
                size: Int64, allocatedSize: Int64? = nil, modificationDate: Date?, device: UInt64? = nil, inode: UInt64? = nil, modificationStamp: String? = nil, linkCount: UInt32? = nil) {
        self.isSymbolicLink = isSymbolicLink
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.size = size
        self.allocatedSize = allocatedSize ?? size
        self.modificationDate = modificationDate
        self.device = device
        self.inode = inode
        self.modificationStamp = modificationStamp
        self.linkCount = linkCount
    }
```

`RealFileOperations.attributesIfExist` 的 `return FileAttributes(...)` 末尾参数改为：

```swift
            modificationDate: mtime, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), modificationStamp: "\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)",
            linkCount: UInt32(st.st_nlink))
```

`FileAttributes` 的 `==` 与 `matches` 不比较 `linkCount`，保持不变。

```swift
// Sources/CleanerCore/Engine/EnginePaths.swift
import Foundation

/// 新引擎的数据目录。用户保护位置与操作锁仍在 V2Paths（~/.dclean-v2），新旧界面共用一把锁。
public enum EnginePaths {
    public static let directoryName = ".dclean-v3"

    public static func dataDirectory(home: String) -> String { home + "/" + directoryName }
    public static func recoveryDirectory(home: String) -> String { dataDirectory(home: home) + "/recovery" }
    public static func auditLog(home: String) -> String { dataDirectory(home: home) + "/audit.log" }
    public static func userRules(home: String) -> String { dataDirectory(home: home) + "/user-rules.json" }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineSizerTests`
Expected: 2 tests PASS。

- [ ] **Step 5: 全量回归**

Run: `swift test`
Expected: 原有测试全部通过（0 failures）。

- [ ] **Step 6: Commit**

```bash
git add Sources/CleanerCore/FileOperations.swift Sources/CleanerCore/Engine/EnginePaths.swift Tests/CleanerCoreTests/EngineSizerTests.swift
git commit -m "feat(engine): add hard link count and v3 data paths"
```

---

### Task 2：规则模型与校验

**Files:**
- Create: `Sources/CleanerCore/Engine/RuleModel.swift`
- Create: `Sources/CleanerCore/Engine/RuleValidator.swift`
- Test: `Tests/CleanerCoreTests/EngineRuleModelTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineRuleModelTests.swift
import XCTest
@testable import CleanerCore

final class EngineRuleModelTests: XCTestCase {
    let home = "/Users/tester"
    lazy var files = InMemoryFileOperations(home: home)
    lazy var safety = PathSafety(home: home, files: files)

    func rule(id: String = "r", tier: CleanTier = .safe, targets: [String] = ["~/.npm/_cacache"],
              action: RuleAction = .command(["npm", "cache", "clean", "--force"]),
              preconditions: RulePreconditions? = nil) -> CleanRule {
        CleanRule(id: id, name: "名称", app: "npm", category: .dev, tier: tier, detect: nil,
                  targets: targets, action: action, preconditions: preconditions,
                  copy: RuleCopy(what: "是什么", impact: "影响", regrows: nil))
    }

    func problems(_ r: CleanRule, _ origin: RuleOrigin = .bundled) -> [String] {
        RuleValidator.problems(in: r, origin: origin, safety: safety)
    }

    func testValidCommandRulePasses() {
        XCTAssertEqual(problems(rule()), [])
    }

    func testCommandOnlyWithSafeOrConfirm() {
        XCTAssertEqual(problems(rule(tier: .confirm)), [])
        XCTAssertFalse(problems(rule(tier: .suggested)).isEmpty)
    }

    func testDisplayOnlyMustHaveNoAction() {
        XCTAssertEqual(problems(rule(tier: .displayOnly, targets: ["~/.codex/sessions"], action: .noAction)), [])
        XCTAssertFalse(problems(rule(tier: .displayOnly, action: .recover)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, action: .noAction)).isEmpty)
    }

    func testActionableRuleCannotTargetForbiddenTree() {
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/.codex/sessions"], action: .recover)).isEmpty)
    }

    func testNoRuleMayTouchPrivacyRoots() {
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/Documents/big"], action: .noAction)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/.ssh"], action: .noAction)).isEmpty)
    }

    func testWildcardMustBeWholeSingleComponent() {
        XCTAssertEqual(problems(rule(tier: .safe, targets: ["~/Library/Caches/JetBrains/*"], action: .recover)), [])
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/Caches/Jet*"], action: .recover)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/*/x/*"], action: .recover)).isEmpty)
    }

    func testRelativeTargetsRejected() {
        XCTAssertFalse(problems(rule(targets: ["Library/Caches"])).isEmpty)
    }

    func testRecoverOlderThanNeedsPositiveDays() {
        XCTAssertFalse(problems(rule(tier: .safe, action: RuleAction(type: .recoverOlderThan, olderThanDays: 0))).isEmpty)
        XCTAssertEqual(problems(rule(tier: .safe, targets: ["~/Library/Logs/DiagnosticReports"], action: RuleAction(type: .recoverOlderThan, olderThanDays: 30))), [])
    }

    func testUserRulesAreConfinedToConfirmRecover() {
        XCTAssertEqual(problems(rule(tier: .confirm, targets: ["~/Library/Caches/Foo"], action: .recover), .user), [])
        XCTAssertFalse(problems(rule(tier: .confirm), .user).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/Caches/Foo"], action: .recover), .user).isEmpty)
        let service = PausableService(name: "s", processPattern: "p", stop: ["a"], start: ["b"])
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/Library/Caches/Foo"], action: .recover,
                                     preconditions: RulePreconditions(pausableServices: [service])), .user).isEmpty)
    }

    func testRuleDecodesFromJSON() throws {
        let json = """
        {"id":"x","name":"X","app":"Chrome","category":"browser","tier":"suggested",
         "targets":["~/Library/Caches/X"],"action":{"type":"recover"},
         "preconditions":{"quitApps":[{"name":"Chrome","bundleID":"com.google.Chrome"}]},
         "copy":{"what":"w","impact":"i"}}
        """
        let decoded = try JSONDecoder().decode(CleanRule.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.action.type, .recover)
        XCTAssertEqual(decoded.preconditions?.quitApps?.first?.canQuitForUser, true)
        XCTAssertNil(decoded.copy.regrows)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineRuleModelTests`
Expected: 编译失败，找不到 `CleanRule` 等类型。

- [ ] **Step 3: 实现 `RuleModel.swift`**

```swift
// Sources/CleanerCore/Engine/RuleModel.swift
import Foundation

/// 清理项的四档。档位由规则声明，执行时的动态条件只会让某项暂时不可处理，不会升档。
public enum CleanTier: String, Codable, Sendable, CaseIterable {
    case safe, suggested, confirm, displayOnly

    public var title: String {
        switch self {
        case .safe: return "安全"
        case .suggested: return "建议"
        case .confirm: return "需要确认"
        case .displayOnly: return "只展示"
        }
    }

    public var selectedByDefault: Bool { self == .safe || self == .suggested }
}

public enum AppCategory: String, Codable, Sendable, CaseIterable {
    case ai, dev, browser, office, other
}

public struct RuleAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command, recover, recoverOlderThan
        case noAction = "none"
    }

    public var type: Kind
    public var command: [String]?
    public var olderThanDays: Int?

    public init(type: Kind, command: [String]? = nil, olderThanDays: Int? = nil) {
        self.type = type
        self.command = command
        self.olderThanDays = olderThanDays
    }

    public static let noAction = RuleAction(type: .noAction)
    public static let recover = RuleAction(type: .recover)
    public static func command(_ argv: [String]) -> RuleAction { RuleAction(type: .command, command: argv) }
}

public struct QuitApp: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var bundleID: String
    /// IDE、编辑器可能有未保存改动，设为 false：工具只提示用户自行退出，不代为退出。
    public var mayQuitForUser: Bool?

    public init(name: String, bundleID: String, mayQuitForUser: Bool? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.mayQuitForUser = mayQuitForUser
    }

    public var canQuitForUser: Bool { mayQuitForUser ?? true }
}

/// 规则登记的「可安全暂停」服务。stop / start 必须是执行后立即返回的命令（start 负责把服务放到后台）。
public struct PausableService: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// pgrep -f 的匹配模式
    public var processPattern: String
    public var stop: [String]
    public var start: [String]

    public init(name: String, processPattern: String, stop: [String], start: [String]) {
        self.name = name
        self.processPattern = processPattern
        self.stop = stop
        self.start = start
    }
}

public struct RulePreconditions: Codable, Equatable, Sendable {
    public var quitApps: [QuitApp]?
    public var lockfiles: [String]?
    public var pausableServices: [PausableService]?

    public init(quitApps: [QuitApp]? = nil, lockfiles: [String]? = nil, pausableServices: [PausableService]? = nil) {
        self.quitApps = quitApps
        self.lockfiles = lockfiles
        self.pausableServices = pausableServices
    }

    public static let empty = RulePreconditions()
}

public struct RuleCopy: Codable, Equatable, Sendable {
    public var what: String
    public var impact: String
    /// 会自动长回来时的说明与关闭方法；不会长回来为 nil。
    public var regrows: String?

    public init(what: String, impact: String, regrows: String?) {
        self.what = what
        self.impact = impact
        self.regrows = regrows
    }
}

public struct CleanRule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var app: String
    public var category: AppCategory
    public var tier: CleanTier
    /// 任一路径存在即视为已安装；为空时以目标存在（命令规则另需找到可执行文件）为准。
    public var detect: [String]?
    /// 绝对路径或 ~/ 开头；允许单独一段 * 匹配一层子目录。
    public var targets: [String]
    public var action: RuleAction
    public var preconditions: RulePreconditions?
    public var copy: RuleCopy

    public init(id: String, name: String, app: String, category: AppCategory, tier: CleanTier, detect: [String]?,
                targets: [String], action: RuleAction, preconditions: RulePreconditions?, copy: RuleCopy) {
        self.id = id
        self.name = name
        self.app = app
        self.category = category
        self.tier = tier
        self.detect = detect
        self.targets = targets
        self.action = action
        self.preconditions = preconditions
        self.copy = copy
    }
}
```

- [ ] **Step 4: 实现 `RuleValidator.swift`**

```swift
// Sources/CleanerCore/Engine/RuleValidator.swift
import Foundation

public enum RuleOrigin: Sendable {
    case bundled, user
}

public enum RuleValidator {
    /// 个人隐私区：任何规则（包括只展示）都不得指向这些位置或其内部。
    public static func privacyRoots(home: String) -> [String] {
        ["/System", home + "/Documents", home + "/Desktop", home + "/Pictures", home + "/.ssh", home + "/.gnupg",
         home + "/Library/Keychains", home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
    }

    public static func problems(in rule: CleanRule, origin: RuleOrigin, safety: PathSafety) -> [String] {
        var out: [String] = []
        let prefix = "规则 \(rule.id)："
        if rule.id.isEmpty { out.append("规则缺少 id") }
        if rule.name.isEmpty || rule.copy.what.isEmpty || rule.copy.impact.isEmpty {
            out.append(prefix + "名称或说明文案为空")
        }
        if rule.targets.isEmpty { out.append(prefix + "没有目标路径") }
        let privacy = privacyRoots(home: safety.home)
        for target in rule.targets {
            guard target.hasPrefix("~/") || target.hasPrefix("/") else {
                out.append(prefix + "目标必须是绝对路径或 ~/ 开头：\(target)")
                continue
            }
            let components = target.split(separator: "/")
            let wildcards = components.filter { $0.contains("*") }
            if wildcards.count > 1 || wildcards.contains(where: { $0 != "*" }) {
                out.append(prefix + "通配只允许单独一段 *：\(target)")
            }
            if components.contains("..") { out.append(prefix + "目标不得含 ..：\(target)") }
            let probe = safety.normalize(target.replacingOccurrences(of: "*", with: "x"))
            if privacy.contains(where: { PathSafety.isInside(probe, root: $0) || PathSafety.isInside($0, root: probe) }) {
                out.append(prefix + "目标指向个人隐私区：\(target)")
            } else if rule.tier != .displayOnly, (try? safety.assertAllowed(probe)) == nil {
                out.append(prefix + "可执行规则的目标命中禁区：\(target)")
            }
        }
        switch rule.action.type {
        case .command:
            if (rule.action.command ?? []).isEmpty { out.append(prefix + "command 动作缺少命令") }
            if rule.tier != .safe && rule.tier != .confirm { out.append(prefix + "command 只能配安全或需要确认档") }
        case .recover:
            break
        case .recoverOlderThan:
            if (rule.action.olderThanDays ?? 0) <= 0 { out.append(prefix + "recoverOlderThan 需要正的天数") }
        case .noAction:
            if rule.tier != .displayOnly { out.append(prefix + "只有只展示档可以没有动作") }
        }
        if rule.tier == .displayOnly && rule.action.type != .noAction {
            out.append(prefix + "只展示档不得带动作")
        }
        if origin == .user {
            if rule.action.type != .recover && rule.action.type != .recoverOlderThan {
                out.append(prefix + "自定义规则只能移入恢复区")
            }
            if rule.tier != .confirm { out.append(prefix + "自定义规则固定为需要确认档") }
            if !(rule.preconditions?.pausableServices ?? []).isEmpty {
                out.append(prefix + "自定义规则不能暂停服务")
            }
        }
        return out
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter EngineRuleModelTests`
Expected: 10 tests PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/CleanerCore/Engine/RuleModel.swift Sources/CleanerCore/Engine/RuleValidator.swift Tests/CleanerCoreTests/EngineRuleModelTests.swift
git commit -m "feat(engine): add rule model and validation"
```

---

### Task 3：规则包读取与内置规则

> 执行后按代码审查修订（以仓库为准）：JetBrains 只清可重建子目录（不含本地历史）并补全 IDE 列表；移除 Yarn 与不可用模拟器两条；Poetry 只清 `cache`；Gradle 加占用检查；Xcode 编译缓存改为建议档；Claude 不代为退出；规则逐条解码、校验版本号、问题信息带来源前缀。内置规则 29 条。

**Files:**
- Create: `Sources/CleanerCore/Engine/RulePack.swift`
- Create: `Sources/CleanerCore/Engine/RulePack.json`
- Modify: `Package.swift`（CleanerCore 的 `resources`）
- Test: `Tests/CleanerCoreTests/EngineRulePackTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineRulePackTests.swift
import XCTest
@testable import CleanerCore

final class EngineRulePackTests: XCTestCase {
    let home = "/Users/tester"
    lazy var files = InMemoryFileOperations(home: home)
    lazy var safety = PathSafety(home: home, files: files)

    func testBundledPackLoadsWithoutProblems() throws {
        let data = try XCTUnwrap(RulePack.bundledData())
        let loaded = RulePack.load(bundled: data, user: nil, safety: safety)
        XCTAssertEqual(loaded.problems, [])
        XCTAssertGreaterThanOrEqual(loaded.rules.count, 25)
    }

    func testBundledCommandsAreBareNamesResolvedAtRuntime() throws {
        let loaded = RulePack.load(bundled: try XCTUnwrap(RulePack.bundledData()), user: nil, safety: safety)
        for rule in loaded.rules where rule.action.type == .command {
            XCTAssertFalse(rule.action.command!.first!.contains("/"), rule.id)
        }
    }

    func testEditorsAndIDEsAreNeverQuitForUser() throws {
        let loaded = RulePack.load(bundled: try XCTUnwrap(RulePack.bundledData()), user: nil, safety: safety)
        let editors = ["com.jetbrains.pycharm", "com.jetbrains.intellij", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        let apps = loaded.rules.flatMap { $0.preconditions?.quitApps ?? [] }
        for app in apps where editors.contains(app.bundleID) {
            XCTAssertFalse(app.canQuitForUser, app.bundleID)
        }
    }

    func testInvalidRulesAreDroppedAndReported() {
        let pack = """
        {"version":1,"platform":"macos","rules":[
          {"id":"ok","name":"OK","app":"a","category":"dev","tier":"safe","targets":["~/.npm/_cacache"],
           "action":{"type":"command","command":["npm","cache","clean","--force"]},"copy":{"what":"w","impact":"i"}},
          {"id":"bad","name":"Bad","app":"a","category":"dev","tier":"suggested","targets":["~/Documents"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}
        ]}
        """
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules.map(\.id), ["ok"])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testUserRulesCannotShadowBundledIDsOrEscalate() {
        let bundled = """
        {"version":1,"platform":"macos","rules":[
          {"id":"dup","name":"B","app":"a","category":"dev","tier":"safe","targets":["~/Library/Caches/A"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}]}
        """
        let user = """
        {"version":1,"platform":"macos","rules":[
          {"id":"dup","name":"U","app":"a","category":"dev","tier":"confirm","targets":["~/Library/Caches/B"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}},
          {"id":"mine","name":"M","app":"a","category":"other","tier":"confirm","targets":["~/Library/Caches/C"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}]}
        """
        let loaded = RulePack.load(bundled: Data(bundled.utf8), user: Data(user.utf8), safety: safety)
        XCTAssertEqual(loaded.rules.map(\.name), ["B", "M"])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testNonMacPackIsIgnored() {
        let pack = #"{"version":1,"platform":"windows","rules":[]}"#
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.problems.count, 1)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineRulePackTests`
Expected: 编译失败，找不到 `RulePack`。

- [ ] **Step 3: 实现 `RulePack.swift`**

```swift
// Sources/CleanerCore/Engine/RulePack.swift
import Foundation

public struct RulePackFile: Codable, Sendable {
    public var version: Int
    public var platform: String
    public var rules: [CleanRule]
}

public struct LoadedRules: Sendable {
    public var rules: [CleanRule]
    public var problems: [String]
}

/// 内置规则在前、自定义规则在后；不合格的规则逐条丢弃并报告，不影响其余规则。
public enum RulePack {
    public static func bundledData() -> Data? {
        guard let url = Bundle.module.url(forResource: "RulePack", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func load(bundled: Data, user: Data?, safety: PathSafety) -> LoadedRules {
        var rules: [CleanRule] = []
        var problems: [String] = []
        var seen = Set<String>()
        func add(_ data: Data, origin: RuleOrigin, label: String) {
            guard let file = try? JSONDecoder().decode(RulePackFile.self, from: data) else {
                problems.append("\(label)无法解析，已忽略")
                return
            }
            guard file.platform == "macos" else {
                problems.append("\(label)不是 macOS 规则包，已忽略")
                return
            }
            for rule in file.rules {
                let issues = RuleValidator.problems(in: rule, origin: origin, safety: safety)
                guard issues.isEmpty else { problems.append(contentsOf: issues); continue }
                guard seen.insert(rule.id).inserted else {
                    problems.append("规则 \(rule.id)：id 重复，已忽略")
                    continue
                }
                rules.append(rule)
            }
        }
        add(bundled, origin: .bundled, label: "内置规则包")
        if let user { add(user, origin: .user, label: "自定义规则文件") }
        return LoadedRules(rules: rules, problems: problems)
    }
}
```

- [ ] **Step 4: 写内置规则 `RulePack.json`**

```json
{
  "version": 1,
  "platform": "macos",
  "rules": [
    {"id": "npm-cache", "name": "npm 缓存", "app": "npm", "category": "dev", "tier": "safe",
     "targets": ["~/.npm/_cacache"], "action": {"type": "command", "command": ["npm", "cache", "clean", "--force"]},
     "copy": {"what": "npm 下载过的包缓存", "impact": "下次安装依赖时重新下载，不影响已安装的项目"}},
    {"id": "pnpm-store", "name": "pnpm 包仓库", "app": "pnpm", "category": "dev", "tier": "safe",
     "targets": ["~/Library/pnpm/store"], "action": {"type": "command", "command": ["pnpm", "store", "prune"]},
     "copy": {"what": "pnpm 全局包仓库中没有项目再引用的包", "impact": "只删未被引用的包，项目不受影响"}},
    {"id": "yarn-cache", "name": "Yarn 缓存", "app": "Yarn", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/Yarn"], "action": {"type": "command", "command": ["yarn", "cache", "clean"]},
     "copy": {"what": "Yarn 下载过的包缓存", "impact": "下次安装依赖时重新下载"}},
    {"id": "bun-cache", "name": "Bun 缓存", "app": "Bun", "category": "dev", "tier": "safe",
     "targets": ["~/.bun/install/cache"], "action": {"type": "command", "command": ["bun", "pm", "cache", "rm"]},
     "copy": {"what": "Bun 下载过的包缓存", "impact": "下次安装依赖时重新下载"}},
    {"id": "pip-cache", "name": "pip 缓存", "app": "pip", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/pip"], "action": {"type": "command", "command": ["pip3", "cache", "purge"]},
     "copy": {"what": "pip 下载过的安装包缓存", "impact": "下次安装 Python 包时重新下载，不影响已安装的环境"}},
    {"id": "uv-cache", "name": "uv 缓存", "app": "uv", "category": "dev", "tier": "safe",
     "targets": ["~/.cache/uv"], "action": {"type": "command", "command": ["uv", "cache", "prune"]},
     "preconditions": {"lockfiles": ["~/.cache/uv/.lock"]},
     "copy": {"what": "uv 缓存中不再被引用的内容", "impact": "只清理 uv 自己判断为无用的部分；与虚拟环境共用的文件不会腾出空间"}},
    {"id": "poetry-cache", "name": "Poetry 缓存", "app": "Poetry", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/pypoetry"], "action": {"type": "command", "command": ["poetry", "cache", "clear", "--all", "PyPI", "-n"]},
     "copy": {"what": "Poetry 下载过的包缓存", "impact": "下次安装依赖时重新下载"}},
    {"id": "homebrew-cleanup", "name": "Homebrew 缓存与旧版本", "app": "Homebrew", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/Homebrew"], "action": {"type": "command", "command": ["brew", "cleanup", "-s"]},
     "copy": {"what": "Homebrew 下载缓存和已升级软件的旧版本", "impact": "旧版本不可还原，需要时可重新安装"}},
    {"id": "cocoapods-cache", "name": "CocoaPods 缓存", "app": "CocoaPods", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/CocoaPods"], "action": {"type": "command", "command": ["pod", "cache", "clean", "--all"]},
     "copy": {"what": "CocoaPods 下载过的库缓存", "impact": "下次 pod install 重新下载"}},
    {"id": "gradle-caches", "name": "Gradle 缓存", "app": "Gradle", "category": "dev", "tier": "safe",
     "targets": ["~/.gradle/caches"], "action": {"type": "recover"},
     "copy": {"what": "Gradle 下载的依赖与构建缓存", "impact": "下次构建重新下载依赖，首次会变慢"}},
    {"id": "maven-repository", "name": "Maven 本地仓库", "app": "Maven", "category": "dev", "tier": "confirm",
     "targets": ["~/.m2/repository"], "action": {"type": "recover"},
     "copy": {"what": "Maven 下载的全部依赖", "impact": "仍在做 Java 项目时会重新下载全部依赖，离线环境请保留"}},
    {"id": "xcode-derived-data", "name": "Xcode 编译缓存", "app": "Xcode", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Developer/Xcode/DerivedData"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Xcode", "bundleID": "com.apple.dt.Xcode", "mayQuitForUser": false}]},
     "copy": {"what": "Xcode 的编译中间产物和索引", "impact": "下次打开项目重新编译和建索引"}},
    {"id": "xcode-unavailable-simulators", "name": "不可用的 iOS 模拟器", "app": "Xcode", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Developer/CoreSimulator/Devices"], "action": {"type": "command", "command": ["xcrun", "simctl", "delete", "unavailable"]},
     "copy": {"what": "已经没有对应系统版本的模拟器", "impact": "只删不可用的模拟器，正常的模拟器保留"}},
    {"id": "xcode-device-support", "name": "iOS 真机调试支持文件", "app": "Xcode", "category": "dev", "tier": "confirm",
     "targets": ["~/Library/Developer/Xcode/iOS DeviceSupport/*"], "action": {"type": "recover"},
     "copy": {"what": "连接过的 iOS 设备的系统符号文件", "impact": "再次连接对应系统版本的设备时 Xcode 会重新准备，需要几分钟"}},
    {"id": "jetbrains-caches", "name": "JetBrains IDE 缓存", "app": "JetBrains", "category": "dev", "tier": "suggested",
     "targets": ["~/Library/Caches/JetBrains/*"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [
       {"name": "PyCharm", "bundleID": "com.jetbrains.pycharm", "mayQuitForUser": false},
       {"name": "PyCharm CE", "bundleID": "com.jetbrains.pycharm.ce", "mayQuitForUser": false},
       {"name": "IntelliJ IDEA", "bundleID": "com.jetbrains.intellij", "mayQuitForUser": false},
       {"name": "IntelliJ IDEA CE", "bundleID": "com.jetbrains.intellij.ce", "mayQuitForUser": false},
       {"name": "WebStorm", "bundleID": "com.jetbrains.WebStorm", "mayQuitForUser": false},
       {"name": "GoLand", "bundleID": "com.jetbrains.goland", "mayQuitForUser": false}]},
     "copy": {"what": "JetBrains IDE 的索引与缓存（含旧版本 IDE 留下的）", "impact": "下次打开项目重新建索引，需要几分钟；请先保存并退出 IDE"}},
    {"id": "vscode-cache", "name": "VS Code 缓存", "app": "VS Code", "category": "dev", "tier": "suggested",
     "targets": ["~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "VS Code", "bundleID": "com.microsoft.VSCode", "mayQuitForUser": false}]},
     "copy": {"what": "VS Code 的网页缓存和旧版本数据", "impact": "不影响设置和扩展；请先保存并退出 VS Code"}},
    {"id": "playwright-browsers", "name": "Playwright 浏览器", "app": "Playwright", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/ms-playwright/*"], "action": {"type": "recover"},
     "copy": {"what": "Playwright 下载的测试浏览器", "impact": "运行测试时需要重新安装（npx playwright install）", "regrows": "运行 Playwright 测试时会重新下载"}},
    {"id": "puppeteer-browsers", "name": "Puppeteer 浏览器", "app": "Puppeteer", "category": "dev", "tier": "safe",
     "targets": ["~/.cache/puppeteer/*"], "action": {"type": "recover"},
     "copy": {"what": "Puppeteer 下载的浏览器", "impact": "下次运行时自动重新下载", "regrows": "运行 Puppeteer 时会重新下载"}},
    {"id": "camoufox-cache", "name": "Camoufox 浏览器", "app": "Camoufox", "category": "dev", "tier": "safe",
     "targets": ["~/Library/Caches/camoufox"], "action": {"type": "recover"},
     "copy": {"what": "Camoufox 下载的浏览器", "impact": "下次使用时重新下载", "regrows": "使用 Camoufox 时会重新下载"}},
    {"id": "huggingface-hub", "name": "Hugging Face 模型", "app": "Hugging Face", "category": "ai", "tier": "confirm",
     "targets": ["~/.cache/huggingface/hub/*"], "action": {"type": "recover"},
     "copy": {"what": "下载到本地的模型与数据集", "impact": "再次使用时要重新下载，大模型可能要几十 G 和很长时间"}},
    {"id": "chrome-cache-storage", "name": "Chrome 网站离线缓存", "app": "Chrome", "category": "browser", "tier": "suggested",
     "targets": ["~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Chrome", "bundleID": "com.google.Chrome"}]},
     "copy": {"what": "网站存在浏览器里的离线缓存", "impact": "不会退出登录，书签和密码不受影响；常用网站第一次打开会慢一些", "regrows": "访问网站时会逐渐重新缓存"}},
    {"id": "chrome-http-cache", "name": "Chrome 网页缓存", "app": "Chrome", "category": "browser", "tier": "suggested",
     "targets": ["~/Library/Caches/Google/Chrome/*/Cache"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Chrome", "bundleID": "com.google.Chrome"}]},
     "copy": {"what": "浏览网页时缓存的图片和脚本", "impact": "不会退出登录；网页第一次打开会慢一些", "regrows": "浏览网页时会重新缓存"}},
    {"id": "chrome-on-device-model", "name": "Chrome 内置本地 AI 模型", "app": "Chrome", "category": "browser", "tier": "confirm",
     "targets": ["~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Chrome", "bundleID": "com.google.Chrome"}]},
     "copy": {"what": "Chrome 的本地 AI 模型（Gemini Nano）", "impact": "Chrome 的 AI 写作等功能暂时不可用", "regrows": "Chrome 会自动重新下载；不想要请在 chrome://flags 搜索 Optimization Guide On Device 并设为 Disabled"}},
    {"id": "edge-cache-storage", "name": "Edge 网站离线缓存", "app": "Edge", "category": "browser", "tier": "suggested",
     "targets": ["~/Library/Application Support/Microsoft Edge/*/Service Worker/CacheStorage"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Edge", "bundleID": "com.microsoft.edgemac"}]},
     "copy": {"what": "网站存在浏览器里的离线缓存", "impact": "不会退出登录；常用网站第一次打开会慢一些", "regrows": "访问网站时会逐渐重新缓存"}},
    {"id": "cursor-db-backup", "name": "Cursor 数据库备份", "app": "Cursor", "category": "ai", "tier": "suggested",
     "targets": ["~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Cursor", "bundleID": "com.todesktop.230313mzl4w4u92", "mayQuitForUser": false}]},
     "copy": {"what": "Cursor 主数据库的旧备份（主数据库含聊天记录，不会动）", "impact": "Cursor 下次运行时可能重新生成备份"}},
    {"id": "cursor-cache", "name": "Cursor 缓存", "app": "Cursor", "category": "ai", "tier": "suggested",
     "targets": ["~/Library/Application Support/Cursor/Cache", "~/Library/Application Support/Cursor/CachedData"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Cursor", "bundleID": "com.todesktop.230313mzl4w4u92", "mayQuitForUser": false}]},
     "copy": {"what": "Cursor 的网页缓存和旧版本数据", "impact": "不影响设置、扩展和聊天记录；请先保存并退出 Cursor"}},
    {"id": "claude-vm-bundles", "name": "Claude 桌面端虚拟机镜像", "app": "Claude", "category": "ai", "tier": "confirm",
     "targets": ["~/Library/Application Support/Claude/vm_bundles"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Claude", "bundleID": "com.anthropic.claudefordesktop"}]},
     "copy": {"what": "Claude 桌面端运行虚拟机用的系统镜像", "impact": "用到需要虚拟机的功能时会重新下载，约 10G", "regrows": "使用 Claude 桌面端的虚拟机功能时会重新下载"}},
    {"id": "claude-desktop-cache", "name": "Claude 桌面端缓存", "app": "Claude", "category": "ai", "tier": "suggested",
     "targets": ["~/Library/Application Support/Claude/Cache", "~/Library/Application Support/Claude/Code Cache"], "action": {"type": "recover"},
     "preconditions": {"quitApps": [{"name": "Claude", "bundleID": "com.anthropic.claudefordesktop"}]},
     "copy": {"what": "Claude 桌面端的网页缓存", "impact": "不影响对话记录；下次打开会稍慢", "regrows": "使用时会重新缓存"}},
    {"id": "codex-sessions", "name": "Codex 会话记录", "app": "Codex", "category": "ai", "tier": "displayOnly",
     "targets": ["~/.codex/sessions"], "action": {"type": "none"},
     "copy": {"what": "Codex 的历史会话", "impact": "有历史价值，工具只展示占用"}},
    {"id": "claude-code-projects", "name": "Claude Code 会话记录", "app": "Claude Code", "category": "ai", "tier": "displayOnly",
     "targets": ["~/.claude/projects"], "action": {"type": "none"},
     "copy": {"what": "Claude Code 的历史会话", "impact": "有历史价值，工具只展示占用"}},
    {"id": "docker-disk", "name": "Docker 虚拟磁盘", "app": "Docker", "category": "dev", "tier": "displayOnly",
     "targets": ["~/Library/Containers/com.docker.docker/Data/vms/0/data"], "action": {"type": "none"},
     "copy": {"what": "Docker 所有镜像、容器和数据卷所在的虚拟磁盘", "impact": "只展示总占用；可清理的内容见 Docker 各项（需先启动 Docker）"}}
  ]
}
```

- [ ] **Step 5: 在 `Package.swift` 声明资源**

把 CleanerCore target 的 `resources: [.copy("DefaultRules.json")]` 改为：

```swift
            resources: [.copy("DefaultRules.json"), .copy("Engine/RulePack.json")]
```

- [ ] **Step 6: 运行确认通过**

Run: `swift test --filter EngineRulePackTests`
Expected: 6 tests PASS。若 `testBundledPackLoadsWithoutProblems` 失败，按 `problems` 内容修正 JSON，不要放宽校验。

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CleanerCore/Engine/RulePack.swift Sources/CleanerCore/Engine/RulePack.json Tests/CleanerCoreTests/EngineRulePackTests.swift
git commit -m "feat(engine): add rule pack loading and bundled rules"
```

---

### Task 4：清理项、阻塞原因与命令查找

> 执行后按代码审查修订（以仓库为准）：nvm 版本按数字排序；只有普通文件或指向普通文件的符号链接才算找到命令；绝对路径先规范化再检查。

**Files:**
- Create: `Sources/CleanerCore/Engine/CleanItem.swift`
- Create: `Sources/CleanerCore/Engine/ExecutableResolver.swift`
- Create: `Tests/CleanerCoreTests/EngineTestSupport.swift`
- Test: `Tests/CleanerCoreTests/EngineRuleDetectorTests.swift`（本任务先放命令查找的测试）

- [ ] **Step 1: 写测试辅助与失败测试**

```swift
// Tests/CleanerCoreTests/EngineTestSupport.swift
import Foundation
@testable import CleanerCore

enum EngineFixture {
    static let home = "/Users/tester"

    static func context(_ files: InMemoryFileOperations, runner: FakeProcessRunner = FakeProcessRunner(),
                        now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> DetectContext {
        DetectContext(files: files, safety: PathSafety(home: files.homeDirectory(), files: files), runner: runner, now: now)
    }

    static func daysBefore(_ days: Double, _ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }
}
```

```swift
// Tests/CleanerCoreTests/EngineRuleDetectorTests.swift
import XCTest
@testable import CleanerCore

final class EngineRuleDetectorTests: XCTestCase {
    func testResolverFindsExecutableInFixedDirectoriesNotPATH() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v18.0.0/bin/npm", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v22.1.0/bin/npm", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("uv"), "/opt/homebrew/bin/uv")
        XCTAssertEqual(resolver.resolve("npm"), EngineFixture.home + "/.nvm/versions/node/v22.1.0/bin/npm")
        XCTAssertNil(resolver.resolve("pnpm"))
        XCTAssertNil(resolver.resolve("bin/uv"))
        XCTAssertEqual(resolver.resolve("/opt/homebrew/bin/uv"), "/opt/homebrew/bin/uv")
    }

    func testCommandLineToolShimsAreSkippedUntilToolsInstalled() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile("/usr/bin/git", size: 1)
        files.makeFile("/usr/bin/pip3", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertNil(resolver.resolve("git"))
        XCTAssertNil(resolver.resolve("/usr/bin/pip3"))
        files.makeFile("/Library/Developer/CommandLineTools/usr/bin/git", size: 1)
        XCTAssertEqual(resolver.resolve("git"), "/usr/bin/git")
        XCTAssertEqual(resolver.resolve("pip3"), "/usr/bin/pip3")
    }

    func testBlockerMessages() {
        XCTAssertEqual(Blocker.appRunning(name: "Chrome", bundleID: "com.google.Chrome").message, "需先退出 Chrome")
        XCTAssertEqual(Blocker.occupied("uv(12)").message, "被占用：uv(12)")
        XCTAssertTrue(Blocker.appRunning(name: "a", bundleID: "b").isAppRunning)
        XCTAssertFalse(Blocker.occupied("x").isAppRunning)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineRuleDetectorTests`
Expected: 编译失败，找不到 `DetectContext`、`ExecutableResolver`、`Blocker`。

- [ ] **Step 3: 实现 `CleanItem.swift`**

```swift
// Sources/CleanerCore/Engine/CleanItem.swift
import Foundation

public enum Blocker: Codable, Equatable, Hashable, Sendable {
    case appRunning(name: String, bundleID: String)
    case occupied(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .appRunning(let name, _): return "需先退出 \(name)"
        case .occupied(let who): return "被占用：\(who)"
        case .unavailable(let why): return why
        }
    }

    public var isAppRunning: Bool {
        if case .appRunning = self { return true }
        return false
    }
}

/// 界面展示与执行的最小单位。
public struct CleanItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var app: String
    public var category: AppCategory
    public var tier: CleanTier
    public var title: String
    public var paths: [String]
    public var action: RuleAction
    public var preconditions: RulePreconditions
    public var copy: RuleCopy
    public var apparentBytes: Int64
    public var reclaimableBytes: Int64
    public var blockers: [Blocker]
    public var notes: [String]
    /// 大小由识别器给出（Docker、空间分布），扫描时不再遍历路径。
    public var sizedByDetector: Bool

    public init(id: String, app: String, category: AppCategory, tier: CleanTier, title: String, paths: [String],
                action: RuleAction, preconditions: RulePreconditions, copy: RuleCopy, notes: [String] = []) {
        self.id = id
        self.app = app
        self.category = category
        self.tier = tier
        self.title = title
        self.paths = paths
        self.action = action
        self.preconditions = preconditions
        self.copy = copy
        self.apparentBytes = 0
        self.reclaimableBytes = 0
        self.blockers = []
        self.notes = notes
        self.sizedByDetector = false
    }
}
```

- [ ] **Step 4: 实现 `ExecutableResolver.swift` 与 `Detector.swift`**

```swift
// Sources/CleanerCore/Engine/ExecutableResolver.swift
import Foundation

/// 在固定目录中查找命令。菜单栏应用继承的 PATH 不完整，不能依赖它。
public struct ExecutableResolver {
    public let files: FileOperations

    public init(files: FileOperations) { self.files = files }

    public func searchDirectories() -> [String] {
        let home = files.homeDirectory()
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin", home + "/.cargo/bin"]
        if let versions = try? files.childrenOfDirectory(atPath: home + "/.nvm/versions/node") {
            dirs += versions.sorted().reversed().map { $0 + "/bin" }
        }
        return dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// 没装命令行工具时，/usr/bin 下这几个只是弹出安装对话框的占位程序，运行即打扰用户。
    static let commandLineToolShims: Set<String> = ["git", "pip3", "python3"]

    func commandLineToolsInstalled() -> Bool {
        files.fileExists("/Library/Developer/CommandLineTools/usr/bin/git")
            || files.fileExists("/Applications/Xcode.app/Contents/Developer/usr/bin/git")
    }

    func isShim(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return (path as NSString).deletingLastPathComponent == "/usr/bin"
            && Self.commandLineToolShims.contains(name) && !commandLineToolsInstalled()
    }

    /// 绝对路径原样校验存在；裸命令名按固定目录查找；含 / 的相对路径一律拒绝。
    public func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") { return files.fileExists(name) && !isShim(name) ? name : nil }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in searchDirectories() {
            let candidate = dir + "/" + name
            if isShim(candidate) { continue }
            if let attributes = files.attributesIfExist(atPath: candidate),
               attributes.isRegularFile || attributes.isSymbolicLink {
                return candidate
            }
        }
        return nil
    }
}
```

```swift
// Sources/CleanerCore/Engine/Detector.swift
import Foundation

public struct DetectContext {
    public let files: FileOperations
    public let safety: PathSafety
    public let runner: ProcessRunner
    public let now: Date

    public init(files: FileOperations, safety: PathSafety, runner: ProcessRunner, now: Date) {
        self.files = files
        self.safety = safety
        self.runner = runner
        self.now = now
    }

    public var home: String { files.homeDirectory() }
}

/// 识别器只读：只能查看文件与运行只读命令，产出清理项，不做任何修改。
public protocol Detector {
    func detect(_ context: DetectContext) -> [CleanItem]
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter EngineRuleDetectorTests`
Expected: 3 tests PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/CleanerCore/Engine/CleanItem.swift Sources/CleanerCore/Engine/ExecutableResolver.swift Sources/CleanerCore/Engine/Detector.swift Tests/CleanerCoreTests/EngineTestSupport.swift Tests/CleanerCoreTests/EngineRuleDetectorTests.swift
git commit -m "feat(engine): add clean item, blockers and executable resolver"
```

---

### Task 5：空间估算 Sizer

> 执行后按代码审查修订（以仓库为准）：起始路径先规范化、去重并去掉嵌套的子路径；inode 键改为结构体；扫描中途消失的目录不算「无法读取」；`perPath` 以规范化后的路径为键。

**Files:**
- Create: `Sources/CleanerCore/Engine/Sizer.swift`
- Test: `Tests/CleanerCoreTests/EngineSizerTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

在 `EngineSizerTests` 类中追加：

```swift
    func testHardLinksInsideScopeCountOnceAndAreReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/scope/a")
        try FileManager.default.linkItem(atPath: dir + "/scope/a", toPath: dir + "/scope/b")
        let files = RealFileOperations(home: dir)
        let size = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/scope/a")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/scope"])
        XCTAssertEqual(m.apparent, size)
        XCTAssertEqual(m.reclaimable, size)
        XCTAssertEqual(m.perPath[dir + "/scope"], size)
    }

    func testHardLinkWithCopyOutsideScopeIsNotReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/cache/a")
        try TestEnv.write(String(repeating: "y", count: 10_000), to: dir + "/cache/plain")
        try FileManager.default.createDirectory(atPath: dir + "/venv", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: dir + "/cache/a", toPath: dir + "/venv/a")
        let files = RealFileOperations(home: dir)
        let linked = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/cache/a")).allocatedSize
        let plain = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/cache/plain")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/cache"])
        XCTAssertEqual(m.apparent, linked + plain)
        XCTAssertEqual(m.reclaimable, plain)
    }

    func testMissingPathsCountZero() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let m = Sizer(files: files).measure([EngineFixture.home + "/nope"])
        XCTAssertEqual(m.apparent, 0)
        XCTAssertEqual(m.reclaimable, 0)
    }

    func testUnreadableDirectoriesAreReportedNotGuessed() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/scope/locked")
            TestEnv.remove(dir)
        }
        try TestEnv.write("secret", to: dir + "/scope/locked/f")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir + "/scope/locked")
        let m = Sizer(files: RealFileOperations(home: dir)).measure([dir + "/scope"])
        XCTAssertEqual(m.unreadable, [dir + "/scope/locked"])
    }

    func testInMemoryFilesWithoutLinkInfoAreFullyReclaimable() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/a", size: 300)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/sub/b", size: 200)
        let m = Sizer(files: files).measure([EngineFixture.home + "/.npm/_cacache"])
        XCTAssertEqual(m.apparent, 500)
        XCTAssertEqual(m.reclaimable, 500)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineSizerTests`
Expected: 编译失败，找不到 `Sizer`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/Sizer.swift
import Foundation

public struct SizeMeasurement: Equatable, Sendable {
    public var apparent: Int64
    public var reclaimable: Int64
    /// 每个起始路径的表观大小（空间分布扣除已列出项时用）
    public var perPath: [String: Int64]
    /// 无法列出内容的目录（通常是缺少完全磁盘访问权限）；其大小未计入，不猜测
    public var unreadable: [String]
}

/// 表观大小：同一 inode 只计一次（du 口径）。
/// 可释放量：硬链接文件只有在它的全部链接都位于本次范围内时才计入——
/// 否则删掉这一处，数据仍被范围外的链接占着（uv 缓存与虚拟环境就是这种情况）。
/// 符号链接只计自身，不跟随。
public struct Sizer {
    public let files: FileOperations

    public init(files: FileOperations) { self.files = files }

    public func measure(_ paths: [String]) -> SizeMeasurement {
        var result = SizeMeasurement(apparent: 0, reclaimable: 0, perPath: [:], unreadable: [])
        var links: [String: (seen: UInt32, total: UInt32, bytes: Int64)] = [:]
        for root in paths {
            var rootBytes: Int64 = 0
            var stack = [root]
            while let path = stack.popLast() {
                guard let attributes = files.attributesIfExist(atPath: path) else { continue }
                if attributes.isDirectory && !attributes.isSymbolicLink {
                    do {
                        stack.append(contentsOf: try files.childrenOfDirectory(atPath: path))
                    } catch FileOpError.notFound {
                        // 扫描期间消失属正常波动
                    } catch {
                        result.unreadable.append(path)
                    }
                    continue
                }
                if attributes.isRegularFile, let total = attributes.linkCount, total > 1,
                   let device = attributes.device, let inode = attributes.inode {
                    let key = "\(device):\(inode)"
                    if var entry = links[key] {
                        entry.seen += 1
                        links[key] = entry
                        continue
                    }
                    links[key] = (1, total, attributes.allocatedSize)
                    rootBytes += attributes.allocatedSize
                } else {
                    rootBytes += attributes.allocatedSize
                    result.reclaimable += attributes.allocatedSize
                }
            }
            result.perPath[root] = rootBytes
            result.apparent += rootBytes
        }
        for entry in links.values where entry.seen >= entry.total {
            result.reclaimable += entry.bytes
        }
        return result
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineSizerTests`
Expected: 7 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/Sizer.swift Tests/CleanerCoreTests/EngineSizerTests.swift
git commit -m "feat(engine): add hard-link-aware size estimation"
```

---

### Task 6：规则识别器 RuleDetector

> 执行后按代码审查修订（以仓库为准）：新增 `EnginePathChecks.isCanonical`，展开后的路径任何一层是符号链接都丢弃；只展示项对解析后的路径也做隐私区检查；`recoverOlderThan` 只列普通文件且逐个过 `assertAllowed`；同一项内去重并去掉嵌套路径。

**Files:**
- Create: `Sources/CleanerCore/Engine/RuleDetector.swift`
- Test: `Tests/CleanerCoreTests/EngineRuleDetectorTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

在 `EngineRuleDetectorTests` 类中追加：

```swift
    func rule(_ id: String, tier: CleanTier = .safe, targets: [String], action: RuleAction = .recover,
              detect: [String]? = nil) -> CleanRule {
        CleanRule(id: id, name: id, app: "App", category: .dev, tier: tier, detect: detect, targets: targets,
                  action: action, preconditions: nil, copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    }

    func testExistingTargetsBecomeOneItemPerRule() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.gradle/caches/x", size: 10)
        let items = RuleDetector(rules: [rule("gradle", targets: ["~/.gradle/caches", "~/.gradle/missing"])])
            .detect(EngineFixture.context(files))
        XCTAssertEqual(items.map(\.id), ["rule:gradle"])
        XCTAssertEqual(items[0].paths, [EngineFixture.home + "/.gradle/caches"])
    }

    func testMissingTargetsProduceNoItem() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        XCTAssertEqual(RuleDetector(rules: [rule("g", targets: ["~/.gradle/caches"])]).detect(EngineFixture.context(files)), [])
    }

    func testWildcardExpandsToDirectoriesOnly() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/PyCharm2025.2/a", size: 1)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/IntelliJIdea2025.2/a", size: 1)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/stray.txt", size: 1)
        files.makeSymlink(at: EngineFixture.home + "/Library/Caches/JetBrains/link", target: "/tmp")
        let items = RuleDetector(rules: [rule("jb", targets: ["~/Library/Caches/JetBrains/*"])]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [EngineFixture.home + "/Library/Caches/JetBrains/IntelliJIdea2025.2",
                                        EngineFixture.home + "/Library/Caches/JetBrains/PyCharm2025.2"])
    }

    func testWildcardInMiddleKeepsSuffix() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let base = EngineFixture.home + "/Library/Application Support/Google/Chrome"
        files.makeFile(base + "/Default/Service Worker/CacheStorage/x", size: 1)
        files.makeFile(base + "/Profile 1/Preferences", size: 1)
        let items = RuleDetector(rules: [rule("c", tier: .suggested, targets: ["~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"])])
            .detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [base + "/Default/Service Worker/CacheStorage"])
    }

    func testCommandRuleNeedsExecutable() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/a", size: 1)
        let r = rule("npm", targets: ["~/.npm/_cacache"], action: .command(["npm", "cache", "clean", "--force"]))
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)), [])
        files.makeFile("/usr/local/bin/npm", size: 1)
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)).count, 1)
    }

    func testDetectPathsGateTheRule() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Library/Caches/Foo/a", size: 1)
        let gated = rule("foo", targets: ["~/Library/Caches/Foo"], detect: ["/Applications/Foo.app"])
        XCTAssertEqual(RuleDetector(rules: [gated]).detect(EngineFixture.context(files)), [])
        files.makeDirectory("/Applications/Foo.app")
        XCTAssertEqual(RuleDetector(rules: [gated]).detect(EngineFixture.context(files)).count, 1)
    }

    func testSymlinkTargetsAreSkipped() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeSymlink(at: EngineFixture.home + "/.gradle/caches", target: EngineFixture.home + "/Documents")
        XCTAssertEqual(RuleDetector(rules: [rule("g", targets: ["~/.gradle/caches"])]).detect(EngineFixture.context(files)), [])
    }

    func testRecoverOlderThanListsOnlyOldChildren() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let dir = EngineFixture.home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/old.ips", size: 5, modifiedAt: EngineFixture.daysBefore(40))
        files.makeFile(dir + "/new.ips", size: 5, modifiedAt: EngineFixture.daysBefore(3))
        let r = rule("diag", targets: ["~/Library/Logs/DiagnosticReports"], action: RuleAction(type: .recoverOlderThan, olderThanDays: 30))
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [dir + "/old.ips"])
    }

    func testDisplayOnlyRulesMayPointIntoForbiddenTrees() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.codex/sessions/2026/a.jsonl", size: 9)
        let r = rule("codex", tier: .displayOnly, targets: ["~/.codex/sessions"], action: .noAction)
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)).count, 1)
        let actionable = rule("codex2", tier: .confirm, targets: ["~/.codex/sessions"])
        XCTAssertEqual(RuleDetector(rules: [actionable]).detect(EngineFixture.context(files)), [])
    }

    func testDisplayOnlyExpansionNeverLandsInPrivacyRoots() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Documents/a", size: 1)
        files.makeFile(EngineFixture.home + "/Downloads/a", size: 1)
        // 绕过校验直接构造规则，验证识别器自身的防线
        let r = rule("wide", tier: .displayOnly, targets: ["~/*"], action: .noAction)
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items.first?.paths, [EngineFixture.home + "/Downloads"])
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineRuleDetectorTests`
Expected: 编译失败，找不到 `RuleDetector`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/RuleDetector.swift
import Foundation

public struct RuleDetector: Detector {
    public let rules: [CleanRule]

    public init(rules: [CleanRule]) { self.rules = rules }

    public func detect(_ context: DetectContext) -> [CleanItem] {
        rules.compactMap { item(for: $0, context) }
    }

    /// 展开 ~ 与单独一段 *（只匹配真实目录，不跟随符号链接）；只返回存在的路径。
    func expand(_ template: String, _ context: DetectContext) -> [String] {
        let path = context.safety.normalize(template)
        guard path.contains("*") else { return context.files.fileExists(path) ? [path] : [] }
        let components = path.split(separator: "/").map(String.init)
        guard let star = components.firstIndex(of: "*") else { return [] }
        let parent = "/" + components[..<star].joined(separator: "/")
        let rest = components[(star + 1)...].joined(separator: "/")
        guard let children = try? context.files.childrenOfDirectory(atPath: parent) else { return [] }
        return children
            .filter { child in
                guard let attributes = context.files.attributesIfExist(atPath: child) else { return false }
                return attributes.isDirectory && !attributes.isSymbolicLink
            }
            .map { rest.isEmpty ? $0 : $0 + "/" + rest }
            .filter { context.files.fileExists($0) }
    }

    func item(for rule: CleanRule, _ context: DetectContext) -> CleanItem? {
        if let detect = rule.detect, !detect.isEmpty,
           !detect.contains(where: { context.files.fileExists(context.safety.normalize($0)) }) {
            return nil
        }
        if rule.action.type == .command,
           let name = rule.action.command?.first,
           ExecutableResolver(files: context.files).resolve(name) == nil {
            return nil
        }
        let privacy = RuleValidator.privacyRoots(home: context.home).map { $0.lowercased() }
        var paths = rule.targets.flatMap { expand($0, context) }.filter { path in
            guard context.files.attributesIfExist(atPath: path)?.isSymbolicLink == false else { return false }
            if rule.tier == .displayOnly {
                // 第二道防线：只展示项不走 assertAllowed，展开后仍不得落入个人隐私区（不区分大小写）
                return !privacy.contains { PathSafety.isInside(path.lowercased(), root: $0) }
            }
            return (try? context.safety.assertAllowed(path)) != nil
        }
        if rule.action.type == .recoverOlderThan, let days = rule.action.olderThanDays {
            let cutoff = context.now.addingTimeInterval(-Double(days) * 86_400)
            paths = paths.flatMap { (try? context.files.childrenOfDirectory(atPath: $0)) ?? [] }.filter { child in
                guard let attributes = context.files.attributesIfExist(atPath: child), !attributes.isSymbolicLink,
                      let modified = attributes.modificationDate else { return false }
                return modified < cutoff
            }
        }
        guard !paths.isEmpty else { return nil }
        return CleanItem(id: "rule:" + rule.id, app: rule.app, category: rule.category, tier: rule.tier, title: rule.name,
                         paths: paths.sorted(), action: rule.action, preconditions: rule.preconditions ?? .empty,
                         copy: rule.copy)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineRuleDetectorTests`
Expected: 13 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/RuleDetector.swift Tests/CleanerCoreTests/EngineRuleDetectorTests.swift
git commit -m "feat(engine): add rule-based detector"
```

---

### Task 7：项目产物识别器

> 执行后按代码审查修订（以仓库为准）：git 调用加 `--no-optional-locks -c core.fsmonitor=false`，status 不看未跟踪文件、不进子模块，只对会展示的项目运行；生成物目录按类型匹配工程标记（去掉 Makefile）；排除 conda/flutter/go 等安装目录、家目录级产物和全局 npm 前缀；闲置时间计入 `.git/index`、`.git/HEAD` 与目录修改时间，读不到提交时间最多为需要确认档；lockfile 只对依赖目录逐个要求。第二轮：不再运行 `git log`，提交时间读 `.git/logs/HEAD`；`git status` 仅在 `git config --show-scope` 显示无 local/worktree 过滤器时运行；只凭 package.json 判断的 `build` 最多为需要确认档。

**Files:**
- Create: `Sources/CleanerCore/Engine/ProjectArtifactDetector.swift`
- Test: `Tests/CleanerCoreTests/EngineProjectDetectorTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineProjectDetectorTests.swift
import XCTest
@testable import CleanerCore

final class EngineProjectDetectorTests: XCTestCase {
    let home = EngineFixture.home
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    /// 项目根 → 最后提交距今天数
    var commits: [String: Double] = [:]
    var dirty: [String: Int] = [:]

    override func setUp() {
        files = InMemoryFileOperations(home: home)
        files.makeFile("/opt/homebrew/bin/git", size: 1)
        runner = FakeProcessRunner()
        commits = [:]
        dirty = [:]
        runner.handler = { [unowned self] path, args in
            guard path == "/opt/homebrew/bin/git", args.count >= 3 else { return nil }
            let root = args[1]
            if args[2] == "log", let days = self.commits[root] {
                let ts = Int(EngineFixture.daysBefore(days).timeIntervalSince1970)
                return ProcessResult(exitStatus: 0, stdout: "\(ts)\n", stderr: "")
            }
            if args[2] == "status" {
                let lines = Array(repeating: " M f", count: self.dirty[root] ?? 0).joined(separator: "\n")
                return ProcessResult(exitStatus: 0, stdout: lines, stderr: "")
            }
            return ProcessResult(exitStatus: 128, stdout: "", stderr: "")
        }
    }

    func gitProject(_ rel: String, idleDays: Double, lock: String? = "package-lock.json") -> String {
        let root = home + "/" + rel
        files.makeDirectory(root + "/.git")
        if let lock { files.makeFile(root + "/" + lock, size: 1) }
        files.makeFile(root + "/package.json", size: 1)
        commits[root] = idleDays
        return root
    }

    func detect() -> [CleanItem] {
        ProjectArtifactDetector().detect(EngineFixture.context(files, runner: runner))
    }

    func testIdleProjectOver90DaysIsSuggested() {
        let root = gitProject("work/app", idleDays: 100)
        files.makeFile(root + "/node_modules/x/index.js", size: 50)
        files.makeFile(root + "/backend/.venv/lib/a.py", size: 50)
        let items = detect()
        XCTAssertEqual(items.map(\.id), ["project:" + root])
        XCTAssertEqual(items[0].tier, .suggested)
        XCTAssertEqual(items[0].paths, [root + "/backend/.venv", root + "/node_modules"])
        XCTAssertEqual(items[0].action.type, .recover)
        XCTAssertTrue(items[0].notes.contains("闲置 100 天"))
    }

    func test30To90DaysIsConfirmAndUnder30IsIgnored() {
        let mid = gitProject("work/mid", idleDays: 45)
        files.makeFile(mid + "/node_modules/a", size: 1)
        let fresh = gitProject("work/fresh", idleDays: 5)
        files.makeFile(fresh + "/node_modules/a", size: 1)
        let items = detect()
        XCTAssertEqual(items.map(\.id), ["project:" + mid])
        XCTAssertEqual(items[0].tier, .confirm)
    }

    func testNonGitProjectUsesSourceModificationTime() {
        let root = home + "/scratch/tool"
        files.makeFile(root + "/requirements.txt", size: 1, modifiedAt: EngineFixture.daysBefore(120))
        files.makeFile(root + "/main.py", size: 1, modifiedAt: EngineFixture.daysBefore(95))
        files.makeFile(root + "/venv/bin/python", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        let items = detect()
        XCTAssertEqual(items.first?.tier, .suggested)
        XCTAssertEqual(items.first?.paths, [root + "/venv"])
    }

    func testMissingLockfileDowngradesToConfirmWithNote() {
        let root = gitProject("work/nolock", idleDays: 200, lock: nil)
        files.makeFile(root + "/node_modules/a", size: 1)
        let item = detect()[0]
        XCTAssertEqual(item.tier, .confirm)
        XCTAssertTrue(item.notes.contains { $0.contains("lockfile") })
    }

    func testDirtySourceIsNotedButNotBlocking() {
        let root = gitProject("work/dirty", idleDays: 100)
        files.makeFile(root + "/node_modules/a", size: 1)
        dirty[root] = 3
        let item = detect()[0]
        XCTAssertEqual(item.tier, .suggested)
        XCTAssertTrue(item.notes.contains { $0.contains("3 处未提交改动") })
    }

    func testBuildDirectoryNeedsProjectMarker() {
        let root = home + "/notes"
        files.makeFile(root + "/build/report.pdf", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        XCTAssertEqual(detect(), [])
    }

    func testToolDirectoriesAppBundlesAndDocumentsAreExcluded() {
        let hidden = home + "/.hermes/agent"
        files.makeFile(hidden + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(hidden + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        let app = home + "/tmp/Tool.app/Contents/Resources/app"
        files.makeFile(app + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(app + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        let docs = home + "/Documents/proj"
        files.makeFile(docs + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(docs + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        XCTAssertEqual(detect(), [])
    }

    func testWithoutUsableGitFallsBackToModificationTimeAndNeverRunsShim() throws {
        try files.removeItem(atPath: "/opt/homebrew/bin/git")
        files.makeFile("/usr/bin/git", size: 1) // 未装命令行工具时的占位程序
        let root = gitProject("work/old", idleDays: 1)
        files.makeFile(root + "/index.js", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/node_modules/a", size: 1)
        XCTAssertEqual(detect().first?.tier, .suggested)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNestedArtifactsAreNotDescendedInto() {
        let root = gitProject("work/nested", idleDays: 100)
        files.makeFile(root + "/node_modules/pkg/node_modules/deep/a", size: 1)
        XCTAssertEqual(detect()[0].paths, [root + "/node_modules"])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineProjectDetectorTests`
Expected: 编译失败，找不到 `ProjectArtifactDetector`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/ProjectArtifactDetector.swift
import Foundation

/// 按项目聚合 node_modules、.venv 等产物，按最后活跃时间分档。
/// 最后活跃 = git 最后提交与源码（项目根及下一层，排除产物目录）修改时间取较新者。
public struct ProjectArtifactDetector: Detector {
    public static let artifactNames: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".nuxt", "dist", "build", "coverage", "__pycache__",
        ".turbo", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".ruff_cache", "Pods", "DerivedData", ".gradle"]
    /// 这些名字太常见，同级必须有工程标记文件才算产物。
    static let needsMarker: Set<String> = ["build", "dist", "coverage", "target"]
    static let markers = ["package.json", "pyproject.toml", "setup.py", "Cargo.toml", "pom.xml", "build.gradle",
                          "build.gradle.kts", "Makefile", "Podfile"]
    static let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "uv.lock",
                            "poetry.lock", "Pipfile.lock", "requirements.txt", "Cargo.lock", "Podfile.lock", "pom.xml",
                            "build.gradle", "build.gradle.kts", "go.sum"]
    static let skippedHomeChildren: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]

    public var maxDepth = 6
    public var suggestAfterDays = 90
    public var confirmAfterDays = 30

    public init() {}

    public func detect(_ context: DetectContext) -> [CleanItem] {
        var byProject: [String: [String]] = [:]
        for artifact in findArtifacts(context) {
            byProject[projectRoot(of: artifact, context), default: []].append(artifact)
        }
        return byProject.keys.sorted().compactMap { makeItem(root: $0, artifacts: byProject[$0]!.sorted(), context) }
    }

    func findArtifacts(_ context: DetectContext) -> [String] {
        var found: [String] = []
        var stack: [(String, Int)] = [(context.home, 0)]
        while let entry = stack.popLast() {
            let (dir, depth) = entry
            guard depth < maxDepth, let children = try? context.files.childrenOfDirectory(atPath: dir) else { continue }
            for child in children {
                let name = (child as NSString).lastPathComponent
                guard let attributes = context.files.attributesIfExist(atPath: child),
                      attributes.isDirectory, !attributes.isSymbolicLink else { continue }
                // 家目录下的隐藏目录是各工具自己的安装与数据目录（如 ~/.hermes、~/.nvm），不当项目处理
                if depth == 0 && (name.hasPrefix(".") || Self.skippedHomeChildren.contains(name)) { continue }
                if name == ".git" || name.hasSuffix(".app") { continue }
                if context.safety.treeForbiddenRoots.contains(where: { PathSafety.isInside(child, root: $0) }) { continue }
                if Self.artifactNames.contains(name) {
                    let hasMarker = Self.markers.contains { context.files.fileExists(dir + "/" + $0) }
                    if Self.needsMarker.contains(name) && !hasMarker {
                        stack.append((child, depth + 1))
                        continue
                    }
                    found.append(child)
                    continue
                }
                stack.append((child, depth + 1))
            }
        }
        return found
    }

    /// 向上找最近的 git 仓库根；找不到则以产物所在目录为项目。
    func projectRoot(of artifact: String, _ context: DetectContext) -> String {
        let parent = (artifact as NSString).deletingLastPathComponent
        var current = parent
        while current != context.home && PathSafety.isInside(current, root: context.home) {
            if context.files.fileExists(current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return parent
    }

    func makeItem(root: String, artifacts: [String], _ context: DetectContext) -> CleanItem? {
        let allowed = artifacts.filter { (try? context.safety.assertAllowed($0)) != nil }
        guard !allowed.isEmpty else { return nil }
        let git = gitInfo(root, context)
        guard let lastActive = [git.lastCommit, newestSourceModification(root, context)].compactMap({ $0 }).max() else {
            return nil
        }
        let idleDays = Int(context.now.timeIntervalSince(lastActive) / 86_400)
        let hasLockfile = allowed.contains { artifact in
            [(artifact as NSString).deletingLastPathComponent, root].contains { dir in
                Self.lockfiles.contains { context.files.fileExists(dir + "/" + $0) }
            }
        }
        let tier: CleanTier
        if idleDays >= suggestAfterDays {
            tier = hasLockfile ? .suggested : .confirm
        } else if idleDays >= confirmAfterDays {
            tier = .confirm
        } else {
            return nil
        }
        let name = (root as NSString).lastPathComponent
        var notes = ["闲置 \(idleDays) 天"]
        if !hasLockfile { notes.append("未找到 lockfile，重建后依赖版本可能变化") }
        if let dirty = git.dirtyCount, dirty > 0 {
            notes.append("源码有 \(dirty) 处未提交改动（本次只清理依赖与构建产物，不影响源码）")
        }
        let kinds = Set(allowed.map { ($0 as NSString).lastPathComponent }).sorted().joined(separator: "、")
        return CleanItem(
            id: "project:" + root, app: "项目：" + name, category: .dev, tier: tier,
            title: "项目 \(name) 的依赖与构建产物", paths: allowed, action: .recover, preconditions: .empty,
            copy: RuleCopy(what: "\(kinds)，共 \(allowed.count) 个目录",
                           impact: "删后需在项目内重新安装依赖或重新构建（如 uv sync、npm i）", regrows: nil),
            notes: notes)
    }

    struct GitInfo {
        var lastCommit: Date?
        var dirtyCount: Int?
    }

    /// 找不到可用的 git（包括没装命令行工具时的 /usr/bin/git 占位程序）就只用文件修改时间。
    func gitInfo(_ root: String, _ context: DetectContext) -> GitInfo {
        guard context.files.fileExists(root + "/.git"),
              let git = ExecutableResolver(files: context.files).resolve("git") else { return GitInfo() }
        var info = GitInfo()
        if let result = context.runner.run(launchPath: git, arguments: ["-C", root, "log", "-1", "--format=%ct"]),
           result.exitStatus == 0,
           let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            info.lastCommit = Date(timeIntervalSince1970: seconds)
        }
        if let result = context.runner.run(launchPath: git, arguments: ["-C", root, "status", "--porcelain"]),
           result.exitStatus == 0 {
            info.dirtyCount = result.stdout.split(whereSeparator: \.isNewline).count
        }
        return info
    }

    func newestSourceModification(_ root: String, _ context: DetectContext) -> Date? {
        var newest: Date?
        var stack: [(String, Int)] = [(root, 0)]
        while let entry = stack.popLast() {
            let (dir, depth) = entry
            guard let children = try? context.files.childrenOfDirectory(atPath: dir) else { continue }
            for child in children {
                let name = (child as NSString).lastPathComponent
                guard let attributes = context.files.attributesIfExist(atPath: child), !attributes.isSymbolicLink else { continue }
                if attributes.isDirectory {
                    if depth < 1 && !Self.artifactNames.contains(name) && name != ".git" {
                        stack.append((child, depth + 1))
                    }
                } else if let modified = attributes.modificationDate {
                    newest = max(newest ?? modified, modified)
                }
            }
        }
        return newest
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineProjectDetectorTests`
Expected: 9 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/ProjectArtifactDetector.swift Tests/CleanerCoreTests/EngineProjectDetectorTests.swift
git commit -m "feat(engine): add project artifact detector"
```

---

### Task 8：Docker 识别器

> 执行后按代码审查修订（以仓库为准）：先 `docker context inspect` 确认是本机 unix 套接字，之后所有探测与命令都带 `-H <host>`；在用镜像查询失败时不产出镜像项；`rmi` 按 `repo:tag` 引用删除（`<none>` 用 ID）；构建缓存取 Reclaimable 列；镜像大小注明含共用层。

**Files:**
- Create: `Sources/CleanerCore/Engine/DockerDetector.swift`
- Test: `Tests/CleanerCoreTests/EngineDockerDetectorTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineDockerDetectorTests.swift
import XCTest
@testable import CleanerCore

final class EngineDockerDetectorTests: XCTestCase {
    let docker = "/usr/local/bin/docker"
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var outputs: [String: String] = [:]
    var daemonUp = true

    override func setUp() {
        files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(docker, size: 1)
        runner = FakeProcessRunner()
        outputs = [:]
        daemonUp = true
        runner.handler = { [unowned self] path, args in
            guard path == self.docker else { return nil }
            if args.first == "info" {
                return self.daemonUp ? ProcessResult(exitStatus: 0, stdout: "28.0.1\n", stderr: "")
                                     : ProcessResult(exitStatus: 1, stdout: "", stderr: "Cannot connect")
            }
            let key = args.prefix(2).joined(separator: " ")
            return ProcessResult(exitStatus: 0, stdout: self.outputs[key] ?? "", stderr: "")
        }
    }

    func detect() -> [CleanItem] { DockerDetector().detect(EngineFixture.context(files, runner: runner)) }

    func testDaemonNotRunningYieldsNothingAndNeverStartsDocker() {
        daemonUp = false
        XCTAssertEqual(detect(), [])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/open" })
    }

    func testBuildCacheIsSafeCommand() {
        outputs["system df"] = "Images\t19.28GB\nBuild Cache\t5.017GB\n"
        let item = detect().first { $0.id == "docker:build-cache" }
        XCTAssertEqual(item?.tier, .safe)
        XCTAssertEqual(item?.action.command, [docker, "builder", "prune", "-a", "-f"])
        XCTAssertEqual(item?.reclaimableBytes, 5_017_000_000)
        XCTAssertEqual(item?.sizedByDetector, true)
    }

    func testOnlyOldFailedContainersAreListedAndVolumesKept() {
        outputs["ps -a"] = "aaa\nbbb\nccc\n"
        outputs["inspect --format"] = """
        aaaaaaaaaaaaaaaa\t1\t2025-01-01T00:00:00.123456789Z\t/charming_bell
        bbbbbbbbbbbbbbbb\t0\t2025-01-01T00:00:00Z\t/mysql8
        cccccccccccccccc\t137\t2025-01-01T00:00:00Z\t/gateway
        """
        let item = detect().first { $0.id == "docker:failed-containers" }
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertEqual(item?.action.command, [docker, "rm", "aaaaaaaaaaaa"])
        XCTAssertTrue(item?.copy.what.contains("charming_bell") == true)
    }

    func testUnusedImagesExcludeThoseReferencedByContainers() {
        outputs["ps -a"] = "aaa\n"
        outputs["inspect --format"] = "sha256:used\n"
        outputs["images --no-trunc"] = "sha256:used\tpostgres:16\t411MB\nsha256:free\trust:1.90\t4.22GB\nsha256:free\trust:latest\t4.22GB\n"
        let item = detect().first { $0.id == "docker:unused-images" }
        XCTAssertEqual(item?.action.command, [docker, "rmi", "sha256:free"])
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertEqual(item?.reclaimableBytes, 4_220_000_000)
    }

    func testSizeParsing() {
        XCTAssertEqual(DockerDetector.parseSize("902.7MB"), 902_700_000)
        XCTAssertEqual(DockerDetector.parseSize("4.1kB"), 4_100)
        XCTAssertEqual(DockerDetector.parseSize("0B"), 0)
        XCTAssertNil(DockerDetector.parseSize("n/a"))
    }
}
```

说明：`FakeProcessRunner` 按前两个参数返回输出，所以「失败容器」「在用镜像」两次 `inspect --format` 会拿到同一段输出。上面两个测试各自只设置自己需要的那段，互不影响。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineDockerDetectorTests`
Expected: 编译失败，找不到 `DockerDetector`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/DockerDetector.swift
import Foundation

/// 只在 Docker 已运行时识别，绝不替用户启动 Docker。
/// 容器只删容器本身（docker rm 不带 -v），数据卷一律保留。
/// 镜像删除用 docker rmi 不带 -f：被扩展容器等看不见的使用者占用时，由 Docker 自己拒绝。
public struct DockerDetector: Detector {
    public var failedContainerMinAgeDays: Double = 30

    public init() {}

    public func detect(_ context: DetectContext) -> [CleanItem] {
        guard let docker = ExecutableResolver(files: context.files).resolve("docker") else { return [] }
        func run(_ args: [String]) -> String? {
            guard let result = context.runner.run(launchPath: docker, arguments: args), result.exitStatus == 0 else { return nil }
            return result.stdout
        }
        guard run(["info", "--format", "{{.ServerVersion}}"]) != nil else { return [] }
        var items: [CleanItem] = []

        if let df = run(["system", "df", "--format", "{{.Type}}\t{{.Size}}"]) {
            for line in df.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count == 2, fields[0] == "Build Cache", let bytes = Self.parseSize(fields[1]), bytes > 0 {
                    items.append(item(id: "docker:build-cache", tier: .safe, title: "Docker 构建缓存",
                                      command: [docker, "builder", "prune", "-a", "-f"], bytes: bytes,
                                      what: "构建镜像时留下的中间层", impact: "下次构建会慢一些，不影响已有镜像和容器"))
                }
            }
        }

        if let exited = run(["ps", "-a", "-q", "--filter", "status=exited"]) {
            let ids = exited.split(whereSeparator: \.isNewline).map(String.init)
            if !ids.isEmpty,
               let details = run(["inspect", "--format", "{{.Id}}\t{{.State.ExitCode}}\t{{.State.FinishedAt}}\t{{.Name}}"] + ids) {
                let cutoff = context.now.addingTimeInterval(-failedContainerMinAgeDays * 86_400)
                let failed = details.split(whereSeparator: \.isNewline).compactMap { line -> (id: String, name: String)? in
                    let fields = line.split(separator: "\t").map(String.init)
                    guard fields.count == 4, let code = Int(fields[1]), (1...127).contains(code),
                          let finished = Self.parseDate(fields[2]), finished < cutoff else { return nil }
                    let name = fields[3].hasPrefix("/") ? String(fields[3].dropFirst()) : fields[3]
                    return (String(fields[0].prefix(12)), name)
                }
                if !failed.isEmpty {
                    items.append(item(id: "docker:failed-containers", tier: .confirm,
                                      title: "Docker 中启动失败的旧容器（\(failed.count) 个）",
                                      command: [docker, "rm"] + failed.map(\.id), bytes: 0,
                                      what: "30 天前异常退出的容器：" + failed.map(\.name).joined(separator: "、"),
                                      impact: "只删容器本身，数据卷保留"))
                }
            }
        }

        var used = Set<String>()
        if let all = run(["ps", "-a", "-q"]) {
            let ids = all.split(whereSeparator: \.isNewline).map(String.init)
            if !ids.isEmpty, let images = run(["inspect", "--format", "{{.Image}}"] + ids) {
                used = Set(images.split(whereSeparator: \.isNewline).map(String.init))
            }
        }
        if let listing = run(["images", "--no-trunc", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"]) {
            var ids: [String] = []
            var names: [String] = []
            var total: Int64 = 0
            for line in listing.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count == 3, !used.contains(fields[0]), !ids.contains(fields[0]) else { continue }
                ids.append(fields[0])
                names.append(fields[1])
                total += Self.parseSize(fields[2]) ?? 0
            }
            if !ids.isEmpty {
                items.append(item(id: "docker:unused-images", tier: .confirm,
                                  title: "未被任何容器使用的 Docker 镜像（\(ids.count) 个）",
                                  command: [docker, "rmi"] + ids, bytes: total, what: names.joined(separator: "、"),
                                  impact: "需要时可重新拉取或构建；被 Docker Desktop 扩展使用的镜像 Docker 会拒绝删除"))
            }
        }
        return items
    }

    func item(id: String, tier: CleanTier, title: String, command: [String], bytes: Int64,
              what: String, impact: String) -> CleanItem {
        var item = CleanItem(id: id, app: "Docker", category: .dev, tier: tier, title: title, paths: [],
                             action: .command(command), preconditions: .empty,
                             copy: RuleCopy(what: what, impact: impact, regrows: nil))
        item.apparentBytes = bytes
        item.reclaimableBytes = bytes
        item.sizedByDetector = true
        return item
    }

    /// Docker 用十进制单位：1kB = 1000B。
    static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where trimmed.hasSuffix(unit) {
            guard let value = Double(trimmed.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// FinishedAt 带 9 位小数秒，ISO8601DateFormatter 不认，先去掉小数部分。
    static func parseDate(_ text: String) -> Date? {
        var value = text
        if let dot = value.firstIndex(of: ".") { value = String(value[..<dot]) + "Z" }
        return ISO8601DateFormatter().date(from: value)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineDockerDetectorTests`
Expected: 5 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/DockerDetector.swift Tests/CleanerCoreTests/EngineDockerDetectorTests.swift
git commit -m "feat(engine): add read-only Docker detector"
```

---

### Task 9：空间分布识别器

> 执行后按代码审查修订（以仓库为准）：不扫描 `~/Library/Containers` 与 `~/Downloads`（避免触发 macOS 隐私授权弹窗，项目识别器同样跳过 Downloads）；只看与家目录同一块磁盘的目录；排除检查不区分大小写并要求路径不含符号链接；已覆盖路径先去掉嵌套再扣除；无法读取的子目录给出提示。

**Files:**
- Create: `Sources/CleanerCore/Engine/SpaceMapDetector.swift`
- Test: `Tests/CleanerCoreTests/EngineSpaceMapTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineSpaceMapTests.swift
import XCTest
@testable import CleanerCore

final class EngineSpaceMapTests: XCTestCase {
    let home = EngineFixture.home

    func testLargeUnknownDirectoriesAreDisplayOnly() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Application Support/VBLobsterAI/data.bin", size: 3_000)
        files.makeFile(home + "/Library/Application Support/Small/a", size: 10)
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:])
        XCTAssertEqual(items.map(\.title), ["未识别：~/Library/Application Support/VBLobsterAI"])
        XCTAssertEqual(items[0].tier, .displayOnly)
        XCTAssertEqual(items[0].category, .other)
        XCTAssertEqual(items[0].apparentBytes, 3_000)
        XCTAssertEqual(items[0].action.type, .noAction)
    }

    func testCoveredBytesAreSubtractedAndCoveredDirectoriesSkipped() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 5_000)
        files.makeFile(home + "/.codex/logs.sqlite", size: 2_000)
        files.makeFile(home + "/.cache/uv/a", size: 9_000)
        let covered = [home + "/.codex/sessions": Int64(5_000), home + "/.cache/uv": Int64(9_000)]
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: covered)
        XCTAssertEqual(items.map(\.id), ["space:" + home + "/.codex"])
        XCTAssertEqual(items[0].apparentBytes, 2_000)
    }

    func testPrivacyAndForbiddenAreasAreNeverShown() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Documents/big", size: 9_000)
        files.makeFile(home + "/Desktop/big", size: 9_000)
        files.makeFile(home + "/.ssh/big", size: 9_000)
        files.makeFile(home + "/.Trash/big", size: 9_000)
        XCTAssertEqual(SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:]), [])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineSpaceMapTests`
Expected: 编译失败，找不到 `SpaceMapDetector`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/SpaceMapDetector.swift
import Foundation

/// 规则之外的大目录：只展示，帮助用户知道空间去了哪。
/// 部分内容已被其他清理项覆盖的目录，扣除已覆盖部分后仍够大才展示。
public struct SpaceMapDetector {
    public var threshold: Int64

    public init(threshold: Int64 = 1 << 30) { self.threshold = threshold }

    public func detect(_ context: DetectContext, covered: [String: Int64]) -> [CleanItem] {
        let files = context.files
        let home = context.home
        let roots = [home, home + "/Library/Application Support", home + "/Library/Caches",
                     home + "/Library/Containers", home + "/.cache"]
        let excluded = Set(roots + [home + "/Library", home + "/.Trash"])
        let forbidden = RuleValidator.privacyRoots(home: home) + context.safety.treeForbiddenRoots
        var items: [CleanItem] = []
        for root in roots {
            guard let children = try? files.childrenOfDirectory(atPath: root) else { continue }
            for child in children {
                guard !excluded.contains(child),
                      let attributes = files.attributesIfExist(atPath: child), attributes.isDirectory, !attributes.isSymbolicLink,
                      !forbidden.contains(where: { PathSafety.isInside(child, root: $0) }),
                      !covered.keys.contains(where: { PathSafety.isInside(child, root: $0) }) else { continue }
                let coveredInside = covered.filter { PathSafety.isInside($0.key, root: child) }.values.reduce(0, +)
                let remaining = files.apparentSize(of: child) - coveredInside
                guard remaining >= threshold else { continue }
                var item = CleanItem(
                    id: "space:" + child, app: "未识别", category: .other, tier: .displayOnly,
                    title: "未识别：~" + child.dropFirst(home.count), paths: [child], action: .noAction,
                    preconditions: .empty,
                    copy: RuleCopy(what: "规则之外的目录，工具不知道它能否清理",
                                   impact: "只展示占用，可在 Finder 中自行查看", regrows: nil))
                if coveredInside > 0 { item.notes.append("已扣除其中已列出的清理项") }
                item.apparentBytes = remaining
                item.sizedByDetector = true
                items.append(item)
            }
        }
        return items
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineSpaceMapTests`
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/SpaceMapDetector.swift Tests/CleanerCoreTests/EngineSpaceMapTests.swift
git commit -m "feat(engine): add display-only space map detector"
```

---

### Task 10：应用控制与前置条件检查

> 执行后按代码审查修订（以仓库为准）：`RealAppControl` 捕获进程号后用 `kill(pid, 0)` 判断存活，不依赖主 run loop；没有实例接受退出请求时立即返回；锁状态无法确认时为 `.unavailable`（不是「被占用」）；Gradle 只检查两个锁文件。

**Files:**
- Create: `Sources/CleanerCore/Engine/AppControl.swift`
- Create: `Sources/CleanerCore/Engine/RealAppControl.swift`
- Create: `Sources/CleanerCore/Engine/PreconditionChecker.swift`
- Modify: `Tests/CleanerCoreTests/EngineTestSupport.swift`（追加 `FakeAppControl`）
- Test: `Tests/CleanerCoreTests/EnginePreconditionTests.swift`

- [ ] **Step 1: 追加测试辅助与失败测试**

在 `EngineTestSupport.swift` 末尾追加：

```swift
final class FakeAppControl: AppControl {
    var running: Set<String> = []
    var quitSucceeds = true
    private(set) var quitRequests: [String] = []
    private(set) var forceQuits: [String] = []

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }

    func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool {
        quitRequests.append(bundleID)
        if quitSucceeds { running.remove(bundleID) }
        return quitSucceeds
    }

    func forceQuit(bundleID: String) -> Bool {
        forceQuits.append(bundleID)
        running.remove(bundleID)
        return true
    }
}
```

```swift
// Tests/CleanerCoreTests/EnginePreconditionTests.swift
import XCTest
@testable import CleanerCore

final class EnginePreconditionTests: XCTestCase {
    let home = EngineFixture.home

    func item(quit: [QuitApp] = [], locks: [String] = []) -> CleanItem {
        CleanItem(id: "i", app: "a", category: .dev, tier: .safe, title: "t", paths: [], action: .recover,
                  preconditions: RulePreconditions(quitApps: quit, lockfiles: locks),
                  copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    }

    func testRunningAppBlocks() {
        let files = InMemoryFileOperations(home: home)
        let apps = FakeAppControl()
        apps.running = ["com.google.Chrome"]
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        XCTAssertEqual(checker.blockers(for: item(quit: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")])),
                       [.appRunning(name: "Chrome", bundleID: "com.google.Chrome")])
        XCTAssertEqual(checker.blockers(for: item(quit: [QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")])), [])
    }

    func testHeldLockfileBlocksWithOccupier() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        let runner = FakeProcessRunner()
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p34045\0cuv\0n/x\0", stderr: "") : nil
        }
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: runner), home: home)
        XCTAssertEqual(checker.blockers(for: item(locks: ["~/.cache/uv/.lock"])), [.occupied("uv(34045)")])
    }

    func testMissingLockfileIsClear() {
        let files = InMemoryFileOperations(home: home)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        XCTAssertEqual(checker.blockers(for: item(locks: ["~/.cache/uv/.lock"])), [])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EnginePreconditionTests`
Expected: 编译失败，找不到 `AppControl`、`PreconditionChecker`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/AppControl.swift
import Foundation

/// 平台层：应用运行状态与退出。Windows 版替换实现即可。
public protocol AppControl: AnyObject {
    func isRunning(bundleID: String) -> Bool
    /// 正常退出（等同用户按 ⌘Q），等待至多 timeout 秒；返回是否已退出。
    func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool
    /// 强制结束。只能在用户对该应用单独确认后调用。
    func forceQuit(bundleID: String) -> Bool
}
```

```swift
// Sources/CleanerCore/Engine/RealAppControl.swift
#if canImport(AppKit)
import AppKit

public final class RealAppControl: AppControl {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { _ = $0.terminate() }
        return waitUntilGone(bundleID, timeout: timeout)
    }

    public func forceQuit(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { _ = $0.forceTerminate() }
        return waitUntilGone(bundleID, timeout: 5)
    }

    private func waitUntilGone(_ bundleID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(bundleID: bundleID) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !isRunning(bundleID: bundleID)
    }
}
#endif
```

```swift
// Sources/CleanerCore/Engine/PreconditionChecker.swift
import Foundation

/// 当前能否处理：应用是否在运行、锁文件是否被占用。扫描时用于展示，执行前再查一次。
public struct PreconditionChecker {
    public let apps: AppControl
    public let guards: GuardEvaluator
    public let home: String

    public init(apps: AppControl, guards: GuardEvaluator, home: String) {
        self.apps = apps
        self.guards = guards
        self.home = home
    }

    public func blockers(for item: CleanItem) -> [Blocker] {
        var blockers: [Blocker] = []
        for app in item.preconditions.quitApps ?? [] where apps.isRunning(bundleID: app.bundleID) {
            blockers.append(.appRunning(name: app.name, bundleID: app.bundleID))
        }
        for lock in item.preconditions.lockfiles ?? [] {
            let status = guards.status(of: [GuardSpec(type: .lockfile, path: lock)], home: home)
            if status.isBlocked { blockers.append(.occupied(status.occupierDescription ?? lock)) }
        }
        return blockers
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EnginePreconditionTests`
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/AppControl.swift Sources/CleanerCore/Engine/RealAppControl.swift Sources/CleanerCore/Engine/PreconditionChecker.swift Tests/CleanerCoreTests/EngineTestSupport.swift Tests/CleanerCoreTests/EnginePreconditionTests.swift
git commit -m "feat(engine): add app control and precondition checks"
```

---

### Task 11：扫描编排与清理方案

**Files:**
- Create: `Sources/CleanerCore/Engine/EngineScanner.swift`
- Create: `Sources/CleanerCore/Engine/CleanPlan.swift`
- Test: `Tests/CleanerCoreTests/EngineScannerTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineScannerTests.swift
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
              spaceMap: SpaceMapDetector? = nil) -> ScanResult {
        let context = EngineFixture.context(files)
        let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: FakeProcessRunner()), home: home)
        return EngineScanner(context: context, detectors: [RuleDetector(rules: rules)], spaceMap: spaceMap, checker: checker).scan()
    }

    func testItemsAreSizedSortedByTierThenBytes() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Caches/A/x", size: 100)
        files.makeFile(home + "/Library/Caches/B/x", size: 900)
        files.makeFile(home + "/Library/Caches/C/x", size: 500)
        let result = scan(files, rules: [rule("a", tier: .suggested, target: "~/Library/Caches/A"),
                                         rule("b", tier: .safe, target: "~/Library/Caches/B"),
                                         rule("c", tier: .suggested, target: "~/Library/Caches/C")])
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
                                              quit: [QuitApp(name: "Chrome", bundleID: "com.google.Chrome")])], apps: apps)
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
```

说明：`testDefaultSelectionFollowsTierAndIgnoresNonAppBlockers` 中 `appsToQuit` 取已选项中「应用在运行」的阻塞，`QuitApp` 由阻塞里的名字和 bundleID 构造，`mayQuitForUser` 为 nil。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineScannerTests`
Expected: 编译失败，找不到 `EngineScanner`、`ScanResult`、`CleanPlan`、`PlanBuilder`。

- [ ] **Step 3: 实现 `EngineScanner.swift`**

```swift
// Sources/CleanerCore/Engine/EngineScanner.swift
import Foundation

public struct ScanResult: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var disk: DiskSummary?
    public var items: [CleanItem]

    public init(generatedAt: Date, disk: DiskSummary?, items: [CleanItem]) {
        self.generatedAt = generatedAt
        self.disk = disk
        self.items = items
    }
}

/// 只读扫描：识别 → 估算 → 空间分布 → 阻塞检查 → 排序。
public final class EngineScanner {
    private let context: DetectContext
    private let detectors: [Detector]
    private let spaceMap: SpaceMapDetector?
    private let checker: PreconditionChecker

    public init(context: DetectContext, detectors: [Detector], spaceMap: SpaceMapDetector?, checker: PreconditionChecker) {
        self.context = context
        self.detectors = detectors
        self.spaceMap = spaceMap
        self.checker = checker
    }

    public func scan() -> ScanResult {
        var items = detectors.flatMap { $0.detect(context) }
        let sizer = Sizer(files: context.files)
        var covered: [String: Int64] = [:]
        for index in items.indices where !items[index].sizedByDetector {
            let measurement = sizer.measure(items[index].paths)
            items[index].apparentBytes = measurement.apparent
            items[index].reclaimableBytes = items[index].tier == .displayOnly ? 0 : measurement.reclaimable
            if !measurement.unreadable.isEmpty {
                items[index].notes.append("有 \(measurement.unreadable.count) 个子目录无法读取（可能需要完全磁盘访问权限），大小可能偏小")
            }
            covered.merge(measurement.perPath) { max($0, $1) }
        }
        if let spaceMap { items += spaceMap.detect(context, covered: covered) }
        for index in items.indices where items[index].tier != .displayOnly {
            items[index].blockers = checker.blockers(for: items[index])
        }
        let order = CleanTier.allCases
        items.sort { lhs, rhs in
            let l = order.firstIndex(of: lhs.tier)!
            let r = order.firstIndex(of: rhs.tier)!
            if l != r { return l < r }
            let lb = lhs.tier == .displayOnly ? lhs.apparentBytes : lhs.reclaimableBytes
            let rb = rhs.tier == .displayOnly ? rhs.apparentBytes : rhs.reclaimableBytes
            if lb != rb { return lb > rb }
            return lhs.id < rhs.id
        }
        return ScanResult(generatedAt: context.now, disk: context.files.volumeSummary(atPath: context.home), items: items)
    }
}
```

- [ ] **Step 4: 实现 `CleanPlan.swift`**

```swift
// Sources/CleanerCore/Engine/CleanPlan.swift
import Foundation

public struct CleanPlan: Codable, Equatable, Sendable {
    public var items: [CleanItem]
    public var selectedIDs: Set<String>

    public init(items: [CleanItem], selectedIDs: Set<String>) {
        self.items = items
        self.selectedIDs = selectedIDs
    }

    public var selectedItems: [CleanItem] { items.filter { selectedIDs.contains($0.id) } }

    public var estimatedReclaimableBytes: Int64 { selectedItems.reduce(0) { $0 + $1.reclaimableBytes } }

    public func items(in tier: CleanTier) -> [CleanItem] { items.filter { $0.tier == tier } }

    /// 已选项中需要先退出的应用（去重，保持出现顺序）
    public var appsToQuit: [QuitApp] {
        var seen = Set<String>()
        var apps: [QuitApp] = []
        for item in selectedItems {
            for blocker in item.blockers {
                guard case .appRunning(let name, let bundleID) = blocker, seen.insert(bundleID).inserted else { continue }
                let declared = item.preconditions.quitApps?.first { $0.bundleID == bundleID }
                apps.append(declared ?? QuitApp(name: name, bundleID: bundleID))
            }
        }
        return apps
    }

    public struct AppGroup: Equatable, Sendable {
        public var app: String
        public var bytes: Int64
        public var items: [CleanItem]
    }

    /// 「按应用」视图：同一应用的清理项合并，按表观占用从大到小。
    public var byApp: [AppGroup] {
        var groups: [String: [CleanItem]] = [:]
        var order: [String] = []
        for item in items {
            if groups[item.app] == nil { order.append(item.app) }
            groups[item.app, default: []].append(item)
        }
        return order.map { app in
            AppGroup(app: app, bytes: groups[app]!.reduce(0) { $0 + $1.apparentBytes }, items: groups[app]!)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.app < $1.app }
    }
}

public enum PlanBuilder {
    /// 默认勾选：安全档与建议档；被占用或无法处理的不勾选，只因应用在运行的仍勾选（执行时集中退出）。
    public static func build(from scan: ScanResult) -> CleanPlan {
        let selected = scan.items.filter { item in
            item.tier.selectedByDefault && item.blockers.allSatisfy(\.isAppRunning)
        }.map(\.id)
        return CleanPlan(items: scan.items, selectedIDs: Set(selected))
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter EngineScannerTests`
Expected: 6 tests PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/CleanerCore/Engine/EngineScanner.swift Sources/CleanerCore/Engine/CleanPlan.swift Tests/CleanerCoreTests/EngineScannerTests.swift
git commit -m "feat(engine): add scan orchestration and clean plan"
```

---

### Task 12：自管恢复区 RecoveryStore

> 执行后按代码审查修订（以仓库为准）：读取记录时严格校验（批次号与目录名一致、存放路径按固定格式推出、原路径规范且在家目录内、不在数据目录内、必须有身份信息）；清空按目录名进行，损坏的记录不清空并单独列出；还原前先校验目标与各级上级目录；目录用流式 SHA256 内容摘要核对（移动前后各算一次；移动前算不出就不移入、保持原样，移动后不符就移回）；移动后身份不符或记录写入失败时尝试移回；新增 `.cancelled` 状态、`occupiedBytes(of:)`、`orphanBatches()`。

**Files:**
- Create: `Sources/CleanerCore/Engine/RecoveryStore.swift`
- Test: `Tests/CleanerCoreTests/EngineRecoveryStoreTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineRecoveryStoreTests.swift
import XCTest
@testable import CleanerCore

final class EngineRecoveryStoreTests: XCTestCase {
    var home: String!
    var files: RealFileOperations!
    var store: RecoveryStore!

    override func setUpWithError() throws {
        home = TestEnv.makeTempDir("recovery")
        files = RealFileOperations(home: home)
        store = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
    }

    override func tearDown() { TestEnv.remove(home) }

    func testAdmitMovesAndRestoreBringsBackExactBytes() throws {
        try TestEnv.makeTree(root: home + "/proj/node_modules", files: ["a/index.js": "console.log(1)", "b.txt": "b"])
        let writer = try store.begin(batchID: "run-1", now: Date())
        try writer.admit(path: home + "/proj/node_modules", bytes: 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/proj/node_modules"))
        XCTAssertEqual(store.occupiedBytes(), 42)
        XCTAssertEqual(store.list().map(\.id), ["run-1"])

        let result = store.restore(batchID: "run-1")
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.restored, [home + "/proj/node_modules"])
        XCTAssertEqual(try String(contentsOfFile: home + "/proj/node_modules/a/index.js"), "console.log(1)")
        XCTAssertEqual(store.occupiedBytes(), 0)
        XCTAssertEqual(store.list(), [])
    }

    func testRestoreNeverOverwrites() throws {
        try TestEnv.write("old", to: home + "/Library/Caches/X/f")
        let writer = try store.begin(batchID: "run-2", now: Date())
        try writer.admit(path: home + "/Library/Caches/X", bytes: 3)
        try TestEnv.write("new", to: home + "/Library/Caches/X/f")
        let result = store.restore(batchID: "run-2")
        XCTAssertEqual(result.restored, [])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(try String(contentsOfFile: home + "/Library/Caches/X/f"), "new")
        XCTAssertEqual(store.occupiedBytes(), 3)
    }

    func testPurgeRemovesOnlyExpiredBatches() throws {
        try TestEnv.write("a", to: home + "/c/old")
        try TestEnv.write("b", to: home + "/c/new")
        let now = Date()
        try store.begin(batchID: "old", now: now.addingTimeInterval(-8 * 86_400)).admit(path: home + "/c/old", bytes: 1)
        try store.begin(batchID: "new", now: now.addingTimeInterval(-6 * 86_400)).admit(path: home + "/c/new", bytes: 1)
        let result = store.purge(olderThanDays: RecoveryStore.retentionDays, now: now)
        XCTAssertEqual(result.purged, ["old"])
        XCTAssertEqual(store.list().map(\.id), ["new"])
    }

    func testSymlinkIsNeverAdmitted() throws {
        try FileManager.default.createDirectory(atPath: home + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/real")
        let writer = try store.begin(batchID: "run-3", now: Date())
        XCTAssertThrowsError(try writer.admit(path: home + "/link", bytes: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/real"))
    }

    func testInvalidBatchIDRejected() {
        XCTAssertThrowsError(try store.begin(batchID: "../x", now: Date()))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineRecoveryStoreTests`
Expected: 编译失败，找不到 `RecoveryStore`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/RecoveryStore.swift
import Foundation

public struct RecoveryEntry: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, stored, restored }

    public var originalPath: String
    public var storedPath: String
    public var bytes: Int64
    public var state: State
    public var identity: FileAttributes?
}

public struct RecoveryBatch: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var entries: [RecoveryEntry]

    public var storedBytes: Int64 {
        entries.filter { $0.state == .stored }.reduce(0) { $0 + $1.bytes }
    }
}

public enum RecoveryError: Error, CustomStringConvertible, Equatable {
    case invalidBatchID(String)
    case missing(String)
    case symlink(String)
    case crossVolume(String)

    public var description: String {
        switch self {
        case .invalidBatchID(let id): return "恢复批次标识不合法：\(id)"
        case .missing(let path): return "目标不存在：\(path)"
        case .symlink(let path): return "拒绝移动符号链接：\(path)"
        case .crossVolume(let path): return "目标不在家目录所在磁盘上，首版不支持：\(path)"
        }
    }
}

/// 工具自管的恢复区：与被清理目录同卷，移入是一次 rename，不复制。
/// 每个批次一个目录：<directory>/<batchID>/manifest.json 与 items/<序号>/<原名>。
/// 移动前先把 pending 记录落盘，崩溃后仍能从清单定位。
public final class RecoveryStore {
    public static let retentionDays = 7

    public let directory: String
    let files: FileOperations

    public init(directory: String, files: FileOperations) {
        self.directory = directory
        self.files = files
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\0")
    }

    func manifestPath(_ id: String) -> String { directory + "/" + id + "/manifest.json" }

    /// 调用方负责持有 OperationLease（执行器在整个执行期间持有）。
    public func begin(batchID: String, now: Date) throws -> RecoveryBatchWriter {
        guard Self.isValidID(batchID) else { throw RecoveryError.invalidBatchID(batchID) }
        for dir in [directory, directory + "/" + batchID, directory + "/" + batchID + "/items"] {
            try files.createDirectory(atPath: dir, intermediate: true)
        }
        let writer = RecoveryBatchWriter(store: self, batch: RecoveryBatch(id: batchID, createdAt: now, entries: []))
        try write(writer.batch)
        return writer
    }

    func write(_ batch: RecoveryBatch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.writeFile(try encoder.encode(batch), toPath: manifestPath(batch.id))
    }

    func read(_ id: String) -> RecoveryBatch? {
        guard Self.isValidID(id),
              files.attributesIfExist(atPath: manifestPath(id))?.isSymbolicLink == false,
              let data = files.readFile(atPath: manifestPath(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecoveryBatch.self, from: data)
    }

    public func list() -> [RecoveryBatch] {
        guard let children = try? files.childrenOfDirectory(atPath: directory) else { return [] }
        return children.compactMap { read(($0 as NSString).lastPathComponent) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func occupiedBytes() -> Int64 { list().reduce(0) { $0 + $1.storedBytes } }

    public func restore(batchID: String) -> (restored: [String], errors: [String]) {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { return ([], [String(describing: error)]) }
        defer { withExtendedLifetime(lease) {} }
        guard var batch = read(batchID) else { return ([], ["恢复批次不存在或记录损坏：\(batchID)"]) }
        var restored: [String] = []
        var errors: [String] = []
        for index in batch.entries.indices {
            let entry = batch.entries[index]
            let recoverable = entry.state == .stored || (entry.state == .pending && files.fileExists(entry.storedPath))
            guard recoverable else { continue }
            guard let current = files.attributesIfExist(atPath: entry.storedPath) else {
                errors.append("副本不存在：" + entry.originalPath)
                continue
            }
            if let identity = entry.identity, !identity.matches(current) {
                errors.append("副本已变化，未还原：" + entry.originalPath)
                continue
            }
            guard !files.fileExists(entry.originalPath) else {
                errors.append("原位置已有内容，不覆盖：" + entry.originalPath)
                continue
            }
            do {
                try files.createDirectory(atPath: (entry.originalPath as NSString).deletingLastPathComponent, intermediate: true)
                try files.moveItem(fromPath: entry.storedPath, toPath: entry.originalPath)
                batch.entries[index].state = .restored
                try write(batch)
                restored.append(entry.originalPath)
            } catch {
                errors.append("还原失败：\(entry.originalPath)（\(error)）")
            }
        }
        if batch.entries.allSatisfy({ $0.state == .restored }) {
            do { try files.removeItem(atPath: directory + "/" + batchID) } catch { errors.append("恢复记录清理失败：\(error)") }
        }
        return (restored, errors)
    }

    /// 永久删除超过保留期的批次。只能由用户显式触发（或用户开启的到期自动清空）。
    public func purge(olderThanDays days: Int, now: Date) -> (purged: [String], errors: [String]) {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { return ([], [String(describing: error)]) }
        defer { withExtendedLifetime(lease) {} }
        var purged: [String] = []
        var errors: [String] = []
        for batch in list() where now.timeIntervalSince(batch.createdAt) >= Double(days) * 86_400 {
            do {
                try files.removeItem(atPath: directory + "/" + batch.id)
                purged.append(batch.id)
            } catch {
                errors.append("清空失败：\(batch.id)（\(error)）")
            }
        }
        return (purged, errors)
    }
}

public final class RecoveryBatchWriter {
    public private(set) var batch: RecoveryBatch
    private let store: RecoveryStore

    init(store: RecoveryStore, batch: RecoveryBatch) {
        self.store = store
        self.batch = batch
    }

    public func admit(path: String, bytes: Int64) throws {
        let files = store.files
        guard let identity = files.attributesIfExist(atPath: path) else { throw RecoveryError.missing(path) }
        guard !identity.isSymbolicLink else { throw RecoveryError.symlink(path) }
        if let recovery = files.attributesIfExist(atPath: store.directory), recovery.device != identity.device {
            throw RecoveryError.crossVolume(path)
        }
        let index = batch.entries.count
        let slot = store.directory + "/" + batch.id + "/items/" + String(index)
        let storedPath = slot + "/" + (path as NSString).lastPathComponent
        batch.entries.append(RecoveryEntry(originalPath: path, storedPath: storedPath, bytes: bytes, state: .pending, identity: identity))
        try store.write(batch)
        try files.createDirectory(atPath: slot, intermediate: true)
        try files.moveItem(fromPath: path, toPath: storedPath)
        batch.entries[index].state = .stored
        try store.write(batch)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineRecoveryStoreTests`
Expected: 5 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/RecoveryStore.swift Tests/CleanerCoreTests/EngineRecoveryStoreTests.swift
git commit -m "feat(engine): add self-managed recovery store"
```

---

### Task 13：执行器——复核、命令与恢复区

> 执行后按代码审查修订（以仓库为准）：`run.start` 与每项 `run.item.intent` 审计必须写入成功，否则停止后续所有操作；复核时同一项内去重，按年龄清理的路径逐个剔除而非整项跳过，缺天数整项跳过；工具自己的数据目录（`~/.dclean-v2`、`~/.dclean-v3`）整项跳过，并加入 `PathSafety.treeForbiddenRoots`；移入前再做一次 `assertAllowed`；拒绝含 `=` 的可执行路径与含 `:` 的目录；恢复区创建失败只报一次。

**Files:**
- Create: `Sources/CleanerCore/Engine/PlanExecutor.swift`
- Test: `Tests/CleanerCoreTests/EngineExecutorTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/CleanerCoreTests/EngineExecutorTests.swift
import XCTest
@testable import CleanerCore

final class EngineExecutorTests: XCTestCase {
    let home = EngineFixture.home
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var apps: FakeAppControl!
    var recovery: RecoveryStore!

    override func setUp() {
        files = InMemoryFileOperations(home: home)
        files.makeDirectory(EnginePaths.recoveryDirectory(home: home))
        runner = FakeProcessRunner()
        apps = FakeAppControl()
        recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
    }

    func executor() -> PlanExecutor {
        PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner, commandRunner: runner,
                     apps: apps, recovery: recovery, audit: AuditLog(files: files, path: EnginePaths.auditLog(home: home)),
                     now: { EngineFixture.daysBefore(0) }, sleep: { _ in })
    }

    func item(_ id: String, tier: CleanTier = .safe, paths: [String], action: RuleAction = .recover,
              preconditions: RulePreconditions = .empty, regrows: String? = nil) -> CleanItem {
        var i = CleanItem(id: id, app: id, category: .dev, tier: tier, title: id, paths: paths, action: action,
                          preconditions: preconditions, copy: RuleCopy(what: "w", impact: "i", regrows: regrows))
        i.reclaimableBytes = 10
        return i
    }

    func testRecoverMovesIntoRecoveryStore() throws {
        files.makeFile(home + "/.gradle/caches/a", size: 70)
        let report = try executor().run([item("gradle", paths: [home + "/.gradle/caches"], regrows: "会长回来")])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertFalse(files.fileExists(home + "/.gradle/caches"))
        XCTAssertEqual(report.recoveryBytes, 70)
        XCTAssertEqual(recovery.occupiedBytes(), 70)
        XCTAssertEqual(report.regrowNotes, ["gradle：会长回来"])
        XCTAssertNil(report.measuredFreedBytes)
    }

    func testCommandRunsResolvedExecutableWithFixedPATH() throws {
        files.makeFile("/opt/homebrew/bin/npm", size: 1)
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        let report = try executor().run([item("npm", paths: [], action: .command(["npm", "cache", "clean", "--force"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(runner.calls.last?.launchPath, "/usr/bin/env")
        XCTAssertEqual(runner.calls.last?.arguments,
                       ["PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin/npm", "cache", "clean", "--force"])
    }

    func testFailedCommandIsReportedAndNeverFallsBackToDeletion() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(home + "/.cache/uv/a", size: 5)
        runner.handler = { _, _ in ProcessResult(exitStatus: 2, stdout: "", stderr: "warn\nerror: locked\n") }
        let report = try executor().run([item("uv", paths: [home + "/.cache/uv"], action: .command(["uv", "cache", "prune"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.failed("命令失败（退出码 2）：error: locked")])
        XCTAssertTrue(files.fileExists(home + "/.cache/uv/a"))
    }

    func testForbiddenPathAtExecutionSkipsWholeItem() throws {
        files.makeFile(home + "/Library/Caches/ok/a", size: 1)
        files.makeFile(home + "/Documents/work/a", size: 1)
        let report = try executor().run([item("mixed", paths: [home + "/Library/Caches/ok", home + "/Documents/work"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/ok/a"))
        XCTAssertTrue(files.fileExists(home + "/Documents/work/a"))
    }

    func testSymlinkPathSkipsWholeItem() throws {
        files.makeSymlink(at: home + "/Library/Caches/link", target: home + "/Library/Caches/real")
        files.makeFile(home + "/Library/Caches/real/a", size: 1)
        let report = try executor().run([item("link", paths: [home + "/Library/Caches/link"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(files.fileExists(home + "/Library/Caches/link"))
    }

    func testSymlinkedAncestorAtExecutionSkipsItem() throws {
        let tmp = TestEnv.makeTempDir("exec")
        defer { TestEnv.remove(tmp) }
        try TestEnv.write("x", to: tmp + "/Library/Caches/Real/CacheStorage/f")
        try FileManager.default.createSymbolicLink(atPath: tmp + "/Library/Caches/App",
                                                   withDestinationPath: tmp + "/Library/Caches/Real")
        let real = RealFileOperations(home: tmp)
        let exec = PlanExecutor(files: real, safety: PathSafety(home: tmp, files: real), runner: runner, commandRunner: runner,
                                apps: apps, recovery: RecoveryStore(directory: EnginePaths.recoveryDirectory(home: tmp), files: real),
                                audit: AuditLog(files: real, path: EnginePaths.auditLog(home: tmp)), sleep: { _ in })
        let report = try exec.run([item("app", paths: [tmp + "/Library/Caches/App/CacheStorage"])])
        guard case .skipped = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/Library/Caches/Real/CacheStorage/f"))
    }

    func testAlreadyGoneItemIsSkipped() throws {
        let report = try executor().run([item("gone", paths: [home + "/Library/Caches/gone"])])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("目标已不存在")])
    }

    func testDisplayOnlyIsNeverExecuted() throws {
        files.makeFile(home + "/.codex/sessions/a", size: 1)
        let report = try executor().run([item("codex", tier: .displayOnly, paths: [home + "/.codex/sessions"], action: .noAction)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("只展示项不可执行")])
        XCTAssertTrue(files.fileExists(home + "/.codex/sessions/a"))
    }

    func testRecoverOlderThanRechecksAge() throws {
        let dir = home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/now-fresh.ips", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        let action = RuleAction(type: .recoverOlderThan, olderThanDays: 30)
        let report = try executor().run([item("diag", paths: [dir + "/now-fresh.ips"], action: action)])
        guard case .skipped = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(files.fileExists(dir + "/now-fresh.ips"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineExecutorTests`
Expected: 编译失败，找不到 `PlanExecutor`。

- [ ] **Step 3: 实现**

```swift
// Sources/CleanerCore/Engine/PlanExecutor.swift
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

public struct ItemRunResult: Codable, Equatable, Sendable {
    public var itemID: String
    public var title: String
    public var outcome: RunOutcome
    public var estimatedBytes: Int64
    public var recoveredBytes: Int64
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

    /// 按执行前后卷可用空间计算；移入恢复区（同卷 rename）不会增加可用空间。
    public var measuredFreedBytes: Int64? {
        guard let before = freeBefore, let after = freeAfter else { return nil }
        return after - before
    }

    public var recoveryBytes: Int64 { results.reduce(0) { $0 + $1.recoveredBytes } }
}

public enum ExecutorRunError: Error, CustomStringConvertible {
    case busy(String)
    public var description: String {
        switch self { case .busy(let why): return "已有清理任务在运行：\(why)" }
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
    ///   - commandRunner: 长超时，用于清理命令与服务启停
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

    public func run(_ items: [CleanItem], options: ExecutionOptions = ExecutionOptions()) throws -> RunReport {
        let lease: OperationLease?
        do { lease = try OperationLease.acquire(files: files) } catch { throw ExecutorRunError.busy(String(describing: error)) }
        defer { withExtendedLifetime(lease) {} }
        let home = files.homeDirectory()
        let started = now()
        let batchID = Self.batchID(started)
        let freeBefore = files.volumeSummary(atPath: home)?.freeBytes
        audit.append(AuditEvent(op: "run.start", detail: "\(batchID) \(items.count) 项"))
        quitApps(for: items, options: options)
        var writer: RecoveryBatchWriter?
        var results: [ItemRunResult] = []
        var serviceIssues: [String] = []
        var regrowNotes: [String] = []
        for item in items {
            var recovered: Int64 = 0
            audit.append(AuditEvent(op: "run.item.intent", detail: item.id))
            let outcome = execute(item, batchID: batchID, started: started, options: options, writer: &writer,
                                  recovered: &recovered, serviceIssues: &serviceIssues)
            audit.append(AuditEvent(op: "run.item.result", detail: "\(item.id) \(outcome)", bytes: recovered))
            if outcome == .done, let regrows = item.copy.regrows { regrowNotes.append("\(item.title)：\(regrows)") }
            results.append(ItemRunResult(itemID: item.id, title: item.title, outcome: outcome,
                                         estimatedBytes: item.reclaimableBytes, recoveredBytes: recovered))
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

    // MARK: 退出应用（Task 14 补全）

    func quitApps(for items: [CleanItem], options: ExecutionOptions) {}

    // MARK: 单项

    func execute(_ item: CleanItem, batchID: String, started: Date, options: ExecutionOptions,
                 writer: inout RecoveryBatchWriter?, recovered: inout Int64, serviceIssues: inout [String]) -> RunOutcome {
        if item.tier == .displayOnly || item.action.type == .noAction { return .skipped("只展示项不可执行") }
        let paths: [String]
        switch revalidate(item) {
        case .success(let valid): paths = valid
        case .failure(let reason): return .skipped(reason.message)
        }
        let blockers = checker.blockers(for: item)
        if let app = blockers.first(where: \.isAppRunning) { return .skipped(app.message) }
        if !blockers.isEmpty { return .skipped(blockers.map(\.message).joined(separator: "；")) }
        return perform(item, paths: paths, batchID: batchID, started: started, writer: &writer, recovered: &recovered)
    }

    struct SkipReason: Error { let message: String }

    /// 执行前复核：命令项的路径只用于估算，不要求存在；移入恢复区的项逐个核对。
    /// 任何一个路径命中禁区或是符号链接，整项跳过；全部已不存在也跳过。
    func revalidate(_ item: CleanItem) -> Result<[String], SkipReason> {
        guard item.action.type != .command else { return .success([]) }
        var valid: [String] = []
        for path in item.paths {
            guard let attributes = files.attributesIfExist(atPath: path) else { continue }
            if attributes.isSymbolicLink || !EnginePathChecks.isCanonical(path, files: files) {
                return .failure(SkipReason(message: "目标或其上级目录变成了符号链接：" + path))
            }
            if (try? safety.assertAllowed(path)) == nil { return .failure(SkipReason(message: "目标位于受保护位置：" + path)) }
            if item.action.type == .recoverOlderThan, let days = item.action.olderThanDays {
                let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
                guard attributes.isRegularFile, let modified = attributes.modificationDate, modified < cutoff else {
                    return .failure(SkipReason(message: "目标最近被修改过：" + path))
                }
            }
            valid.append(path)
        }
        return valid.isEmpty ? .failure(SkipReason(message: "目标已不存在")) : .success(valid)
    }

    func perform(_ item: CleanItem, paths: [String], batchID: String, started: Date,
                 writer: inout RecoveryBatchWriter?, recovered: inout Int64) -> RunOutcome {
        switch item.action.type {
        case .command:
            guard let argv = item.action.command, !argv.isEmpty else { return .failed("缺少命令") }
            guard let result = runCommand(argv) else { return .failed("找不到命令或命令无法启动、超时：" + argv[0]) }
            guard result.exitStatus == 0 else {
                let last = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                return .failed("命令失败（退出码 \(result.exitStatus)）：" + last)
            }
            return .done
        case .recover, .recoverOlderThan:
            if writer == nil {
                do { writer = try recovery.begin(batchID: batchID, now: started) }
                catch { return .failed("无法创建恢复区：\(error)") }
            }
            var moved = 0
            var errors: [String] = []
            let sizer = Sizer(files: files)
            for path in paths {
                let bytes = sizer.measure([path]).apparent
                do {
                    try writer!.admit(path: path, bytes: bytes)
                    recovered += bytes
                    moved += 1
                } catch {
                    errors.append("\(path)：\(error)")
                }
            }
            if errors.isEmpty { return .done }
            return .failed("\(moved) 个已移入恢复区，\(errors.count) 个失败：" + errors.joined(separator: "；"))
        case .noAction:
            return .skipped("只展示项不可执行")
        }
    }

    /// 用 /usr/bin/env 固定 PATH 运行：npm 等脚本需要同目录的 node，菜单栏应用继承的 PATH 不可靠。
    func runCommand(_ argv: [String]) -> ProcessResult? {
        guard let executable = ExecutableResolver(files: files).resolve(argv[0]) else { return nil }
        let dir = (executable as NSString).deletingLastPathComponent
        let path = "PATH=" + dir + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let args = argv.dropFirst().map { safety.expandTilde($0) }
        return commandRunner.run(launchPath: "/usr/bin/env", arguments: [path, executable] + args)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineExecutorTests`
Expected: 9 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/PlanExecutor.swift Tests/CleanerCoreTests/EngineExecutorTests.swift
git commit -m "feat(engine): add executor with revalidation, commands and recovery"
```

---

### Task 14：执行器——集中退出应用与暂停服务

> 执行后按代码审查修订（以仓库为准）：只为确实会执行的项退出应用；只有当锁的全部占用进程都属于登记服务时才暂停；服务用 `pgrep -u <uid> -f` 找进程，停止在短超时 runner 上执行，启动经 `/bin/sh` 以位置参数、`nohup` 与重定向后台启动；等待与「已恢复」判断都以暂停前的进程号为准；退出应用、强制退出、停止服务的审计必须写入成功；等待以 `now()` 为截止并有迭代上限。

**Files:**
- Modify: `Sources/CleanerCore/Engine/PlanExecutor.swift`（`quitApps`、`execute`，新增服务暂停/恢复）
- Test: `Tests/CleanerCoreTests/EngineExecutorTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

在 `EngineExecutorTests` 类中追加：

```swift
    let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
    let pycharm = QuitApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm", mayQuitForUser: false)

    func testRunningAppWithoutConsentIsSkipped() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        let report = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"],
                                               preconditions: RulePreconditions(quitApps: [chrome]))])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertEqual(apps.quitRequests, [])
    }

    func testConsentedAppIsQuitOnceThenItemRuns() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        files.makeFile(home + "/Library/Caches/ChromeModel/a", size: 1)
        apps.running = [chrome.bundleID]
        let pre = RulePreconditions(quitApps: [chrome])
        let report = try executor().run([item("c1", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre),
                                         item("c2", tier: .confirm, paths: [home + "/Library/Caches/ChromeModel"], preconditions: pre)],
                                        options: ExecutionOptions(quitApps: [chrome.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done])
        XCTAssertEqual(apps.quitRequests, [chrome.bundleID])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func testForceQuitOnlyWhenConsentedAfterTimeout() throws {
        files.makeFile(home + "/Library/Caches/Chrome/a", size: 1)
        apps.running = [chrome.bundleID]
        apps.quitSucceeds = false
        let pre = RulePreconditions(quitApps: [chrome])
        let skipped = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre)],
                                         options: ExecutionOptions(quitApps: [chrome.bundleID]))
        XCTAssertEqual(skipped.results.map(\.outcome), [.skipped("需先退出 Chrome")])
        XCTAssertEqual(apps.forceQuits, [])
        let done = try executor().run([item("c", tier: .suggested, paths: [home + "/Library/Caches/Chrome"], preconditions: pre)],
                                      options: ExecutionOptions(quitApps: [chrome.bundleID], forceQuitApps: [chrome.bundleID]))
        XCTAssertEqual(done.results.map(\.outcome), [.done])
        XCTAssertEqual(apps.forceQuits, [chrome.bundleID])
    }

    func testEditorsAreNeverQuitEvenWithConsent() throws {
        files.makeFile(home + "/Library/Caches/JetBrains/PyCharm/a", size: 1)
        apps.running = [pycharm.bundleID]
        let report = try executor().run([item("jb", tier: .suggested, paths: [home + "/Library/Caches/JetBrains/PyCharm"],
                                               preconditions: RulePreconditions(quitApps: [pycharm]))],
                                        options: ExecutionOptions(quitApps: [pycharm.bundleID], forceQuitApps: [pycharm.bundleID]))
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("需先退出 PyCharm")])
        XCTAssertEqual(apps.quitRequests, [])
        XCTAssertEqual(apps.forceQuits, [])
    }

    func testOccupiedWithoutPausableServiceIsSkipped() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        runner.handler = { path, _ in
            path == GuardEvaluator.lsofPath ? ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "") : nil
        }
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"]))])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped("被占用：uv(9)")])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/env" })
    }

    func testPausableServiceIsStoppedThenResumedAroundTheAction() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var serviceRunning = true
        var log: [String] = []
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: "p9\0cuv\0n/x\0", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case GuardEvaluator.pgrepPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: "9\n", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case "/usr/bin/env":
                let command = args.dropFirst().joined(separator: " ")
                log.append(command)
                if command.hasSuffix("svc stop") { serviceRunning = false }
                if command.hasSuffix("svc start") { serviceRunning = true }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp",
                                      stop: ["svc", "stop"], start: ["svc", "start"])
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"],
                                                                                pausableServices: [service]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(log, ["/opt/homebrew/bin/svc stop", "/opt/homebrew/bin/uv cache prune", "/opt/homebrew/bin/svc start"])
        XCTAssertEqual(report.serviceIssues, [])
    }

    func testServiceThatFailsToComeBackIsReported() throws {
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile("/opt/homebrew/bin/svc", size: 1)
        files.makeFile(home + "/.cache/uv/.lock", size: 0)
        var serviceRunning = true
        runner.handler = { path, args in
            switch path {
            case GuardEvaluator.lsofPath, GuardEvaluator.pgrepPath:
                return serviceRunning ? ProcessResult(exitStatus: 0, stdout: path == GuardEvaluator.lsofPath ? "p9\0cuv\0n/x\0" : "9\n", stderr: "")
                                      : ProcessResult(exitStatus: 1, stdout: "", stderr: "")
            case "/usr/bin/env":
                if args.last == "stop" { serviceRunning = false }
                return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
            default:
                return nil
            }
        }
        let service = PausableService(name: "记忆服务", processPattern: "chroma-mcp", stop: ["svc", "stop"], start: ["svc", "start"])
        let report = try executor().run([item("uv", paths: [], action: .command(["uv", "cache", "prune"]),
                                               preconditions: RulePreconditions(lockfiles: ["~/.cache/uv/.lock"],
                                                                                pausableServices: [service]))])
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertEqual(report.serviceIssues, ["服务 记忆服务 未能自动恢复，请手动运行：svc start"])
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter EngineExecutorTests`
Expected: `testConsentedAppIsQuitOnceThenItemRuns`、`testForceQuitOnlyWhenConsentedAfterTimeout`、`testPausableServiceIsStoppedThenResumedAroundTheAction`、`testServiceThatFailsToComeBackIsReported` FAIL（空的 `quitApps`，占用直接跳过）；其余通过。

- [ ] **Step 3: 实现**

把 `PlanExecutor` 中的空实现 `func quitApps(for items: [CleanItem], options: ExecutionOptions) {}` 替换为：

```swift
    /// 集中退出：每个应用只处理一次。只退出用户同意的；编辑器与 IDE 一律不代为退出；
    /// 正常退出超时后，只有用户对该应用单独同意才强制结束。
    func quitApps(for items: [CleanItem], options: ExecutionOptions) {
        var seen = Set<String>()
        for app in items.flatMap({ $0.preconditions.quitApps ?? [] }) where seen.insert(app.bundleID).inserted {
            guard apps.isRunning(bundleID: app.bundleID), app.canQuitForUser,
                  options.quitApps.contains(app.bundleID) else { continue }
            audit.append(AuditEvent(op: "run.app.quit", detail: app.bundleID))
            if !apps.requestQuit(bundleID: app.bundleID, timeout: options.quitTimeout),
               options.forceQuitApps.contains(app.bundleID) {
                audit.append(AuditEvent(op: "run.app.force-quit", detail: app.bundleID))
                _ = apps.forceQuit(bundleID: app.bundleID)
            }
        }
    }
```

把 `execute` 中这两行：

```swift
        if !blockers.isEmpty { return .skipped(blockers.map(\.message).joined(separator: "；")) }
        return perform(item, paths: paths, batchID: batchID, started: started, writer: &writer, recovered: &recovered)
```

替换为：

```swift
        guard !blockers.isEmpty else {
            return perform(item, paths: paths, batchID: batchID, started: started, writer: &writer, recovered: &recovered)
        }
        let services = item.preconditions.pausableServices ?? []
        guard !services.isEmpty else { return .skipped(blockers.map(\.message).joined(separator: "；")) }
        // 暂停 → 复查 → 执行 → 恢复，在一次执行内连续完成，避免中途被其他程序重新拉起
        let paused = pause(services, timeout: options.serviceWaitTimeout)
        let recheck = checker.blockers(for: item)
        let outcome: RunOutcome
        if recheck.isEmpty {
            outcome = perform(item, paths: paths, batchID: batchID, started: started, writer: &writer, recovered: &recovered)
        } else {
            outcome = .skipped("暂停服务后仍被占用：" + recheck.map(\.message).joined(separator: "；"))
        }
        resume(paused, timeout: options.serviceWaitTimeout, issues: &serviceIssues)
        return outcome
```

在 `runCommand` 之后追加：

```swift
    // MARK: 服务暂停与恢复

    func isServiceRunning(_ service: PausableService) -> Bool {
        guard let result = runner.run(launchPath: GuardEvaluator.pgrepPath, arguments: ["-f", service.processPattern]) else {
            return false
        }
        return result.exitStatus == 0 && !result.stdout.isEmpty
    }

    func pause(_ services: [PausableService], timeout: TimeInterval) -> [PausableService] {
        var paused: [PausableService] = []
        for service in services where isServiceRunning(service) {
            audit.append(AuditEvent(op: "run.service.stop", detail: service.name))
            _ = runCommand(service.stop)
            paused.append(service)
            waitUntil(timeout) { !self.isServiceRunning(service) }
        }
        return paused
    }

    func resume(_ services: [PausableService], timeout: TimeInterval, issues: inout [String]) {
        for service in services {
            audit.append(AuditEvent(op: "run.service.start", detail: service.name))
            _ = runCommand(service.start)
            if !waitUntil(timeout, { self.isServiceRunning(service) }) {
                issues.append("服务 \(service.name) 未能自动恢复，请手动运行：" + service.start.joined(separator: " "))
            }
        }
    }

    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        var waited: TimeInterval = 0
        while true {
            if condition() { return true }
            if waited >= timeout { return false }
            sleep(0.5)
            waited += 0.5
        }
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter EngineExecutorTests`
Expected: 16 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanerCore/Engine/PlanExecutor.swift Tests/CleanerCoreTests/EngineExecutorTests.swift
git commit -m "feat(engine): quit consented apps and pause registered services"
```

---

### Task 15：命令行换成新引擎

**Files:**
- Modify: `Sources/dclean/main.swift`（整体替换）

旧命令（`sessions`、`workspaces`、`plugins` 等）随旧引擎一起在子项目 2 删除，本任务起命令行只暴露新引擎。旧菜单栏应用不依赖命令行，不受影响。

- [ ] **Step 1: 整体替换 `main.swift`**

```swift
// Sources/dclean/main.swift
import Foundation
import CleanerCore

let usage = """
清理大师命令行（默认只读；clean 加 --apply 才执行）

用法:
  dclean scan [--json] [--no-projects] [--no-docker] [--no-space-map]
                              只读扫描，按档位列出清理项
  dclean clean [--tiers safe,suggested] [--only id1,id2] [--quit-apps] [--apply] [--json]
                              预览或执行清理方案；--quit-apps 允许工具正常退出应用（不会强制退出，也不会退出 IDE）
  dclean recovery [list | restore <批次ID> | purge [--days 7]]
                              恢复区：查看、还原、永久清空超过保留期的批次
  dclean rules                查看已加载的规则与规则问题
"""

let arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let files = RealFileOperations()
let home = files.homeDirectory()
let safety = PathSafety(home: home, files: files)
let probeRunner = RealProcessRunner(timeout: 30)
let commandRunner = RealProcessRunner(timeout: 900, outputLimit: 8 << 20)
let apps = RealAppControl()
let checker = PreconditionChecker(apps: apps, guards: GuardEvaluator(files: files, runner: probeRunner), home: home)
let recovery = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
let audit = AuditLog(files: files, path: EnginePaths.auditLog(home: home))

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

func scan() -> ScanResult {
    let loaded = loadRules()
    for problem in loaded.problems { FileHandle.standardError.write(Data(("规则问题：" + problem + "\n").utf8)) }
    var detectors: [Detector] = [RuleDetector(rules: loaded.rules)]
    if !flag("--no-projects") { detectors.append(ProjectArtifactDetector()) }
    if !flag("--no-docker") { detectors.append(DockerDetector()) }
    let context = DetectContext(files: files, safety: safety, runner: probeRunner, now: Date())
    return EngineScanner(context: context, detectors: detectors,
                         spaceMap: flag("--no-space-map") ? nil : SpaceMapDetector(), checker: checker).scan()
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
                : "预计可释放 \(human(item.reclaimableBytes))（表观 \(human(item.apparentBytes))）"
            print("\(mark)\(item.title)  \(size)  [\(item.id)]")
            for blocker in item.blockers { print("     ⚠ " + blocker.message) }
            for note in item.notes { print("     · " + note) }
        }
    }
    print("\n已选预计可释放：\(human(plan.estimatedReclaimableBytes))")
    let quit = plan.appsToQuit
    if !quit.isEmpty { print("需要先退出：" + quit.map(\.name).joined(separator: "、")) }
}

func printReport(_ report: RunReport) {
    for result in report.results {
        switch result.outcome {
        case .done: print("✓ \(result.title)")
        case .skipped(let why): print("– \(result.title)：跳过，\(why)")
        case .failed(let why): print("✗ \(result.title)：\(why)")
        }
    }
    if let freed = report.measuredFreedBytes { print("\n实际释放：\(human(max(freed, 0)))（按执行前后可用空间计算）") }
    if report.recoveryBytes > 0 {
        print("移入恢复区：\(human(report.recoveryBytes))，清空恢复区后才会释放（批次 \(report.batchID)）")
    }
    for issue in report.serviceIssues { print("⚠ " + issue) }
    for note in report.regrowNotes { print("↻ " + note) }
}

switch arguments.first {
case "scan":
    let result = scan()
    if flag("--json") { printJSON(result) } else { printPlan(PlanBuilder.build(from: result), disk: result.disk) }

case "clean":
    let result = scan()
    var plan = PlanBuilder.build(from: result)
    let actionable = Set(plan.items.filter { $0.tier != .displayOnly }.map(\.id))
    if let tiers = value("--tiers") {
        let wanted = Set(tiers.split(separator: ",").compactMap { CleanTier(rawValue: String($0)) })
        plan.selectedIDs = Set(plan.items.filter { wanted.contains($0.tier) }.map(\.id)).intersection(actionable)
    }
    if let only = value("--only") {
        plan.selectedIDs = Set(only.split(separator: ",").map(String.init)).intersection(actionable)
    }
    guard flag("--apply") else {
        printPlan(plan, disk: result.disk)
        print("\n这是预览，没有做任何改动。加 --apply 执行；需要工具帮忙正常退出应用时加 --quit-apps。")
        exit(0)
    }
    let quit = flag("--quit-apps") ? Set(plan.appsToQuit.filter(\.canQuitForUser).map(\.bundleID)) : []
    let executor = PlanExecutor(files: files, safety: safety, runner: probeRunner, commandRunner: commandRunner,
                                apps: apps, recovery: recovery, audit: audit)
    do {
        let report = try executor.run(plan.selectedItems, options: ExecutionOptions(quitApps: quit))
        if flag("--json") { printJSON(report) } else { printReport(report) }
    } catch {
        fail(String(describing: error))
    }

case "recovery":
    switch arguments.dropFirst().first ?? "list" {
    case "list":
        for batch in recovery.list() {
            print("\(batch.id)  \(batch.createdAt)  \(human(recovery.occupiedBytes(of: batch)))  \(batch.entries.count) 项")
        }
        print("恢复区合计：\(human(recovery.occupiedBytes()))，保留 \(RecoveryStore.retentionDays) 天")
        for orphan in recovery.orphanBatches() { print("⚠ 恢复记录损坏，未计入也不会自动清空：" + orphan) }
    case "restore":
        guard arguments.count >= 3 else { fail(usage) }
        let result = recovery.restore(batchID: arguments[2])
        result.restored.forEach { print("✓ 已还原 " + $0) }
        result.errors.forEach { print("✗ " + $0) }
        if !result.errors.isEmpty { exit(1) }
    case "purge":
        let days = value("--days").flatMap(Int.init) ?? RecoveryStore.retentionDays
        let result = recovery.purge(olderThanDays: days, now: Date())
        result.purged.forEach { print("已永久清空批次 " + $0) }
        result.errors.forEach { print("✗ " + $0) }
        if !result.errors.isEmpty { exit(1) }
    default:
        fail(usage)
    }

case "rules":
    let loaded = loadRules()
    for rule in loaded.rules { print("\(rule.tier.title)\t\(rule.id)\t\(rule.name)") }
    for problem in loaded.problems { print("问题：" + problem) }

default:
    print(usage)
}
```

- [ ] **Step 2: 构建**

Run: `swift build`
Expected: `Build complete!`，无错误。

- [ ] **Step 3: 全量测试**

Run: `swift test`
Expected: 旧测试与全部 Engine 测试通过，0 failures。

- [ ] **Step 4: 规则自检（只读）**

Run: `swift run dclean rules`
Expected: 列出 29 条规则，没有「问题：」行。

- [ ] **Step 5: Commit**

```bash
git add Sources/dclean/main.swift
git commit -m "feat(cli): switch dclean to the new engine"
```

---

### Task 16：真机只读验收

**Files:**
- Create: `docs/v2/22-引擎重构真机只读验收.md`

本任务**不执行任何清理**。只运行 `scan` 和不带 `--apply` 的 `clean`。

- [ ] **Step 1: 只读扫描**

Run: `swift run -c release dclean scan > /tmp/dclean-scan.txt; swift run -c release dclean scan --json > /tmp/dclean-scan.json`
Expected: 两条命令都退出码 0；文本输出按「安全 / 建议 / 需要确认 / 只展示」分组。

- [ ] **Step 2: 预览方案**

Run: `swift run -c release dclean clean`
Expected: 输出末尾为「这是预览，没有做任何改动」；`~/.dclean-v3/recovery` 不存在或为空（`ls ~/.dclean-v3/recovery` 无批次）。

- [ ] **Step 3: 与 2026-09-26 手动清理结果对照**

逐项核对并记录到验收文档：
- 包管理器缓存各项是否都识别到（npm、pip、uv、bun、pnpm、Homebrew、Poetry）；uv 的「预计可释放」是否明显小于表观大小
- 项目产物：建议档项目数与合计，是否没有出现 AI 工具隐藏目录、`~/.nvm`、`.app` 内部、`~/Documents` 下的项目
- Chrome、Cursor、JetBrains 等条目在应用运行时是否显示「需先退出」
- uv 在 claude-mem 运行时是否显示「被占用」
- Docker：未运行时应没有 Docker 可清理项，只有「Docker 虚拟磁盘」只展示项
- 空间分布：列出的「未识别」目录
- 扫描耗时（`time swift run -c release dclean scan --no-space-map` 与完整扫描各一次）

- [ ] **Step 4: 写验收文档并提交**

文档结构与 `docs/v2/20-Codex会话首条元数据只读盘点.md` 一致：实现、本机只读结果（实测数字）、测试与构建（`swift test` 的通过/跳过/失败数）、与预期不符之处、未完成。

```bash
git add docs/v2/22-引擎重构真机只读验收.md
git commit -m "docs(v2): engine rebuild real-machine read-only acceptance"
```

---

## 不在本子项目内

以下属于后续子项目，本计划不实现：
- 菜单栏与主窗口界面、结果页的「外部变化」标注（子项目 2；引擎已在 `RunReport` 中提供执行前后可用空间与逐项估算，界面据此判断）
- 每日扫描、提醒条件、安全档自动清理、恢复区到期自动清空（子项目 3）
- 办公软件、国产 AI 工具、Safari 规则，自定义规则的界面入口，匿名反馈（子项目 4）
- Yarn（需区分 1.x 与 Berry，并固定命令工作目录）、iOS 不可用模拟器（需按设备估算大小）两条规则，Task 3 审查后移出（子项目 4）
- Sizer 并行遍历与取消（沿用 `apparentSize` 的按层并行 + `OperationCancellation`）：Task 16 实测扫描耗时后决定是否在子项目 2 前补上；界面扫描必须可取消
- 项目产物：用户在 `~/code` 这类上层目录 `git init` 形成「伞仓库」时，按最近的工程标记文件（package.json 等）拆分子项目并各自计算闲置时间（Task 7 审查遗留）
- reflog 只读文件尾部（`tailBytes`）；worktree / 子模块的 `.git` 为文件时跟随 `gitdir:` 读取（目前保守地降为需要确认）
- 命令项部分失败（如 `docker rmi` 多个参数中个别被拒）时，结果页按执行前后实测空间说明实际效果（子项目 2）
- 空间分布：遍历时跳过已覆盖的子树（避免重复遍历项目目录）、支持取消；Docker 等自带大小的识别器也要把自己的数据目录计入「已覆盖」，避免 `~/.orbstack` 这类目录重复计算（Task 9 审查遗留）
- 自定义规则上线时：扫描阶段去掉已被前面清理项覆盖的路径，避免同一路径计入两项、执行两次（Task 11 审查遗留）
- 「预计可释放」另给一个不含「需用户自己退出的应用」项的数字，界面与命令行都标注（Task 11 审查遗留）
- 空间分布：源码目录（如存放各项目的 `~/Projects`）不应标为「未识别」，改为「项目文件夹」或只展示其中未列出的部分（Task 16 验收发现）
- 子项目 2 必须处理（整体审查）：
  - 扫描、执行、还原、退出应用都是同步阻塞调用，界面必须放在后台线程，并补充进度回调与取消（项目识别器遍历、Docker 探测、执行逐项进度）
  - 执行器的退出应用流程要改成可交互：正常退出超时后逐个应用让用户选择强制退出或跳过（spec §3.3 第 2 步），而不是在 `run()` 前一次性给出 `forceQuitApps`
  - 只执行本进程刚扫描得到的清理项；如需持久化每日扫描结果，执行前按 id 重新扫描或由执行器按规则重建命令参数，绝不执行解码得到的 `CleanItem`
  - `CleanPlan.appsToQuit` 是扫描时的快照，展示退出应用页面前要重新检查
  - 跳过/失败原因目前是中文字符串，界面分组需要结构化原因
  - 结果页分开展示实际释放（`measuredFreedBytes`）与恢复区占用（`recoveryBytes`）；`pnpm store prune`、`uv cache prune` 的预估是整个目录，会偏大
  - 恢复区页面展示 `orphanBatches()`
- 项目产物：已提交到 git 的 `dist`/`build`（如 GitHub Action 仓库）不应进入建议档，需要「是否被 git 跟踪」检查（整体审查 M-1）
- conda 规则、Docker 数据卷的只展示项（spec §5、§4.3，整体审查 M-9）
- 大小写不敏感逻辑的测试（内存文件系统区分大小写，目前靠真实文件系统测试覆盖不全）；清理项 id 含完整路径，反馈文本需脱敏（整体审查 M-7、M-8）
- 多个清理项共用同一服务时合并为一次暂停/恢复，避免反复重启（Task 14 审查遗留）
- Gradle：把 `gradle --stop` 登记为可暂停服务，并加 `GradleDaemon` 进程检查（锁文件为按需持有，可能漏检），避免空闲守护进程长期占用导致缓存项总是被跳过（子项目 4）
- 删除旧引擎代码（子项目 2 切换界面后进行）
