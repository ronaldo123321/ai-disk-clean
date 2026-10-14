import Foundation
import CleanerCore

public struct RecoveryOverview: Equatable {
    public struct Item: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var bytes: Int64
        /// 条目记录了所属清理项才能单独还原；否则只能整批还原。
        public var restorableIndividually: Bool
        public var originalPaths: [String] = []
    }

    public struct Batch: Equatable, Identifiable {
        public var id: String
        public var createdAt: Date
        public var bytes: Int64
        public var daysLeft: Int
        public var items: [Item]
    }

    public var batches: [Batch]
    public var orphans: [String]

    public static let empty = RecoveryOverview(batches: [], orphans: [])

    public var totalBytes: Int64 { batches.reduce(0) { $0 + $1.bytes } }
    public var expiredBatchIDs: [String] { batches.filter { $0.daysLeft <= 0 }.map(\.id) }

    public static func make(batches: [RecoveryBatch], orphans: [String], occupied: (RecoveryBatch) -> Int64,
                            now: Date, retentionDays: Int = RecoveryStore.retentionDays) -> RecoveryOverview {
        let rows = batches.sorted { $0.createdAt > $1.createdAt }.compactMap { batch -> Batch? in
            var order: [String] = []
            var titles: [String: String] = [:]
            var bytes: [String: Int64] = [:]
            var individual: [String: Bool] = [:]
            var paths: [String: [String]] = [:]
            for entry in batch.entries where entry.state == .stored || entry.state == .pending {
                let key = entry.itemID ?? entry.originalPath
                if titles[key] == nil {
                    order.append(key)
                    titles[key] = entry.itemTitle ?? (entry.originalPath as NSString).lastPathComponent
                    individual[key] = entry.itemID != nil
                }
                bytes[key, default: 0] += entry.bytes
                paths[key, default: []].append(entry.originalPath)
            }
            guard !order.isEmpty else { return nil }
            let age = Int(now.timeIntervalSince(batch.createdAt) / 86_400)
            return Batch(id: batch.id, createdAt: batch.createdAt, bytes: occupied(batch),
                         daysLeft: max(retentionDays - age, 0),
                         items: order.map { Item(id: $0, title: titles[$0]!, bytes: bytes[$0]!, restorableIndividually: individual[$0]!, originalPaths: paths[$0] ?? []) })
        }
        return RecoveryOverview(batches: rows, orphans: orphans)
    }
}
