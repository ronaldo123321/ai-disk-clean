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
    public var projectRoot: String?
    public var projectEvidence: ProjectEvidence?
    public var sizeIncomplete: Bool?

    public var isSelectable: Bool {
        tier != .displayOnly && action.type != .noAction && blockers.allSatisfy(\.isAppRunning)
    }

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
