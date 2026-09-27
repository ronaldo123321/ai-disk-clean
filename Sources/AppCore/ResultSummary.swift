import Foundation
import CleanerCore

public struct ResultSummary: Equatable {
    public struct Group: Equatable {
        public var reason: OutcomeReason
        public var results: [ItemRunResult]
    }

    public var report: RunReport
    public var doneCount: Int
    public var skippedGroups: [Group]
    public var failedGroups: [Group]
    /// 实际腾出远小于「工具自带命令」项的预估时给出的解释；移入恢复区的项本来就不腾出空间，不计入预估。
    public var gapHint: String?

    public init(report: RunReport, commandItemIDs: Set<String>) {
        self.report = report
        doneCount = report.results.filter { $0.outcome == .done }.count
        skippedGroups = Self.group(report.results) { if case .skipped = $0 { return true }; return false }
        failedGroups = Self.group(report.results) { if case .failed = $0 { return true }; return false }
        let expected = report.results.filter { $0.outcome == .done && commandItemIDs.contains($0.itemID) }
            .reduce(0) { $0 + $1.estimatedBytes }
        // 没测到前后可用空间就不下结论
        if let measured = report.measuredFreedBytes, expected > 100 << 20, max(measured, 0) < expected / 2 {
            gapHint = "实际腾出比预估少很多，可能是：清理命令只删掉了一部分缓存、缓存文件与其他目录共用（硬链接），或清理期间其他程序在写入磁盘。"
        } else {
            gapHint = nil
        }
    }

    private static func group(_ results: [ItemRunResult], _ matches: (RunOutcome) -> Bool) -> [Group] {
        var order: [OutcomeReason] = []
        var buckets: [OutcomeReason: [ItemRunResult]] = [:]
        for result in results where matches(result.outcome) {
            let reason = result.reason ?? .other
            if buckets[reason] == nil { order.append(reason) }
            buckets[reason, default: []].append(result)
        }
        return order.map { Group(reason: $0, results: buckets[$0]!) }
    }
}
