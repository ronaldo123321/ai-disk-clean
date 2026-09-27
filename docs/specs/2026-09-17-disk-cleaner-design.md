# 磁盘清理大师（DiskCleaner）设计文档

日期：2026-09-17
状态：已确认，实施中（2026-09-17 修订两处：禁区按匹配语义分两类；黄色与 command/truncate 互斥）

## 1. 问题

日常大量使用 AI 工具产生的缓存、会话记录、模型权重、容器镜像持续堆积，占满磁盘。现状实测（460G 盘，已用 381G，可用 34G，92%）：

| 路径 | 大小 |
|---|---|
| `~/.cache/uv` | 21 G |
| Docker.raw | 21 G |
| Chrome Service Worker | 18 G |
| `~/Library/Application Support/Claude`（含 vm_bundles） | 12 G |
| `~/.codex`（sessions 4.6G / skills 2.1G / sqlite 日志 2.5G） | 10 G |
| `~/Library/Caches/JetBrains` | 6.6 G |
| `~/Library/Caches/ms-playwright` | 4.0 G |
| 某 AI 工具的隐藏安装目录 | 3.9 G |
| `~/.claude/plugins` | 3.3 G |
| `~/Library/Caches/pip` | 3.1 G |

已有的一次性脚本解决了单次问题，但无法常态化：没有定时感知、没有统一的安全模型、没有回滚能力。

## 2. 目标与非目标

**目标**
- 菜单栏常驻，不点开就能看出磁盘健康状况
- 每天自动扫描，人工确认后才清理
- 覆盖 AI 工具产物与开发缓存
- 安全性优先：白名单制、可回滚、拒绝绕过守卫

**非目标（明确不做）**
- 不做全盘通用清理（大文件搜索、重复文件、应用残留）——规则不可穷举，误删风险高
- 不做自动清理。任何删除都由用户点击触发
- 不提供任何 `--force` 绕过占用检测的入口
- 不删除 Chrome 数据（仅在红色组只读展示占用）

## 3. 架构

Swift package，三个 target：

```
DiskCleaner/
├─ Sources/CleanerCore/     引擎（库）：规则加载、扫描、风险评级、计划、执行、隔离区
├─ Sources/dclean/          CLI：scan / plan / apply / restore / purge
├─ Sources/DiskCleanerApp/  SwiftUI MenuBarExtra 壳
└─ Tests/CleanerCoreTests/  引擎单测
```

**数据流**（GUI 与 CLI 共用同一条）：

```
rules.json ─┐
            ├→ Scanner ──→ Report(JSON) ──→ 菜单栏 UI 渲染
文件系统  ──┘      ↑                   └──→ 终端表格
                   │
         launchd 每天定时跑 `dclean scan --write-report`
                   │
用户点「清理」 → Planner(生成计划) → 用户确认 → Executor → 审计日志 + 隔离区
```

**GUI 不含任何删除逻辑。** 它渲染 Report、收集勾选、调用 `CleanerCore.execute(plan)`。由此：
- 引擎可被单测完整覆盖
- 无 GUI 时可用 `dclean` 单独审计（延续现有脚本 dry-run 默认、`--apply` 才执行的习惯）
- 定时任务与手动扫描共用入口，不会出现两边结果不一致

**为什么扫描不放在 GUI 进程内**：目录遍历是秒级耗时操作，必须后台进程执行，UI 只读结果文件。

**技术栈选型理由**：纯 Swift、零运行时依赖。Python 环境本身是清理对象之一，用 miniconda 的 Python 编写会删 Python 缓存的工具存在自举风险，且 `/opt/miniconda3` 路径变动会导致工具失效。

## 4. 规则模型

规则是数据不是代码，存于 `~/.dclean/rules.json`：

```json
{
  "id": "uv-cache",
  "name": "uv 包缓存",
  "risk": "green",
  "roots": ["~/.cache/uv"],
  "strategy": { "type": "command", "cmd": ["uv", "cache", "prune"] },
  "guards": [{ "type": "lockfile", "path": "~/.cache/uv/.lock" }],
  "explain": "删后下次装包需重新下载。APFS clonefile 写时复制，不影响已有 venv，但净回收会明显小于表观大小。"
}
```

### strategy 四种类型

