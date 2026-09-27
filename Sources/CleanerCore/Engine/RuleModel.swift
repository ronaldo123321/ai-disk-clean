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
