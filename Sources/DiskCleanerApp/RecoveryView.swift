import SwiftUI
import AppKit
import CleanerCore
import AppCore

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    var embedded = false
    @State private var showHistory = false
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
            Picker("记录", selection: $showHistory) {
                Text("可还原批次").tag(false)
                Text("操作历史").tag(true)
            }.pickerStyle(.segmented)
            if showHistory {
                Text("读取本机审计日志（当前及上一代），不是永久完整历史。命令清理无恢复副本；记录缺失不代表未执行。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(HistoryBatch.make(model.history)) { batch in
                            Text("批次：" + batch.id).font(.headline).textSelection(.enabled)
                            ForEach(Array(batch.events.enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(Format.dateTime(event.ts)) · \(historyTitle(event))").bold()
                                    if let title = event.itemTitle { Text(title) }
                                    Text(event.detail).font(.caption).textSelection(.enabled)
                                    ForEach(event.paths ?? [], id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                    if event.action == "command" { Text("原生命令 · 无恢复副本").font(.caption).foregroundStyle(.orange) }
                                }
                                Divider()
                            }
                        }
                        if model.history.isEmpty { Text("没有可读取的历史记录").foregroundStyle(.secondary) }
                    }
                }
            } else {
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    ForEach(item.originalPaths, id: \.self) { Text($0).font(.caption2.monospaced()).textSelection(.enabled) }
                                }
                                Spacer()
                                Text(Format.bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("还原") { model.restore(batchID: batch.id, itemIDs: [item.id]) }
                                    .disabled(busy || !item.restorableIndividually)
                                Button("另存恢复…") { alternateRestore(batch.id, item.id) }
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
            Text("还原不会覆盖原位置；如有冲突，可另选家目录内同卷空目录。到期只提醒，不自动清空。")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .frame(width: embedded ? nil : 800, height: embedded ? nil : 560)
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

    private func alternateRestore(_ batchID: String, _ itemID: String) {
        let panel = NSOpenPanel()
        panel.title = "选择家目录内的空目录（不覆盖、不合并）"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.homeDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            model.restore(batchID: batchID, itemIDs: [itemID], destinationDirectory: url.resolvingSymlinksInPath().path)
        }
    }

    private func historyTitle(_ event: AuditEvent) -> String {
        switch event.op {
        case "run.start": return "开始清理"
        case "run.finish": return "清理结束"
        case "restore.done": return event.action == "alternate" ? "已另存恢复" : "已还原"
        case "purge.done": return "已永久清空"
        default: return "条目执行结果"
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