| 类型 | 行为 |
|---|---|
| `command` | 委托给工具自身的清理命令（`uv cache prune`、`brew cleanup`、`docker system prune`）。**优先使用**——工具比我们更清楚什么能删 |
| `delete-dir` | 整目录删除 |
| `glob-age` | 匹配 glob 且 mtime 早于 N 天的条目 |
| `truncate` | 清空文件内容（用于被进程占用的日志） |

`command` 失败时标记为失败，**不 fallback 到自行 rm**。

**策略与风险等级的兼容性**（修正记录：Docker 悬空镜像最初列为「黄色 + `command`」，但委托命令无法先把目标移入隔离区、也就无法还原，是矛盾组合）：`command` 与 `truncate` 只能配绿色；黄色只能配 `delete-dir` / `glob-age`。Planner 对违规组合直接报配置错误。Docker 悬空镜像已降级为绿色，`explain` 写明「不可还原，需重新拉取」。

### 规则文件的来源与更新

内置默认规则集随二进制发布。首次运行时写入 `~/.dclean/rules.json`；此后版本升级**不覆盖**该文件，新增的默认规则以「有新规则可用」提示用户手动合并。用户可自行编辑该文件，但第 5 节的硬编码禁区对用户编辑的规则同样生效——这正是禁区必须在代码中而非配置中的原因。

### guards 两种类型

| 类型 | 检查 |
|---|---|
| `lockfile` | `lsof` 查锁文件持有者 |
| `process` | 查指定进程是否运行中 |

guard 不通过 → 该项在 UI 中禁用勾选，并显示占用者 PID 与进程名。无绕过入口。

## 5. 安全机制（七层）

1. **白名单制**。只处理 `rules.json` 显式列出的路径模式。不做「发现大文件即建议删除」这类启发式判断。
2. **根目录围栏**。候选路径经 `realpath` 解析后必须仍落在该规则声明的 `roots` 内，阻断 symlink 逃逸与 `../` 穿越。
3. **硬编码禁区**（不可被配置覆盖），按匹配语义分两类：
   - **精确匹配**——路径本身就是禁区，其后代不受影响：`/`、`/Users`、`$HOME` 本身。（修正记录：最初按「前缀匹配」处理，`/Users` 会把 `/Users/me/.cache/uv` 也判成禁区，整个工具直接瘫痪；必须精确匹配。）
   - **整棵树禁止**——该目录及其所有后代都是禁区：`/System`、`~/Documents`、`~/Desktop`、`~/Pictures`、`~/.ssh`、`~/.gnupg`、`~/Library/Keychains`，以及任何 `.git` 目录。
   命中则**整个计划 abort**，而非静默跳过该条。
4. **不跟随符号链接**。删除 link 本身，不删其指向的目标。
5. **路径断言**。执行前断言路径非空且深度 ≥ 3 层，杜绝变量为空拼接出根路径删除。
6. **占用守卫**。见上节 guards。设计动机：已知 claude-mem 的 `chroma-mcp` 服务会持续持有 `~/.cache/uv/.lock`，此时 `uv cache prune` 必定失败。
7. **两段式执行 + 重校验**。`plan` 生成不可变计划对象（逐条路径 + 大小 + 风险 + 动作），UI 展示完整清单，确认后 `apply` 时**逐条重新校验**——计划生成到执行之间目标变化则跳过并在结果中报告（防 TOCTOU）。

## 6. 风险分级

| 级别 | 处理方式 | 首版覆盖范围 |
|---|---|---|
| 🟢 绿 · 直接删除 | 空间立即回收 | uv 缓存、pip 缓存、ms-playwright、Homebrew 缓存、puppeteer/camoufox、各家日志与崩溃转储、Docker 悬空镜像（command 委托，不可还原，需重新拉取） |
| 🟡 黄 · 隔离 7 天 | 可一键还原 | `~/.codex/sessions`、codex sqlite 日志、JetBrains 旧版本缓存、`~/.claude/plugins` 旧版本、HuggingFace 权重 |
| 🔴 红 · 只读展示 | 无清理按钮 | Claude vm_bundles、Docker.raw、Chrome Service Worker |

红色项在 UI 中显示占用量，附一段「为何不自动清理 + 手动处理方式」说明。例如 Docker.raw 的正确做法是在 Docker Desktop 中调低磁盘镜像上限，而非删除文件。

