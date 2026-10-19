# DiskCleaner 与 Mole、npkill、Pearcleaner、MangoDisk 的源码对比

研究日期：2026-10-13。范围：功能、交互、清理边界、恢复与可借鉴设计；不是实现方案批准，也不是安全认证。

## 结论

建议继续聚焦「Mac 开发者与 AI 编程用户的可解释、可恢复清理」。下一轮最值得做的是项目级决策体验和安全证据，而不是扩展成系统优化大全。

- 向 **Mole** 学习扫描范围、持久排除、清理原因和边界保护。
- 向 **npkill** 学习路径／体积／活跃时间一屏决策、渐进式扫描反馈。
- 向 **Pearcleaner** 学习应用身份、文件分类、详情侧栏、历史恢复入口。
- 向 **MangoDisk** 学习规则证据、细粒度选择、构建产物保护、空间分析导航。

DiskCleaner 已有规则、风险分档、确认、恢复区和审计基础。应把这些能力做成用户能理解和控制的产品，而不是重新搭引擎。竞争对象也包括用户自己运行包管理器清理命令、在 Finder 里找大目录，以及因为怕误删而不清理：能解释为什么可清理、为什么跳过，才有理由替代这些习惯。

## 研究方法与证据边界

本轮读取本地实际实现，并浅克隆四个官方仓库到临时目录进行定点源码阅读。结合 competitive-analysis 技能，以目标用户的决策成本和任务完成度排序，不按功能数量给分。

| 项目 | 本次源码版本 |
|---|---|
| DiskCleaner | `6de5a392f0c1790613d2fd6c6f23e420c6dfc692` |
| Mole | `3fdf4040c77ab048e4d8396c515c43ff633f2623` |
| npkill | `620f011bf79ebf345d76d916448b37840b30e2a3` |
| Pearcleaner | `7724df7111bff82ae243301cf701992ef05ecf19` |
| MangoDisk | `6ffff1f54caab0291c4d965230114be79d31306d` |

这是源码和文档分析，没有安装运行竞品、执行清理、做速度基准或完整 GUI 体验测试。读取测试代码只能证明有相应回归用例，不能证明当前测试已运行通过。界面判断来自视图和交互代码，优先级为本报告建议，不代表已验证的用户需求。

## 一、当前项目真正具备的能力

| 维度 | 当前实现 | 下一步差距 |
|---|---|---|
| 目标场景 | macOS 13+，开发缓存、AI 工具、浏览器、项目产物、Docker | 定位集中，应保留 |
| 规则 | 29 条内置 JSON 规则；支持受限自定义规则 | 缺少逐规则验证日期、来源、适用版本与生命周期 |
| 风险 | 安全／建议／需要确认／只展示；前两档默认选择 | 风险、恢复方式、重建成本没有在摘要层清晰分开 |
| 项目识别 | 多生态产物；结合活跃时间、工程标记和依赖文件 | 每项目一个选择项，不能逐个选择 `.venv`、`node_modules`、构建目录 |
| 扫描 | 阶段提示、取消、大小估算、占用检查 | 无结果渐进展示；范围选择和完整性说明不足 |
| 清理 | 确认单、应用退出同意、执行锁、审计、跳过原因 | 项目身份和活跃证据未完整绑定到执行前复核 |
| 恢复 | 同卷移动；按批次／项恢复；不覆盖现有目标；到期手动清空 | 缺少恢复冲突处理、还原到其他位置、完整历史界面 |
| 空间 | 已用／可用、硬链接感知估算、卷可用空间前后差 | 首页把恢复区移动也算作「可腾出」；不是完整磁盘可视化 |
| 保护 | 系统／隐私／凭据等保护；自定义保护路径存储 | 当前 GUI 缺少「始终保留」入口；保护与不扫描不是同一语义 |

