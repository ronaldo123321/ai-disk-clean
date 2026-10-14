import SwiftUI
import CleanerCore
import AppCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let openMain: () -> Void
    let openMainAndClean: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let disk = model.scanResult?.disk { DiskSummaryView(disk: disk) }
            switch model.phase {
            case .scanning:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.scanStep?.title ?? "正在扫描…")
                    Spacer()
                    Button("取消") { model.cancelScan() }
                }
            case .executing:
                Button("正在清理 \(model.progress.finished.count) / \(model.progress.total)，点击查看", action: openMain)
            case .finished:
                Text("清理完成，请在主窗口查看结果").foregroundStyle(.secondary)
            default:
                if let plan = model.defaultPlan {
                    recommendation(plan)
                } else {
                    Button("开始扫描") { model.startScan() }
                }
            }
            Divider()
            HStack {
                Button("查看详情", action: openMain)
                Spacer()
                Text("恢复区 \(Format.bytes(model.recovery.totalBytes))").foregroundStyle(.secondary)
            }
            if let date = model.scanResult?.generatedAt {
                Text("上次扫描：\(Format.relative(date, now: Date()))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func recommendation(_ plan: CleanPlan) -> some View {
        let selected = plan.selectedItems
        VStack(alignment: .leading, spacing: 6) {
            Text("预计立即释放 \(Format.bytes(plan.estimatedImmediateBytes))").bold()
            Text("移入恢复区 \(Format.bytes(plan.recoveryMoveBytes))（仍占空间）").font(.caption)
            Text(CleanTier.allCases.filter { $0 != .displayOnly }.compactMap { tier in
                let count = selected.filter { $0.tier == tier }.count
                return count > 0 ? "\(tier.title) \(count) 项" : nil
            }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if !plan.appsToQuit.isEmpty {
                Text("需要先退出：" + plan.appsToQuit.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.orange)
            }
            Button("查看推荐确认单", action: openMainAndClean)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || model.phase == .confirming || model.phase == .finished || model.recoveryBusy)
        }
    }
}
