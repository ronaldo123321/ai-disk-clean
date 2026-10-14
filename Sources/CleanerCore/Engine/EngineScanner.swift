import Foundation

public struct ScanResult: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var disk: DiskSummary?
    public var items: [CleanItem]
    /// 被取消的扫描只含部分结果：可能未计算大小、未检查占用、未排序，不能用来生成方案或展示为扫描结果。
    public var cancelled: Bool
    public var issues: [ScanIssue]?

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
            let found = detector.detect(context)
            items += found.flatMap { item -> [CleanItem] in
                guard item.id.hasPrefix("project:") else { return [item] }
                let root = String(item.id.dropFirst("project:".count))
                return item.paths.map { path in
                    var child = item
                    child.id = "artifact:" + path
                    child.projectRoot = root
                    child.title = (path as NSString).lastPathComponent
                    child.paths = [path]
                    child.copy.what = String(path.dropFirst(root.count + 1))
                    return child
                }
            }
            onStep?(.preview(items))
        }
        let sizer = Sizer(files: context.files, cancellation: context.cancellation)
        items = items.filter { item in
            !item.paths.isEmpty || item.sizedByDetector
        }.filter { item in
            !item.paths.contains { path in context.options.excludedPaths.contains { PathSafety.isInside(path, root: context.safety.normalize($0)) } }
        }
        for index in items.indices {
            let protected = context.options.keptPaths + context.options.excludedPaths
            if items[index].paths.contains(where: { path in protected.contains { p in
                let p = context.safety.normalize(p)
                return PathSafety.isInside(path, root: p) || PathSafety.isInside(p, root: path)
            } }) { items[index].blockers.append(.unavailable("已长期保留或包含排除路径")) }
        }
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
                items[index].notes.append("有 \(measurement.unreadable.count) 个目录无法读取，大小不完整，不能清理")
                items[index].sizeIncomplete = true
                items[index].blockers.append(.unavailable("目录未完整读取"))
                for path in measurement.unreadable { context.diagnostics.record(path, "目录无法读取，未计入完整大小") }
                hasUnreadable[index] = true
            }
            if let root = items[index].projectRoot, let path = items[index].paths.first {
                do {
                    items[index].projectEvidence = try ProjectProtection.capture(root: root, artifact: path,
                        files: context.files, runner: context.runner, now: context.now, cancellation: context.cancellation)
                    items[index].notes.append("已检查 Git 跟踪内容、敏感文件与产物身份；执行前再次复核")
                } catch {
                    items[index].blockers.append(.unavailable(String(describing: error)))
                    items[index].tier = .displayOnly
                }
            }
            covered.merge(measurement.perPath) { max($0, $1) }
            onStep?(.preview(Array(items.prefix(index + 1))))
        }
        if sizedAny && !context.isCancelled { onStep?(.sizing(done: items.count, total: items.count)) }
        // 体积过小而被隐藏的项，除非有子目录读不到（此时大小可能被低估，不能拿它去判断「够不够小」）；
        // 隐藏的项本身仍然从 covered 里扣除，空间分布图不会把它已占的空间重复计入「未分类」——这是有意为之。
        items = items.indices.filter { index in
            items[index].tier == .displayOnly || items[index].sizedByDetector
                || items[index].apparentBytes >= minimumItemBytes || hasUnreadable[index]
        }.map { items[$0] }
        if let spaceMap, context.options.projectRoots == nil {
            if context.isCancelled { return cancelledResult(items) }
            onStep?(.spaceMap)
            items += spaceMap.detect(context, covered: covered)
        }
        if context.isCancelled { return cancelledResult(items) }
        onStep?(.checkingBlockers)
        for index in items.indices where items[index].tier != .displayOnly {
            items[index].blockers += checker.blockers(for: items[index])
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
        var result = ScanResult(generatedAt: context.now, disk: context.files.volumeSummary(atPath: context.home), items: items)
        result.issues = context.diagnostics.issues
        return result
    }

    private func cancelledResult(_ items: [CleanItem]) -> ScanResult {
        ScanResult(generatedAt: context.now, disk: context.files.volumeSummary(atPath: context.home), items: items, cancelled: true)
    }
}
