import Foundation
import CleanerCore

public enum PlanSort: String, CaseIterable { case size = "按体积", idle = "按闲置时间", name = "按名称" }
public enum PlanFilter: String, CaseIterable { case all = "全部条目", large = "大于 1 GB", idle = "闲置 90 天以上", protected = "已保护 / 保留" }

public enum PlanPresentation {
    public static func idleDays(_ item: CleanItem) -> Int {
        item.notes.first(where: { $0.hasPrefix("闲置 ") })?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
    }
    public static func visible(_ items: [CleanItem], projects: Bool, query: String, filter: PlanFilter,
                               sort: PlanSort, isKept: (CleanItem) -> Bool) -> [CleanItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard (item.projectRoot != nil) == projects else { return false }
            guard query.isEmpty || ([item.title, item.app] + item.paths).contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return false }
            switch filter {
            case .all: return true
            case .large: return item.apparentBytes > 1_000_000_000
            case .idle: return idleDays(item) >= 90
            case .protected: return !item.isSelectable || isKept(item)
            }
        }.sorted { lhs, rhs in
            switch sort {
            case .size: if lhs.apparentBytes != rhs.apparentBytes { return lhs.apparentBytes > rhs.apparentBytes }
            case .idle: if idleDays(lhs) != idleDays(rhs) { return idleDays(lhs) > idleDays(rhs) }
            case .name: if lhs.app != rhs.app { return lhs.app.localizedStandardCompare(rhs.app) == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }
}
