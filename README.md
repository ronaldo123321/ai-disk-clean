# AI工具清理大师

**专为 Cursor、Claude Code、Codex 等 AI 编程工具用户打造的 Mac 磁盘清理工具。**
找出闲置项目里的 `node_modules` / `.venv` / `target`、包管理器缓存、模型文件和 AI 工具缓存。能还原的先移进恢复区，7 天内随时可以还原。

[![下载最新版](https://img.shields.io/github/v/release/ronaldo123321/ai-disk-clean?label=%E4%B8%8B%E8%BD%BD&color=2ea44f)](https://github.com/ronaldo123321/ai-disk-clean/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Apple 芯片 + Intel](https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87%20%2B%20Intel-%E9%80%9A%E7%94%A8-blue)
[![MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

<!-- 截图 / 动图待补：扫描 → 确认单 → 恢复区。用临时目录造的演示数据截图，不要截真实项目名和路径。 -->

## 为什么做这个

Vibe coding 半年，磁盘悄悄被吃掉几十 GB：每个试过的项目都留着一份 `node_modules` 或 `.venv`，pnpm、uv、Homebrew 的缓存越积越多，Cursor、Claude 桌面端、Chrome 内置模型各自又占好几 GB。

通用清理工具什么都扫，但不认识这些东西，也不敢替你判断一个项目还用不用。AI工具清理大师只做这一件事：**把 AI 编程留下的垃圾找出来，讲清楚每一项是什么、删了有什么影响，并且让你后悔时还能还原。**

## 安全承诺

- **默认可还原**：项目产物和应用缓存先移进恢复区，保留 7 天，可以按项或整批还原，还原时不会覆盖原位置已有的内容。
- **不碰源码**：只清理依赖与构建产物。产物里有 Git 跟踪的文件、`.env`、密钥文件或疑似源码，就直接保护起来，不让勾选。
- **逐项复核**：执行前把每一项和扫描时的状态再比一遍，有变化就跳过。
- **不可还原的操作会单独标出**：比如 `brew cleanup`、`npm cache clean` 这类工具自带的命令，在确认单里用橙色列出，你勾选「我已了解」之后才能开始。
- **完全离线**：不联网，不上传任何数据，也不收集使用统计。
- **全程留痕**：清理、还原、永久清空都写入本机审计日志，审计写不进去就不执行。

## 安装

需要 macOS 13 或更新版本，Apple 芯片和 Intel 芯片都支持。

### 方式一：一行命令安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/ronaldo123321/ai-disk-clean/main/Scripts/install.sh | bash
```

它会下载最新版并装到 `~/Applications/AI工具清理大师.app`，装完自动打开。以后更新也是同一条命令（更新前先从菜单栏退出应用）。

### 方式二：手动下载

1. 在 [Releases](https://github.com/ronaldo123321/ai-disk-clean/releases/latest) 下载 `AI-Disk-Clean-macos.zip`，解压后把 `AI工具清理大师.app` 拖进「应用程序」。
2. 本项目没有经过苹果公证，第一次打开会提示「无法验证开发者」：
   - **macOS 15 及以上**：先双击一次，然后打开「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」，输入密码确认。
   - **macOS 13、14**：在「应用程序」里右键点它，选「打开」，再点「打开」。

   以后打开就不会再提示了。不放心的话可以用方式三，自己从源码构建。

### 方式三：从源码构建

需要 Xcode（编译能同时运行在 Apple 芯片和 Intel 上的版本需要完整的 Xcode）：

```bash
git clone https://github.com/ronaldo123321/ai-disk-clean.git
cd ai-disk-clean
Scripts/install-local.sh
```

### 命令行工具（可选）

命令行工具 `dclean` 已经放在应用里，建一个链接就能直接用：

```bash
sudo mkdir -p /usr/local/bin
sudo ln -sf ~/Applications/AI工具清理大师.app/Contents/MacOS/dclean /usr/local/bin/dclean
```

## 使用

### 1. 扫描

打开后自动只读扫描，菜单栏图标显示磁盘已用比例（如「清 72%」）。点开弹窗能看到推荐方案：**预计立即释放**多少空间，另有多少会**移入恢复区**（移进恢复区的仍然占空间，到期清空后才真正腾出来）。

想只扫自己的工作目录，可以在主窗口的「扫描范围」里添加项目目录和排除目录，设置会保存在本机。

### 2. 查看方案

主窗口左侧分为「项目清理」「应用与缓存」「扫描范围」「空间浏览」「历史与恢复」。清理项按风险分四档：

| 档位 | 含义 | 默认 |
|---|---|---|
| 安全 | 包管理器缓存等，删了下次会自动重新下载 | 勾选 |
| 建议 | IDE / 浏览器 / AI 工具缓存，闲置 90 天以上的项目产物 | 勾选 |
| 需要确认 | 模型、本地仓库、闲置 30 天以上的项目产物等，删了可能要花较长时间恢复 | 不勾选 |
| 只展示 | 会话记录、Docker 虚拟磁盘、未识别的大目录 | 不可勾选 |

- **项目清理**：按项目列出依赖与构建产物，可以整个项目勾选，也可以只勾其中几项；支持搜索、按体积或闲置时间排序。不想被清理的目录可以设为「始终保留」。
- **应用与缓存**：每一项可以看到是什么、删了有什么影响、会不会自动长回来，以及具体路径。
- **空间浏览**：只读的目录占用条形图，可以一层层往下看大目录，不会删除任何东西。

标着「被占用」或「需先退出 X」的项，说明有程序正在使用它，这时清理会跳过它。

### 3. 确认并清理

点「清理已选」会弹出确认单，分别列出移入恢复区的项、不可还原的命令，以及需要先退出的应用。浏览器这类应用可以由工具代为正常退出；IDE、编辑器需要你自己保存后退出，不退出的话相关项会跳过。

执行时逐项显示进度，可以随时「停止」，已经完成的不会回退。结果页显示卷可用空间的变化、移入恢复区的大小，以及跳过和失败的原因。

### 4. 历史与恢复

按批次列出每次清理，可以单项还原、整批还原，也可以还原到家目录内另一个空目录。

- 原位置已有内容时拒绝还原，不会覆盖
- 超过 7 天的批次可以「清空已到期」
- **「立即永久清空此批」会直接删除，不经过废纸篓，无法找回**，需要二次确认

## 命令行

`dclean` 默认只读，不带 `--apply` 不会改动任何文件。

```bash
dclean scan                     # 只读扫描，按档位列出
dclean scan --json
dclean clean                    # 预览默认方案（不执行）
dclean clean --tiers safe       # 只预览安全档
dclean clean --tiers safe --apply                          # 真正执行
dclean clean --only chrome-http-cache --quit-apps --apply  # 允许代为正常退出应用（不会退出 IDE）
dclean recovery list
dclean recovery restore <批次ID>
dclean recovery purge           # 预览将被永久清空的到期批次
dclean recovery purge --apply   # 真正删除
dclean rules                    # 查看已加载的规则
```

从源码运行时把 `dclean` 换成 `swift run dclean`。

## 能清理什么

内置 29 条规则（`dclean rules` 可以看完整列表），另外会自动识别项目产物：

- **项目产物**：`node_modules`、`.venv`、`target`、`build`、`dist`、`.next`、`Pods`、`DerivedData`、`__pycache__` 等，按项目最后活跃时间分档
- **包管理器**：npm、pnpm、Bun、pip、uv、Poetry、Homebrew、CocoaPods、Gradle、Maven
- **开发工具**：Xcode 编译缓存与真机调试文件、JetBrains、VS Code、Cursor
- **AI 工具**：Claude 桌面端缓存与虚拟机镜像、Hugging Face 模型；Codex 和 Claude Code 的会话记录只展示，不清理
- **浏览器**：Chrome、Edge 缓存与内置模型；Playwright、Puppeteer、Camoufox 浏览器
- **Docker**：只在 Docker 已运行时列出构建缓存、启动失败的旧容器、未被使用的镜像，不会替你启动 Docker

### 自定义规则

在 `~/.dclean-v3/user-rules.json` 中添加规则，文件格式与内置规则包相同（见 [`RulePack.json`](Sources/CleanerCore/Engine/RulePack.json)）：

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

自定义规则的档位固定为 `confirm`（需要确认，默认不勾选），动作只能是移入恢复区（`recover` 或 `recoverOlderThan`），不能执行命令。指向根目录、家目录本身、隐私目录或使用通配的规则会被拒绝，原因可以用 `dclean rules` 查看。

## 数据位置

| 路径 | 内容 |
|---|---|
| `~/.dclean-v3/recovery/` | 恢复区 |
| `~/.dclean-v3/audit.log` | 审计日志（每行一条 JSON） |
| `~/.dclean-v3/user-rules.json` | 自定义规则（可选） |
| `~/.dclean-v2/` | 保护位置设置与操作锁 |

**卸载**：退出应用，删除 `~/Applications/AI工具清理大师.app`。先确认恢复区里没有需要还原的内容，再删除 `~/.dclean-v3`。

## 开发

```bash
swift build
swift test
Scripts/install-local.sh    # 构建并安装到 ~/Applications
Scripts/make-release.sh     # 生成发行包 dist/AI-Disk-Clean-macos.zip
```

| 目录 | 内容 |
|---|---|
| `Sources/CleanerCore/Engine/` | 引擎：规则包、识别器、空间估算、方案、执行器、恢复区 |
| `Sources/AppCore/` | 界面状态与逻辑（不依赖 AppKit，可单测） |
| `Sources/DiskCleanerApp/` | 菜单栏与主窗口界面（AppKit + SwiftUI） |
| `Sources/dclean/` | 命令行工具 |
| `docs/` | 设计、计划与验收记录 |

新增规则请修改 `RulePack.json`，并在 `Tests/CleanerCoreTests` 中补充测试。欢迎提 Issue 告诉我们你的 AI 工具把空间占在了哪里。

## 许可证

[MIT](LICENSE)
