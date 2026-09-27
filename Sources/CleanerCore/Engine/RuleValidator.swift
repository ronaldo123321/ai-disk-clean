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

    /// APFS 默认大小写不敏感：~/documents 与 ~/Documents 是同一目录，比较时统一小写。
    private static func insideCI(_ path: String, _ root: String) -> Bool {
        PathSafety.isInside(path.lowercased(), root: root.lowercased())
    }

    private static func equalsCI(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
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
            if ["/", "/Users", safety.home].contains(where: { equalsCI(probe, $0) }) {
                out.append(prefix + "目标范围过大：\(target)")
            }
            if let wildcardIdx = components.firstIndex(where: { $0 == "*" }) {
                let parentComponents = components[..<wildcardIdx]
                let parentRaw: String
                if target.hasPrefix("/") {
                    parentRaw = "/" + parentComponents.joined(separator: "/")
                } else {
                    parentRaw = parentComponents.isEmpty ? "~" : parentComponents.joined(separator: "/")
                }
                let parent = safety.normalize(parentRaw)
                let dangerRoots = privacy + safety.treeForbiddenRoots
                if PathSafety.depth(of: parent) < 3
                    || dangerRoots.contains(where: { insideCI(parent, $0) || insideCI($0, parent) }) {
                    out.append(prefix + "通配目录范围过大或包含受保护位置：\(target)")
                }
            }
            // 恢复区只收家目录内的内容：可执行规则的目标落在家目录外，执行时只会失败。
            if rule.tier != .displayOnly, !insideCI(probe, safety.home) {
                out.append(prefix + "可执行规则的目标必须在家目录内：\(target)")
            }
            if privacy.contains(where: { insideCI(probe, $0) || insideCI($0, probe) }) {
                out.append(prefix + "目标指向个人隐私区：\(target)")
            } else if rule.tier != .displayOnly, safety.treeForbiddenRoots.contains(where: { insideCI(probe, $0) || insideCI($0, probe) }) {
                out.append(prefix + "可执行规则的目标命中禁区：\(target)")
            } else if rule.tier != .displayOnly, (try? safety.assertAllowed(probe)) == nil {
                out.append(prefix + "可执行规则的目标命中禁区或保护位置无法确认：\(target)")
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
