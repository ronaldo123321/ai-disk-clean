# 清理大师（DiskCleaner）

给重度使用 AI 编程工具的 Mac 用户准备的磁盘清理工具。

Vibe coding 会留下大量中间产物：各语言的包缓存、闲置项目里的 `node_modules` / `.venv` / `target`、IDE 与 AI 工具的缓存、Docker 镜像……清理大师把它们找出来，按风险分档，**默认只清理确定安全的部分，能还原的先放进恢复区保留 7 天**。

- 菜单栏常驻，点一下看磁盘占用和推荐方案
- 主窗口按「档位」或「应用」查看每一项：是什么、删了有什么影响、会不会自动长回来
- 清理前弹出确认单，写明哪些可还原、哪些不可还原、需要先退出哪些应用
- 所有操作写入审计日志
- 附带命令行工具 `dclean`，默认只读

> 目前只支持 macOS 13 及以上。

## 安装

需要 Xcode 命令行工具（Swift 5.10 或更新）：

```bash
xcode-select --install
```

克隆并构建：

```bash
git clone https://github.com/ronaldo123321/ai-disk-clean.git
cd ai-disk-clean
Scripts/make-v2-app.sh
```

脚本会用 release 模式构建，并安装到 `~/Applications/清理大师V2.app`（本地临时签名）。之后在「应用程序」里打开，或：

```bash
open ~/Applications/清理大师V2.app
```

更新时拉取新代码后重新执行脚本即可，**记得先退出正在运行的旧版本再打开**。安装位置和 bundle id 都是固定的，更新后已授予的系统权限会保留。从更早使用旧 bundle id 的版本升级时，需要重新授予一次。

命令行工具不需要安装，直接用 SwiftPM 运行：

```bash
swift run dclean scan
```

## 使用界面

### 1. 扫描

打开后自动扫描，约 30–60 秒。菜单栏图标显示磁盘已用比例（如「清 72%」），点开弹窗可以看到推荐方案能腾出多少空间。

### 2. 查看方案

点「查看详情」打开主窗口。清理项分四档：

| 档位 | 含义 | 默认 |
|---|---|---|
| 安全 | 包管理器缓存等，删了下次会自动重新下载 | 勾选 |
| 建议 | IDE / 浏览器 / AI 工具缓存，闲置 90 天以上且有锁文件的项目产物 | 勾选 |
| 需要确认 | 模型、本地仓库、闲置 30 天以上的项目产物等，删了可能要花较长时间恢复 | 不勾选 |
| 只展示 | 会话记录、Docker 虚拟磁盘、未识别的大目录 | 不可勾选，只能在 Finder 中查看 |

每一项可以展开看说明和具体路径。项目产物只清理依赖与构建产物（`node_modules`、`.venv`、`target`、`build`、`Pods`、`DerivedData`、`__pycache__` 等），不会动源码。

某项标着「被占用」或「需先退出 X」时，说明有程序正在使用它，这时清理会被跳过。

### 3. 确认并清理

勾选好后点底部「清理已选」，会弹出确认单：

- **移入恢复区**：7 天内可以还原
- **不可还原**（橙色）：由工具自带命令清理，例如 `npm cache clean --force`、`brew cleanup`，执行后无法撤回
- **需要先退出的应用**：浏览器等可以由清理大师代为正常退出；IDE、编辑器、Claude 等需要你自己保存后退出，不退出则相关项跳过

点「开始清理」后逐项执行，可以随时「停止」（已完成的不回退）。某个应用 10 秒内没有退出，会询问你「强制退出」还是「跳过相关项」。

结果页显示实际腾出的空间（按清理前后可用空间计算）、跳过和失败的原因。点「完成」后会自动重新扫描。

### 4. 恢复区

主窗口右上角进入。按批次列出，每一项都可以单独「还原」，也可以整批还原。

- 还原不会覆盖原位置已有的内容
- 超过 7 天的批次可以点「清空已到期」
- **「立即永久清空此批」会直接删除，不经过废纸篓，无法找回**，需要二次确认

恢复区里的文件仍占用磁盘空间。要真正腾出空间，需要等到期后清空，或者手动永久清空。

## 使用命令行

`dclean` 默认只读，不带 `--apply` 不会改动任何文件。

