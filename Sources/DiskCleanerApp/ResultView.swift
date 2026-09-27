import SwiftUI
import CleanerCore
import AppCore

struct ResultView: View {
    @ObservedObject var model: AppModel
    @Binding var showRecovery: Bool

    var body: some View {
        if let summary = model.resultSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let measured = summary.report.measuredFreedBytes {
                        Text("已腾出 \(Format.bytes(max(measured, 0)))").font(.title2.bold())
                    } else {
                        Text("已腾出：未能测得").font(.title2.bold())
                    }
                    Text("按清理前后可用空间计算；完成 \(summary.doneCount) 项").foregroundStyle(.secondary)
                    if summary.report.recoveryBytes > 0 {
                        HStack {
                            Text("恢复区里新增 \(Format.bytes(summary.report.recoveryBytes))，\(RecoveryStore.retentionDays) 天后到期；清空后可再腾出这些空间")
                            Button("查看恢复区") { showRecovery = true }
                        }
                    }
                    if let hint = summary.gapHint { Text(hint).foregroundStyle(.secondary) }
                    groups("跳过", summary.skippedGroups, color: .secondary)
                    groups("失败", summary.failedGroups, color: .red)
                    if !summary.report.regrowNotes.isEmpty {
                        section("会自动长回来") { ForEach(summary.report.regrowNotes, id: \.self) { Text("· " + $0) } }
                    }
                    if !summary.report.serviceIssues.isEmpty {
                        section("需要你处理") {
                            ForEach(summary.report.serviceIssues, id: \.self) { Text("⚠ " + $0).foregroundStyle(.orange) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("完成") { model.finish() }.buttonStyle(.borderedProminent)
                            .disabled(model.recoveryBusy)
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func groups(_ title: String, _ groups: [ResultSummary.Group], color: Color) -> some View {
        if !groups.isEmpty {
            section("\(title) \(groups.reduce(0) { $0 + $1.results.count }) 项") {
                ForEach(groups, id: \.reason) { group in
                    Text(group.reason.title).bold().foregroundStyle(color)
                    ForEach(group.results, id: \.itemID) { result in
                        Text("· \(result.title)：\(detail(result.outcome))").font(.callout)
                    }
                }
            }
        }
    }

    private func detail(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .done: return "完成"
        case .skipped(let why), .failed(let why): return why
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bold()
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}
