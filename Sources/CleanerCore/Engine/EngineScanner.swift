import Foundation

public struct ScanResult: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var disk: DiskSummary?
    public var items: [CleanItem]
    /// 被取消的扫描只含部分结果：可能未计算大小、未检查占用、未排序，不能用来生成方案或展示为扫描结果。
    public var cancelled: Bool

    public init(generatedAt: Date, disk: DiskSummary?, items: [CleanItem], cancelled: Bool = false) {
        self.generatedAt = generatedAt
        self.disk = disk
        self.items = items
        self.cancelled = cancelled
    }
}

/// 只读扫描：识别 → 估算 → 空间分布 → 阻塞检查 → 排序。
public final class EngineScanner {
    private let context: DetectContext
    private let detectors: [Detector]
    private let spaceMap: SpaceMapDetector?
    private let checker: PreconditionChecker
    /// 非 displayOnly 且非 sizedByDetector 的项，体积小于此阈值时不展示（默认 1 MiB）。
    public var minimumItemBytes: Int64

    public init(context: DetectContext, detectors: [Detector], spaceMap: SpaceMapDetector?, checker: PreconditionChecker,
                minimumItemBytes: Int64 = 1 << 20) {
        self.context = context
        self.detectors = detectors
        self.spaceMap = spaceMap
        self.checker = checker
        self.minimumItemBytes = minimumItemBytes
    }

    /// `onStep` 在扫描所在的线程上同步调用；调用方（如界面层）需要自行切回主线程再更新状态。
    public func scan(onStep: ((ScanStep) -> Void)? = nil) -> ScanResult {
        var items: [CleanItem] = []
        for detector in detectors {
            if context.isCancelled { return cancelledResult(items) }
            onStep?(.detecting(detector.name))
            items += detector.detect(context)
        }
        let sizer = Sizer(files: context.files, cancellation: context.cancellation)
        var covered: [String: Int64] = [:]
        var hasUnreadable = Array(repeating: false, count: items.count)
        var sizedAny = false
        for index in items.indices where !items[index].sizedByDetector {
            if context.isCancelled { return cancelledResult(items) }
            onStep?(.sizing(done: index, total: items.count))
            sizedAny = true
            let measurement = sizer.measure(items[index].paths)
            items[index].apparentBytes = measurement.apparent
            items[index].reclaimableBytes = items[index].tier == .displayOnly ? 0 : measurement.reclaimable
            if !measurement.unreadable.isEmpty {
                items[index].notes.append("有 \(measurement.unreadable.count) 个子目录无法读取（可能需要完全磁盘访问权限），大小可能偏小")
                hasUnreadable[index] = true
            }
            covered.merge(measurement.perPath) { max($0, $1) }
        }
        if sizedAny && !context.isCancelled { onStep?(.sizing(done: items.count, total: items.count)) }
        // 体积过小而被隐藏的项，除非有子目录读不到（此时大小可能被低估，不能拿它去判断「够不够小」）；
        // 隐藏的项本身仍然从 covered 里扣除，空间分布图不会把它已占的空间重复计入「未分类」——这是有意为之。
        items = items.indices.filter { index in
            items[index].tier == .displayOnly || items[index].sizedByDetector
                || items[index].apparentBytes >= minimumItemBytes || hasUnreadable[index]
        }.map { items[$0] }
        if let spaceMap {
            if context.isCancelled { return cancelledResult(items) }
            onStep?(.spaceMap)
            items += spaceMap.detect(context, covered: covered)
        }
        if context.isCancelled { return cancelledResult(items) }
        onStep?(.checkingBlockers)
        for index in items.indices where items[index].tier != .displayOnly {
            items[index].blockers = checker.blockers(for: items[index])
        }
        let order = CleanTier.allCases
        items.sort { lhs, rhs in
            let l = order.firstIndex(of: lhs.tier)!
            let r = order.firstIndex(of: rhs.tier)!
            if l != r { return l < r }
            let lb = lhs.tier == .displayOnly ? lhs.apparentBytes : lhs.reclaimableBytes
            let rb = rhs.tier == .displayOnly ? rhs.apparentBytes : rhs.reclaimableBytes
            if lb != rb { return lb > rb }
            return lhs.id < rhs.id
        }
        return ScanResult(generatedAt: context.now, disk: context.files.volumeSummary(atPath: context.home), items: items)
    }

    private func cancelledResult(_ items: [CleanItem]) -> ScanResult {
        ScanResult(generatedAt: context.now, disk: context.files.volumeSummary(atPath: context.home), items: items, cancelled: true)
    }
}