```bash
# 只读扫描，按档位列出
swift run dclean scan
swift run dclean scan --json
swift run dclean scan --no-space-map          # 跳过大目录分布，更快

# 预览清理方案（不执行）
swift run dclean clean
swift run dclean clean --tiers safe
swift run dclean clean --only npm-cache,pip-cache

# 真正执行
swift run dclean clean --tiers safe --apply
swift run dclean clean --only chrome-http-cache --quit-apps --apply   # 允许代为正常退出应用（不会退出 IDE）

# 恢复区
swift run dclean recovery list
swift run dclean recovery restore <批次ID>
swift run dclean recovery purge               # 预览将被永久清空的到期批次
swift run dclean recovery purge --apply       # 真正删除

# 查看已加载的规则
swift run dclean rules
```

## 覆盖范围

内置 29 条规则，`swift run dclean rules` 可以查看完整列表：

- **包管理器**：npm、pnpm、Bun、pip、uv、Poetry、Homebrew、CocoaPods、Gradle、Maven
- **开发工具**：Xcode 编译缓存与真机调试文件、JetBrains、VS Code、Cursor
- **AI 工具**：Claude 桌面端缓存与虚拟机镜像、Hugging Face 模型，以及 Codex / Claude Code 会话记录（只展示）
- **浏览器**：Chrome、Edge 缓存与内置模型；Playwright、Puppeteer、Camoufox 浏览器
- **项目产物**：自动识别家目录下各项目的依赖与构建产物，按最后活跃时间分档
- **Docker**：仅在 Docker 已运行时列出构建缓存、启动失败的旧容器、未被使用的镜像，不会替你启动 Docker

### 自定义规则

在 `~/.dclean-v3/user-rules.json` 中添加规则，文件格式与内置规则包相同（见 [`Sources/CleanerCore/Engine/RulePack.json`](Sources/CleanerCore/Engine/RulePack.json)）：

```json
{
  "version": 1,
  "platform": "macos",
  "rules": [
    {
      "id": "my-tool-cache",
      "name": "某工具缓存",
      "app": "某工具",
      "category": "dev",
      "tier": "confirm",
      "targets": ["~/Library/Caches/com.example.tool"],
      "action": { "type": "recover" },
      "copy": {
        "what": "某工具的临时缓存",
        "impact": "下次打开时重新生成"
      }
    }
  ]
}
```

自定义规则有额外限制：档位固定为 `confirm`（需要确认，默认不勾选），动作只能是移入恢复区（`recover` 或 `recoverOlderThan`），不能执行命令，也不能暂停服务。

规则会被逐条校验，指向根目录、家目录本身、隐私目录或使用通配的规则会被拒绝，拒绝原因可以用 `dclean rules` 查看。

## 安全设计

- **只清理规则明确列出的位置和识别出的项目产物**。不认识的目录只展示，不提供清理
- **执行前逐项复核**：路径、符号链接、保护区域、闲置时间与扫描时不一致就跳过
- **恢复区用同卷移动**，不复制；还原前核对内容摘要，内容变化或原位置已有内容则拒绝还原
- **审计日志写不进去就停止**：清理和永久清空前都先写审计，写不进去就不动手（从恢复区还原目前不写审计）
- **不会强制退出应用**，除非你在执行页面明确点了「强制退出」；IDE 与编辑器从不代为退出
- 同一时间只允许一个清理任务运行

## 数据位置

| 路径 | 内容 |
|---|---|
| `~/.dclean-v3/recovery/` | 恢复区 |
| `~/.dclean-v3/audit.log` | 审计日志（每行一条 JSON） |
| `~/.dclean-v3/user-rules.json` | 自定义规则（可选） |
| `~/.dclean-v2/` | 保护位置设置与操作锁 |

卸载：退出应用，删除 `~/Applications/清理大师V2.app`；确认恢复区里没有需要还原的内容后，再删除 `~/.dclean-v3`。

## 开发

```bash
swift build
swift test
```

| 目录 | 内容 |
|---|---|
| `Sources/CleanerCore/Engine/` | 引擎：规则包、识别器、空间估算、方案、执行器、恢复区 |
| `Sources/AppCore/` | 界面状态与逻辑（不依赖 AppKit，可单测） |
| `Sources/DiskCleanerApp/` | 菜单栏与主窗口界面（AppKit + SwiftUI） |
| `Sources/dclean/` | 命令行工具 |
| `docs/specs/`、`docs/plans/` | 设计与实施计划 |

新增规则请修改 `RulePack.json`，并在 `Tests/CleanerCoreTests` 中补充测试。
