import Foundation

public struct CleanPlan: Codable, Equatable, Sendable {
    public var items: [CleanItem]
    public var selectedIDs: Set<String>

    public init(items: [CleanItem], selectedIDs: Set<String>) {
        self.items = items
        self.selectedIDs = selectedIDs
    }

    public var selectedItems: [CleanItem] { items.filter { selectedIDs.contains($0.id) } }

    public var estimatedReclaimableBytes: Int64 { selectedItems.reduce(0) { $0 + $1.reclaimableBytes } }
    public var estimatedImmediateBytes: Int64 {
        selectedItems.filter { $0.action.type == .command }.reduce(0) { $0 + $1.reclaimableBytes }
    }
    public var recoveryMoveBytes: Int64 {
        selectedItems.filter { $0.action.type == .recover || $0.action.type == .recoverOlderThan }
            .reduce(0) { $0 + $1.apparentBytes }
    }

    public func items(in tier: CleanTier) -> [CleanItem] { items.filter { $0.tier == tier } }

    /// 已选项中需要先退出的应用（去重，保持出现顺序）
    public var appsToQuit: [QuitApp] {
        var seen = Set<String>()
        var apps: [QuitApp] = []
        for item in selectedItems {
            for blocker in item.blockers {
                guard case .appRunning(let name, let bundleID) = blocker, seen.insert(bundleID).inserted else { continue }
                let declared = item.preconditions.quitApps?.first { $0.bundleID == bundleID }
                apps.append(declared ?? QuitApp(name: name, bundleID: bundleID))
            }
        }
        return apps
    }

    public struct AppGroup: Equatable, Sendable {
        public var app: String
        public var bytes: Int64
        public var items: [CleanItem]
    }

    /// 「按应用」视图：同一应用的清理项合并，按表观占用从大到小。
    public var byApp: [AppGroup] {
        var groups: [String: [CleanItem]] = [:]
        var order: [String] = []
        for item in items {
            if groups[item.app] == nil { order.append(item.app) }
            groups[item.app, default: []].append(item)
        }
        return order.map { app in
            AppGroup(app: app, bytes: groups[app]!.reduce(0) { $0 + $1.apparentBytes }, items: groups[app]!)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.app < $1.app }
    }
}

public enum PlanBuilder {
    /// 默认勾选：安全档与建议档；被占用或无法处理的不勾选，只因应用在运行的仍勾选（执行时集中退出）。
    /// 被取消的扫描结果不产出任何默认勾选——其中的项可能未计算大小、未检查占用，不能当作可执行的方案。
    public static func build(from scan: ScanResult) -> CleanPlan {
        guard !scan.cancelled else { return CleanPlan(items: scan.items, selectedIDs: []) }
        let selected = scan.items.filter { item in
            item.tier.selectedByDefault && item.isSelectable
        }.map(\.id)
        return CleanPlan(items: scan.items, selectedIDs: Set(selected))
    }
}
