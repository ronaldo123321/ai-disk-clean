import Foundation
import CleanerCore

public struct HistoryBatch: Identifiable {
    public var id: String
    public var events: [AuditEvent]

    public static func make(_ events: [AuditEvent]) -> [HistoryBatch] {
        let visible = events.filter { ["run.start", "run.finish", "run.item.result", "restore.done", "purge.done"].contains($0.op) }
        let groups = Dictionary(grouping: visible) { event -> String in
            if let id = event.batchID { return id }
            if event.op == "run.start" { return event.detail.split(separator: " ").first.map(String.init) ?? "旧记录（批次未知）" }
            if event.op == "run.finish" || event.op == "purge.done" { return event.detail }
            // Legacy item results lack a batch key; never invent an association.
            return "旧记录（批次未知）"
        }
        return groups.map { HistoryBatch(id: $0.key, events: $0.value.sorted { $0.ts > $1.ts }) }
            .sorted {
                let a = $0.events.first?.ts ?? .distantPast, b = $1.events.first?.ts ?? .distantPast
                return a == b ? $0.id < $1.id : a > b
            }
    }
}