本地关键证据：[项目检测](../../Sources/CleanerCore/Engine/ProjectArtifactDetector.swift)、[计划界面](../../Sources/DiskCleanerApp/PlanView.swift)、[规则包](../../Sources/CleanerCore/Engine/RulePack.json)、[执行器](../../Sources/CleanerCore/Engine/PlanExecutor.swift)、[恢复实现](../../Sources/CleanerCore/Engine/RecoveryStore.swift)。

有两点不能误读：七天是恢复批次的到期阈值，不是七天后自动删除；恢复目录的摘要基于路径、类型、大小、inode 等元数据，不是每个文件内容的字节级哈希。

## 二、Mole：学习清理范围和执行边界

Mole 官方仓库提供开源 CLI；原生 Mac 应用单独发行。不能把其原生应用的全部功能当作仓库里可直接复用的 SwiftUI 实现。

它覆盖缓存、卸载、空间分析、维护、监控、项目产物等场景。对我们最相关的是 `mo purge`、`--dry-run`、持久白名单和操作历史，而不是 CPU／风扇监控。

### 值得借鉴

1. **明确扫描哪些项目。** `mo purge --paths` 支持用户配置项目根目录。我们的检测器目前从家目录遍历，限制深度并排除家目录下隐藏目录。用户不能直接指定「只扫这几个工作目录」。GUI 应提供项目目录列表、临时扫描目录、排除目录，并说明没有覆盖的范围。
2. **把保留决定长期记住。** Mole 有持久保护名单。我们已有 ProtectedLocations 底层，但界面没有相应入口。增加「本次不选」和「始终保留」，重扫后保留用户决定；明确它是禁止清理还是连扫描都跳过。
3. **预览和执行使用同一范围。** 学习其 dry-run 与实际操作的边界表达。我们已有默认只读 CLI，应重点完善 GUI 的路径、动作和跳过原因，而不是重复增加一个预览按钮。
4. **构建目录不凭名字认定可删。** Mole 的项目保护包括 Git 跟踪文件、嵌套 Git 仓库、部署 keypair 等检测，未知或超时不能直接转成「安全」。这比单纯增加 `build`、`target` 命中率重要。
5. **历史可解释。** 以一次清理为单位呈现成功、跳过、失败及原因；我们已有日志，应先加可读界面，不必换日志架构。

