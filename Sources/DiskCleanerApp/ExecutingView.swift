import SwiftUI
import CleanerCore
import AppCore

struct ExecutingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正在清理 \(model.progress.finished.count) / \(model.progress.total)").font(.title3.bold())
            ProgressView(value: Double(model.progress.finished.count), total: Double(max(model.progress.total, 1)))
            if !model.stuckApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("以下应用 10 秒内没有退出（可能有未关闭的对话框）").bold()
                    // 每个应用各选一次，全部选完自动继续
                    ForEach(model.stuckApps, id: \.bundleID) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            if let force = model.stuckDecisions[app.bundleID] {
                                Text(force ? "将强制退出" : "将跳过相关项").foregroundStyle(.secondary)
                            } else {
                                Button("强制退出 \(app.name)") { model.decideStuckApp(app.bundleID, forceQuit: true) }
                                Button("跳过 \(app.name) 相关的 \(model.affectedItemCount(for: app)) 项") {
                                    model.decideStuckApp(app.bundleID, forceQuit: false)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange))
            }
            if let current = model.progress.currentTitle {
                Label("正在处理：\(current)", systemImage: "hourglass")
            } else if model.progress.finished.isEmpty && model.stuckApps.isEmpty {
                Label(model.progress.currentStep ?? "正在退出需要关闭的应用…", systemImage: "hourglass")
            }
            List(model.executionRows, id: \.id) { ExecutionLine(row: $0) }
            HStack {
                Text("停止后，当前这一项做完就停，已完成的不会撤回").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.progress.stopping ? "正在停止…" : "停止") { model.stopClean() }
                    .disabled(model.progress.stopping)
            }
        }
        .padding(20)
    }
}

/// 执行页的一行：每一项都显示，带状态（等待 / 进行中 / 完成 / 跳过 / 失败）
struct ExecutionLine: View {
    let row: ExecutionRow

    var body: some View {
        HStack {
            switch row.status {
            case .waiting:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text(row.title).foregroundStyle(.secondary)
            case .running(let step):
                ProgressView().controlSize(.small)
                Text(row.title)
                if let step { Text(step).font(.caption).foregroundStyle(.secondary) }
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(row.title)
            case .skipped(let why):
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text(row.title)
                Text(why).font(.caption).foregroundStyle(.secondary)
            case .failed(let why):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(row.title)
                Text(why).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Text(row.status.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
