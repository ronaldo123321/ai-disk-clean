import SwiftUI
import CleanerCore
import AppCore

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    /// 待二次确认的永久清空
    @State private var pendingPurge: PendingPurge?

    private enum PendingPurge: Equatable {
        case expired
        case batch(String)
    }

    private var busy: Bool { model.phase == .executing || model.phase == .scanning || model.recoveryBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("恢复区 \(Format.bytes(model.recovery.totalBytes))").font(.title3.bold())
                Text("保留 \(RecoveryStore.retentionDays) 天").foregroundStyle(.secondary)
                Spacer()
                Button("清空已到期（\(model.recovery.expiredBatchIDs.count) 批）") { pendingPurge = .expired }
                    .disabled(busy || model.recovery.expiredBatchIDs.isEmpty)
                Button("关闭", action: onClose)
            }
            if busy {
                Text(model.recoveryBusy ? "正在还原或清空，完成后再操作" : "清理或扫描进行中，完成后再操作").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(model.recovery.batches) { batch in
                    Section(header: HStack {
                        Text("\(Format.dateTime(batch.createdAt)) 的清理 · \(Format.bytes(batch.bytes)) · 还剩 \(batch.daysLeft) 天")
                        Spacer()
                        Button("全部还原") { model.restore(batchID: batch.id, itemIDs: nil) }
                            .disabled(busy)
                        Button("立即永久清空此批") { pendingPurge = .batch(batch.id) }
                            .disabled(busy)
                    }) {
                        ForEach(batch.items) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text(Format.bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("还原") { model.restore(batchID: batch.id, itemIDs: [item.id]) }
                                    .disabled(busy || !item.restorableIndividually)
                            }
                        }
                    }
                }
                if !model.recovery.orphans.isEmpty {
                    Section(header: Text("记录损坏的批次（不计入，也不会自动清空）")) {
                        ForEach(model.recovery.orphans, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
            if model.recovery.batches.isEmpty && model.recovery.orphans.isEmpty {
                Text("恢复区是空的").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 680, height: 500)
        .onAppear { model.refreshRecovery() }
        .alert(model.message ?? "", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.clearMessage() } })) {
            Button("好") { model.clearMessage() }
        }
        .confirmationDialog(purgeTitle, isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } })) {
            Button("永久清空", role: .destructive) {
                switch pendingPurge {
                case .expired: model.purgeExpired()
                case .batch(let id): model.purge(batchID: id)
                case nil: break
                }
                pendingPurge = nil
            }
            Button("取消", role: .cancel) { pendingPurge = nil }
        }
    }

    private var purgeTitle: String {
        switch pendingPurge {
        case .expired:
            return "永久清空已到期的 \(model.recovery.expiredBatchIDs.count) 批？"
        case .batch(let id):
            let bytes = model.recovery.batches.first(where: { $0.id == id })?.bytes ?? 0
            return "永久清空此批（\(Format.bytes(bytes))）？"
        case nil:
            return "永久删除后无法恢复，确定吗？"
        }
    }
}