其 purge 在删除前还检查候选活跃变化与父目录／目标身份，值得直接对照我们的执行前复核设计。Mole 默认七天闲置门槛是候选策略，不能与我们的七天恢复保留期混淆，也没有证据表明应该把我们的 30／90 天直接改成七天。[执行前检查](https://github.com/tw93/Mole/blob/3fdf4040c77ab048e4d8396c515c43ff633f2623/lib/clean/project.sh#L2941-L2964)。

### 不建议照搬

Mole 的项目 purge 是确认后的永久删除；它的 analyze 则有移入废纸篓行为，不能概括成所有操作都可恢复。不要为追求立即释放数字，取消我们已有恢复机制。系统维护、启动管理、监控也不应进入当前核心路线。

证据：[Mole README 与安全／purge 说明](https://github.com/tw93/Mole/blob/3fdf4040c77ab048e4d8396c515c43ff633f2623/README.md)、[项目范围配置](https://github.com/tw93/Mole/blob/3fdf4040c77ab048e4d8396c515c43ff633f2623/lib/manage/purge_paths.sh)、[项目保护代码](https://github.com/tw93/Mole/blob/3fdf4040c77ab048e4d8396c515c43ff633f2623/lib/clean/purge_shared.sh)。

## 三、npkill：学习一屏完成项目清理决策

npkill 的优势是任务集中：发现依赖目录、看大小和活跃时间、选择清理。支持按 size／path／age 排序、扫描目录与排除参数、批量操作，以及 JSON 和流式 JSON 输出。

需要修正只看简介时的印象：本次源码已不只覆盖 `node_modules`，还有 Node、Python、Rust、Swift 等 profile；部分 profile 纳入 `.dvc`、`.mlruns`、`outputs` 等目录。它们可能包含有价值的实验数据，不能把竞品的目标目录表直接变成我们的安全规则。[profile 源码](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/src/core/constants/profiles.constants.ts)。

### 值得借鉴

1. **项目专用视图。** 项目名、路径、体积、最后活跃时间和恢复方式应同时可见。用户不必逐项展开详情才能决定。
2. **项目 → 产物两级选择。** 我们已经按项目聚合，但一个项目的多个路径共用一个勾选框。建议保留项目汇总，同时允许只清 `.next`、保留 `node_modules`；每个子项独立计算空间和风险。这里是结合 npkill 的精确目录选择与我们多生态能力提出的设计，不是说 npkill 已提供同样的多生态树。
3. **大小／闲置时间排序与筛选。** 例如只看大于 1 GB、闲置超过 90 天、可恢复的产物。单独提供「显示近期项目」作为只读盘点，不应因为放宽显示范围就自动放宽清理条件。
4. **边发现边显示。** npkill 的扫描结果流与后续大小、时间计算分开。我们可先展示发现的项目，再补充体积与证据；未完成验证的行禁用清理。扫描取消后可以保留只读结果，但不能把未检查项当成完整方案。
5. **快捷键用于选择与浏览。** 支持上下移动、空格勾选、搜索、显示路径。最终动作仍进入现有确认单。

### 不建议照搬

不要照搬 Space／Del 直接删除或自动 delete-all 作为默认路径。源码中，部分大小计算异常会回退到 0；我们应明确显示「未能测得」，以免把未知误解为占用为零。活跃时间也只是证据，不等于用户未来不再需要这个环境。

选择体验也需要补一条自己的原则：批选限定为当前筛选结果，同时显示筛选外仍选中的数量。过滤不是撤销选择，不能让隐藏项悄悄进入最终执行。

证据：[npkill 使用与参数](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/README.md)、[扫描结果流和后续测量](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/src/cli/services/scan.service.ts)、[时间／体积列](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/src/cli/ui/components/result-columns.ts)。

## 四、Pearcleaner：学习身份清楚的原生界面和恢复入口

Pearcleaner 不只是拖入应用卸载：仓库还包含残留搜索、开发环境、Homebrew、服务等视图。它的源代码采用 Apache 2.0 加 Commons Clause；当前 README 标注开发暂停。应把它作为设计与源码研究对象，不假定它是持续维护中的宽松许可基础库。

### 值得借鉴

1. **应用身份在前，路径在后。** 详情侧栏展示图标、名称、版本、bundle identifier、安装位置与来源标记。我们的「按应用」只是文本聚合。给 Cursor、Claude、Xcode 等添加可信应用身份，会减少「这是谁的缓存」的疑惑。
2. **主列表简洁、侧栏解释充分。** 主列表负责比较和选择；侧栏说明用途、影响、目录与恢复方法。比在长列表里展开大段文字更适合几十个清理项。
3. **可理解的分类与范围设置。** 把应用缓存、日志、用户数据分开；通过目录设置管理扫描范围。我们可借鉴交互，但不能把名称匹配直接当作文件归属证明。
4. **历史就是用户入口。** Pearcleaner 有最近操作的废纸篓恢复界面。我们的恢复批次可以增加应用／项目图标、清理时间、原路径、状态和剩余保留时间，连接成功结果页与历史页。

### 我们已有且应保留的差异

我们自己的七天恢复区、批次与逐项还原、不覆盖目标、损坏记录拒绝清空是已有基础。没有必要改成只有系统废纸篓。更实用的是处理「原位置已重新生成」：解释冲突，允许后续设计中的另存位置，而不是只有失败信息。

### 不建议照搬

先借鉴列表、身份、侧栏与历史，不急着上完整卸载器、服务管理或应用瘦身。这些功能要解决共享容器、多版本同 bundle ID、包管理器归属等问题，明显超出缓存清理的边界。

此外，本次读取的文件搜索页「全选」使用全部 results，而不是当前文本过滤后的结果。这是值得避免的交互陷阱；我们应明确写「选择当前结果」，最终确认显示完整选择范围。[FileSearchView.swift](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Views/FileSearchView.swift#L384-L397)。

证据：[状态与功能说明](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/README.md)、[应用身份侧栏](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Views/FilesView/FilesSidebarView.swift)、[恢复历史界面](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Views/DeleteHistoryView.swift)、[目录设置](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Views/Settings/Folders.swift)。

## 五、MangoDisk：最值得研究的是证据链和细粒度操作

MangoDisk 覆盖综合清理、大文件、重复文件、空间分析、卸载、启动项、维护等，Vue 界面与 Rust/Tauri 后端的实现范围远大于当前项目。不建议照搬其全部模块或因它使用 Rust 而重写 Swift 引擎。

它的项目产物在当前实现中默认不选、也不加入推荐；我们符合条件的 90 天以上项目可进入建议档并默认选择。前者降低默认动作范围，后者减少用户操作，不能仅凭标签数量判断谁更安全。若继续保留我们的默认策略，应先补足用户内容保护和执行证据。[项目选择策略](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/src/cleanup/cleaners/project_artifacts.rs#L2698-L2720)。

### 值得借鉴

1. **规则也是需要维护的产品数据。** 规则资源包含版本、验证状态、验证日期、平台与证据来源；区分候选和可发布规则。我们的 JSON 目前主要描述路径、动作和说明。先增加轻量元数据与对应回归样例即可，不需要先做大型规则编辑器。
2. **项目产物里的用户内容保护。** 其实现检查嵌套 `.git`、`*-keypair.json`，并通过受控 `git ls-files` 判断产物中是否有 Git 跟踪文件；不能验证时阻止操作。我们的工程标记／lockfile／闲置时间有帮助，但不足以证明 `build` 或 `target` 内全是可丢弃内容。
3. **Codex worktree 专项识别。** 它有专门的 checkout 归属和 Git 双向关联检查，仅清理识别出的项目产物，不把整个 worktree、会话或凭据当作目标。我们当前跳过家目录下隐藏目录，不能指望普通项目扫描覆盖 `.codex/worktrees`。这可以成为贴合 AI 编程场景的后续能力，但前提是单独设计识别和保护策略。
4. **细粒度选择与统一确认。** 清理来源可细分；确认单汇总路径影响与应用退出选择。我们已有确认和退出流程，主要补子项选择、排序与更一致的摘要。
5. **空间分析可以下钻。** 它有目录导航、面包屑、列表排序、矩形树图／旭日图和虚拟列表。我们目前的 SpaceMapDetector 只是列出规则之外的大目录。先实现可下钻目录列表和条形占比，再评估树图；不必第一版同时做两种图。
6. **AI 解释不能成为删除权限。** 可选 AI 模块只解释条目，不选择项目、改风险或执行命令；原生检查和用户确认仍决定动作。我们现在的结构化「是什么／影响／会不会长回来」应先完善，LLM 解释可后置。若加入，明确发送哪些元数据；不要把它解释成完全本地功能。

细粒度选择不是只加复选框：MangoDisk 还区分 all／partial／none，处理来源列表截断，避免把显示出来的前 N 项等同于所有匹配项。我们增加分页或虚拟列表时，也应使「显示范围、选择范围、执行范围」一致。[选择模型](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src/lib/utils/cleanup-rule-selection.ts)。

### 不建议照搬

不把 AI 模型目录按普通缓存整体处理；不把「文件内容相同」直接等同于「任意一份都可删除」；不为实现大文件／重复文件功能而自动扩大已有保护范围。即使将来做这些模块，也应独立授权范围、默认不选和独立验收。

证据：[规则规范](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/rules/README.md)、[用户内容保护实现](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/src/cleanup/cleaners/project_artifact_protection.rs)、[Codex worktree 检测](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/src/cleanup/codex_worktrees.rs)、[空间分析组件](https://github.com/harry0703/MangoDisk/tree/6ffff1f54caab0291c4d965230114be79d31306d/src/pages/analysis/components)、[AI 边界](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/src/ai/README.md)。

## 六、应先解决的现有问题

先明确各产品的恢复含义，不能把风险标签、日志和真正的备份混为一谈：

| 产品／动作 | 本次核对的行为 | 对我们意味着什么 |
|---|---|---|
| DiskCleaner recover | 同卷移动到自有恢复区；到期后由用户清空 | 保留其用户可撤销价值，同时提前说明不立即释放空间 |
| DiskCleaner command | 原生命令清理，无恢复区 | 风险低不等于能撤销，确认单继续单独说明 |
| Mole purge／clean | 存在永久删除路径；analyze 使用废纸篓 | 按动作研究，不用一句「Mole 可恢复」概括 |
| npkill Unix 删除 | `execFile('rm', ['-rf', path])` | 借鉴选取效率，不借鉴默认删除方式 |
| Pearcleaner 文件删除 | 废纸篓路径映射及历史恢复；依赖原文件仍在 | 可以借鉴历史呈现，不是固定保留期保证 |
| MangoDisk 清理 | 存在受保护的永久删除层；staging 用于执行安全 | `Recoverable` 风险标签不等于提供七天备份恢复区 |

补充证据：[npkill 删除实现](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/src/core/services/files/unix-files.service.ts)、[Pearcleaner 移动与恢复](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Logic/UndoManager.swift)、[MangoDisk 永久删除边界](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/src-tauri/crates/mangodisk-core/src/filesystem/permanent_delete.rs)。

### 1. 清理前后的空间承诺不一致

`CleanPlan.estimatedReclaimableBytes` 直接累加已选项。Popover 使用它显示「可腾出」，而 recover 动作只是同卷移动，不能立即释放数据块。结果页虽然区分恢复区，但用户到最后才知道。

建议从首页到结果统一分开：

- **预计立即释放**：仅针对实际删除／原生命令可回收部分；无法精确预估时明确为估算。
- **将移入恢复区**：仍占用磁盘，可还原。
- **卷可用空间变化**：操作前后观测值，可能受其他程序写入影响，不保证全由本工具产生。

恢复区清空后的潜在释放量也要考虑硬链接；不要承诺「清空后必然腾出移动体积」。当前 Sizer 有硬链接处理，但不同清理项简单相加还不是全计划级去重。

证据：[累加口径](../../Sources/CleanerCore/Engine/CleanPlan.swift:14)、[菜单栏文案](../../Sources/DiskCleanerApp/PopoverView.swift:50)、[结果页](../../Sources/DiskCleanerApp/ResultView.swift:13)。

### 2. 项目产物的扫描证据没有完整带到执行时

GUI 有十分钟过期重扫机制；执行器也检查路径与符号链接；恢复区在移入前后核对身份和元数据摘要。这些保护应保留。

但项目项的 preconditions 当前为空，CleanItem 不保存扫描时身份；普通 recover 路径不会重新运行项目闲置／归属判断。恢复区的移入校验验证的是「移动前后是否一致」，不是「仍是用户刚才审核过的同一候选」。这两者不能混为一谈。

建议保存轻量候选证据，执行前复核归属、身份和用户内容；验证失败时跳过或要求重新扫描。优先补受控 Git 跟踪检查与嵌套仓库保护，再做 Codex 专项。不要用「有 lockfile」替代可重建性证明，尤其自建包、本地安装依赖和离线环境。

证据：[项目生成](../../Sources/CleanerCore/Engine/ProjectArtifactDetector.swift:124)、[执行前复核](../../Sources/CleanerCore/Engine/PlanExecutor.swift:337)、[移动阶段身份检查](../../Sources/CleanerCore/Engine/RecoveryStore.swift:395)。

### 3. 扫描不完整不能看起来像没发现垃圾

当前大小测量会注明部分不可读，但发现阶段存在 `try?` 跳过，GUI 也未呈现规则加载问题。应区分：没有命中、未扫描、无权限、规则失效、工具不可用、用户排除。先给简短可操作的提示，诊断详情可展开。

证据：[扫描流程](../../Sources/CleanerCore/Engine/EngineScanner.swift:37)、[规则加载与 GUI 服务](../../Sources/AppCore/EngineService.swift:54)。

## 七、建议优先级与验收方式

这里的优先级是建议，未实施。工作量是相对判断，不是排期承诺。

| 顺序 | 建议 | 来源 | 相对工作量 | 关键验收 |
|---|---|---|---|---|
| P0 | 立即释放／恢复区／观测变化分开呈现 | 当前差距、空间统计原则 | 小—中 | 仅 recover 的方案不能显示预计立即释放；硬链接案例不夸大承诺 |
| P0 | 项目内用户内容保护与执行前证据复核 | Mole、MangoDisk | 中 | 已跟踪文件、嵌套仓库、keypair、扫描后替换／重新活跃均受保护 |
| P1 | 项目 → 产物选择、搜索、大小／时间排序 | npkill、MangoDisk | 中 | 选一个产物只影响该路径；monorepo 不被整组误选 |
| P1 | 明确扫描目录、长期保留、排除管理 | Mole、Pearcleaner | 中 | 范围外不遍历；排除跨重扫保留；新增目录不解除原保护 |
| P1 | 渐进扫描与不完整状态提示 | npkill、MangoDisk | 中 | 未验证条目只读；取消不生成未验证可执行方案；权限错误可见 |
| P1 | 应用身份与详情侧栏 | Pearcleaner | 小—中 | 不展开每行也能比较；身份未知时显示未知，不猜归属 |
| P2 | 历史与恢复冲突体验 | Mole、Pearcleaner | 中 | 可查一次操作；冲突不覆盖；恢复也纳入可追溯记录 |
| P2 | 可下钻空间列表／条形图 | MangoDisk | 中—大 | 占用口径一致；不因目录大就自动提供危险清理 |
| P2 | 规则验证元数据与样例 | MangoDisk | 中 | 每条生产规则有边界证据、验证日期与回归样例 |
| P2 | Codex worktree 产物识别 | MangoDisk | 大 | 仅识别归属明确的产物；源码、会话、凭据及整个 worktree 保留 |
| 后置 | 卸载器、重复文件、自动定时清理、系统维护、AI 解释 | 各竞品 | 范围跨度大 | 单独做需求与安全设计，不混入本轮优化 |

如果只做一轮：先补 P0，再选「项目视图 + 保留／排除 + 扫描反馈」作为核心产品升级。验收既看安全回归，也看用户能否更快完成选择；不要把扫描数量、清理 GB 或规则条数单独当作成功标准。

## 八、源码借鉴边界

本轮借鉴的是设计和机制，没有复制竞品代码。仓库许可分别是 Mole GPL-3.0、npkill MIT、Pearcleaner Apache-2.0 加 Commons Clause、MangoDisk GPL-3.0；进入实际代码复用前，需要针对要引入的文件核对许可，而不是因为 GitHub 能看到源码就直接搬用。

许可原文：[Mole](https://github.com/tw93/Mole/blob/3fdf4040c77ab048e4d8396c515c43ff633f2623/LICENSE)、[npkill](https://github.com/voidcosmos/npkill/blob/620f011bf79ebf345d76d916448b37840b30e2a3/LICENSE)、[Pearcleaner](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/LICENSE.md)、[MangoDisk](https://github.com/harry0703/MangoDisk/blob/6ffff1f54caab0291c4d965230114be79d31306d/LICENSE)。
