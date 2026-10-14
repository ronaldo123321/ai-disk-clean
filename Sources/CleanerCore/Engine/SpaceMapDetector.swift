import Foundation

/// 规则之外的大目录：只展示，帮助用户知道空间去了哪。
/// 部分内容已被其他清理项覆盖的目录，扣除已覆盖部分后仍够大才展示。
public struct SpaceMapDetector {
    public var threshold: Int64

    public init(threshold: Int64 = 1 << 30) { self.threshold = threshold }

    /// APFS 默认大小写不敏感：比较时统一小写。
    private func isInsideCI(_ path: String, _ root: String) -> Bool {
        PathSafety.isInside(path.lowercased(), root: root.lowercased())
    }

    public func detect(_ context: DetectContext, covered: [String: Int64]) -> [CleanItem] {
        let files = context.files
        let home = context.home
        // 不扫描 ~/Library/Containers：读取其他 App 的沙盒容器会触发 macOS
        // 「访问其他 App 数据」隐私提示，后台扫描不能弹这种框。
        // ~/Downloads 同理：非完全磁盘访问权限的进程读取它会触发系统的访问其他数据提示。
        let roots = [home, home + "/Library/Application Support", home + "/Library/Caches", home + "/.cache"]
        let excluded = Set(roots + [home + "/Library", home + "/.Trash", home + "/Downloads"])
        let forbidden = RuleValidator.privacyRoots(home: home) + context.safety.treeForbiddenRoots
        let homeDevice = files.attributesIfExist(atPath: home)?.device
        // 嵌套的 covered key（如不同清理项分别覆盖了父子目录）只应按最外层去重一次，避免重复扣减。
        var dedupedCovered: [String: Int64] = [:]
        for (key, value) in covered {
            let isNested = covered.keys.contains { $0 != key && isInsideCI(key, $0) }
            if !isNested { dedupedCovered[key] = value }
        }
        var items: [CleanItem] = []
        for root in roots {
            let children: [String]
            do { children = try files.childrenOfDirectory(atPath: root) }
            catch {
                if !Sizer.isVanished(error) { context.diagnostics.record(root, "目录无法读取：\(error)") }
                continue
            }
            for child in children {
                if context.isCancelled { return items }
                // Never re-enter an excluded subtree via the legacy large-directory inventory.
                if context.options.excludedPaths.contains(where: {
                    let path = context.safety.normalize($0)
                    return isInsideCI(child, path) || isInsideCI(path, child)
                }) { continue }
                if root == home, let scopes = context.options.projectRoots,
                   !scopes.contains(where: { isInsideCI(child, context.safety.normalize($0)) || isInsideCI(context.safety.normalize($0), child) }) {
                    continue
                }
                guard !excluded.contains(child),
                      let attributes = files.attributesIfExist(atPath: child), attributes.isDirectory, !attributes.isSymbolicLink,
                      EnginePathChecks.isCanonical(child, files: files),
                      homeDevice == nil || attributes.device == nil || attributes.device == homeDevice,
                      !forbidden.contains(where: { isInsideCI(child, $0) }),
                      !dedupedCovered.keys.contains(where: { isInsideCI(child, $0) }) else { continue }
                let coveredInside = dedupedCovered.filter { isInsideCI($0.key, child) }.values.reduce(0, +)
                var unreadable = false
                let remaining = files.apparentSize(of: child, cancellation: context.cancellation,
                                                   onUnreadable: { path, error in
                                                       unreadable = true
                                                       context.diagnostics.record(path, "占用统计不完整：\(error)")
                                                   }) - coveredInside
                guard remaining >= threshold else { continue }
                var item = CleanItem(
                    id: "space:" + child, app: "未识别", category: .other, tier: .displayOnly,
                    title: "未识别：~" + child.dropFirst(home.count), paths: [child], action: .noAction,
                    preconditions: .empty,
                    copy: RuleCopy(what: "规则之外的目录，工具不知道它能否清理",
                                   impact: "只展示占用，可在 Finder 中自行查看", regrows: nil))
                if coveredInside > 0 { item.notes.append("已扣除其中已列出的清理项") }
                if unreadable { item.notes.append("部分子目录无法读取，大小不完整"); item.sizeIncomplete = true }
                item.apparentBytes = remaining
                item.sizedByDetector = true
                items.append(item)
            }
        }
        return items
    }
}
