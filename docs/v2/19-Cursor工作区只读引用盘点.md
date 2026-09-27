# 阶段二：Cursor 工作区只读引用盘点

## 实现

新增 CursorWorkspaceInventory 与 CLI 命令 `dclean workspaces [--json]`。固定盘点 Cursor/User/workspaceStorage 下的直属工作区，读取 workspace.json 的本地 folder 引用；输出 exists、confirmedMissing、unknown 及原因。报告始终 executable=false，不产生 Rule、Evidence 执行授权或清理计划。

目录包含符号链接、元数据不能可靠读取、远程引用、workspace 文件、未知格式均不推断为孤儿。项目缺失时仅从已挂载本地卷中选择最长匹配的卷根，交由 ReferenceReachabilityCollector 核验；外接卷未挂载、祖先不安全或设备不一致时保持 unknown。探测后再读取元数据比较变化。

存在任何 unknown 或目录枚举问题时 isComplete=false，CLI 返回 2，仍输出完整的已观察报告；这不是程序崩溃。

## 有界元数据读取

新增 BoundedMetadataReader。生产路径采用 SafeDirectory 逐级无链接打开父目录，并通过 openat + O_NOFOLLOW 打开普通文件。默认最大读取 64 KiB，超限拒绝，不读插件源码或工作区数据库。读取前后核对文件身份、长度和修改时间，文件变化时弃权。单测使用内存实现，并用独立临时夹具覆盖真实读取、叶链接及父目录链接拒绝。

## 本机只读结果

- 26 个工作区。
- 13 个项目目录存在，保留。
- 13 个元数据缺失、不可读取或不属于支持的本地 folder 格式，状态 unknown，保留。
- 0 个 confirmedMissing，未生成清理计划。
- 报告不完整（isComplete=false），命令返回 2 如实反映未知项。

报告保留在本地构建验收目录，未发送用户项目路径或元数据到外部服务。

## 验证

新增 11 项测试。全量测试 269 项，跳过 2 项，失败 0 项。Release 构建通过，差异格式检查通过。

## 未完成

本轮实现的是 Cursor 只读观察，不是失效工作区清理交付。尚未处理多根 workspace 文件、远程工作区、未知格式，也未绕过 APFS/挂载不确定性。下一步需明确这些元数据类型与卷身份，再绑定候选、占用和执行时证据重采集。

Claude 精确目录授权及执行/恢复链路、Codex 新规则仍待开发。没有真实删除、移动、恢复或规则修改。
