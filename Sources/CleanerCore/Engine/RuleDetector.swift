import Foundation

public struct RuleDetector: Detector {
    public let rules: [CleanRule]
    public var name: String { "规则" }

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
            // 路径的任何一层都不能是符号链接，否则真实位置可能逃出预期范围。
            guard EnginePathChecks.isCanonical(path, files: context.files) else { return false }
            if rule.tier == .displayOnly {
                // 第二道防线：只展示项不走 assertAllowed，展开后（路径本身与其解析结果）仍不得落入个人隐私区（不区分大小写）
                let resolved = context.files.realPath(ofPath: path)?.lowercased() ?? path.lowercased()
                return !privacy.contains { root in
                    PathSafety.isInside(path.lowercased(), root: root) || PathSafety.isInside(resolved, root: root)
                }
            }
            return (try? context.safety.assertAllowed(path)) != nil
        }
        if rule.action.type == .recoverOlderThan, let days = rule.action.olderThanDays {
            let cutoff = context.now.addingTimeInterval(-Double(days) * 86_400)
            paths = paths.flatMap { (try? context.files.childrenOfDirectory(atPath: $0)) ?? [] }.filter { child in
                guard let attributes = context.files.attributesIfExist(atPath: child), attributes.isRegularFile,
                      !attributes.isSymbolicLink, let modified = attributes.modificationDate, modified < cutoff
                else { return false }
                return (try? context.safety.assertAllowed(child)) != nil
            }
        }
        let unique = Array(Set(paths))
        let finalPaths = unique.filter { path in
            !unique.contains { other in other != path && PathSafety.isInside(path, root: other) }
        }
        guard !finalPaths.isEmpty else { return nil }
        return CleanItem(id: "rule:" + rule.id, app: rule.app, category: rule.category, tier: rule.tier, title: rule.name,
                         paths: finalPaths.sorted(), action: rule.action, preconditions: rule.preconditions ?? .empty,
                         copy: rule.copy)
    }
}