**关于隔离区与空间释放**：同一 APFS 卷内移动文件不释放空间。因此绿色项直接删除以立即回收，黄色项进隔离区换取可回滚性。隔离区自身占用在 UI 中单列一行。

## 7. 隔离区与审计

- 位置：`~/.dclean/quarantine/<时间戳>/`
- 每批次附 `manifest.json` 记录原路径映射
- `dclean restore <批次>` 按 manifest 还原
- 超过 7 天的批次由每日定时任务自动 purge
- 所有操作追加写入 `~/.dclean/audit.log`，每次操作一行 JSON

## 8. 菜单栏 UI

图标为环形占用指示器，随可用空间比例变色：>20% 灰、10–20% 黄、<10% 红。

```
┌────────────────────────────────────────────┐
│  磁盘  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░  381G / 460G   │
│  可用 34G · 上次扫描 今天 13:07            │
├────────────────────────────────────────────┤
│  可回收合计  38.4 G          [ 重新扫描 ]  │
├────────────────────────────────────────────┤
│ ▼ 🟢 可直接清理                    29.1 G  │
│   ☑ pip 缓存                        3.1 G  │
│   ☐ uv 包缓存        ⚠ 被 chroma-mcp 占用 │
│   ☑ Playwright 浏览器               4.0 G  │
│   ☑ Homebrew 缓存                   1.1 G  │
│ ▶ 🟡 隔离 7 天后删除                9.3 G  │
│ ▶ 🔴 需手动处理（只看）            51.0 G  │
├────────────────────────────────────────────┤
│  隔离区 0 B · 空            [还原] [清空]  │
├────────────────────────────────────────────┤
│         [   清理选中的 8.2 G    ]          │
└────────────────────────────────────────────┘
```

点击「清理选中」弹出确认单，逐条列出完整路径、大小、以及该条是「立即删除」还是「移入隔离区」，两个按钮：取消 / 确认。

不采用输入框二次确认等摩擦设计——真正的保护在引擎的七层机制中，UI 层堆砌摩擦只会训练出闭眼点确认的习惯。

## 9. 定时任务

单个 launchd agent：`~/Library/LaunchAgents/com.example.dclean.scan.plist`

- 每天 13:07 执行 `dclean scan --write-report`（避开整点；`ProcessType: Background` 交由系统调度至空闲时段）
- 输出 `~/.dclean/report.json`
- App 通过 `DispatchSource` 监听该文件变动刷新图标
- **过期隔离批次的 purge 并入同一任务**（扫描前先 purge），不单开 agent

扫描仅遍历规则声明的 roots，非全盘遍历，耗时为秒级。

## 10. 测试策略

`CleanerCore` 将文件操作抽象为 `FileOperations` protocol；单测使用内存实现与临时目录构造的假文件树。采用 TDD：先写下表用例，红灯后再实现引擎。

| 测试 | 断言 | 对应防护层 |
|---|---|---|
| 围栏 | root 内 symlink 指向 root 外 → 只删 link，目标完好 | 2, 4 |
| 禁区 | 规则 roots 配为 `~/Documents` → 整个 plan 抛错，不执行任何一条；`/Users`、`$HOME` 精确命中抛错；`/Users/me/.cache/uv` 不命中 | 3 |
| 路径断言 | 规则产生空路径或两层浅路径 → 抛错 | 5 |
| guard | 注入「锁被占用」→ 该项状态为 blocked，执行时跳过 | 6 |
| TOCTOU | plan 生成后删除目标 → apply 报 skipped，不报错、不误删其他条目 | 7 |
| 隔离往返 | 文件 → quarantine → restore，路径与内容逐字节一致 | §7 |
| purge | 8 天前的批次被清除，6 天前的保留 | §7 |
| 命令委托 | `uv cache prune` 返回非零 → 标记失败，不 fallback 到自行 rm | §4 |

外加冒烟测试：对真实 home 仅执行 `scan`（纯只读），断言不崩溃且 `report.json` 可解析。

## 11. 交付顺序

1. `CleanerCore` 引擎 + 测试表全绿
2. `dclean` CLI（先可用、可审计）
3. 首版 `rules.json`（基于本文档 §6 的实测清单）
4. `DiskCleanerApp` 菜单栏壳
5. launchd plist + 安装脚本
