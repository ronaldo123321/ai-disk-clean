import SwiftUI
import CleanerCore
import AppCore

struct ConfirmView: View {
    let summary: ConfirmationSummary
    let onCancel: () -> Void
    let onStart: (Set<String>) -> Void
    @State private var consented: Set<String>

    init(summary: ConfirmationSummary, onCancel: @escaping () -> Void, onStart: @escaping (Set<String>) -> Void) {
        self.summary = summary
        self.onCancel = onCancel
        self.onStart = onStart
        _consented = State(initialValue: Set(summary.appsWeCanQuit.map(\.bundleID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("将清理 \(summary.items.count) 项，预计腾出约 \(Format.bytes(summary.estimatedBytes))").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !summary.recoverable.isEmpty {
                        box(title: "移入恢复区（\(RecoveryStore.retentionDays) 天内可还原）", items: summary.recoverable, color: .secondary)
                    }
                    if !summary.irreversible.isEmpty {
                        box(title: "⚠ 不可还原（由工具自带命令清理）", items: summary.irreversible, color: .orange)
                    }
                    if !summary.appsWeCanQuit.isEmpty || !summary.appsUserMustQuit.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("需要先退出").bold()
                            ForEach(summary.appsWeCanQuit, id: \.bundleID) { app in
                                Toggle("\(app.name)　由我来正常退出（不勾选则相关项跳过）", isOn: Binding(
                                    get: { consented.contains(app.bundleID) },
                                    set: { if $0 { consented.insert(app.bundleID) } else { consented.remove(app.bundleID) } }))
                            }
                            ForEach(summary.appsUserMustQuit, id: \.bundleID) { app in
                                Text("✋ \(app.name)　请你保存后自己退出；不退出则相关项跳过").foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                    }
                }
            }
            .frame(maxHeight: 460)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("开始清理") { onStart(consented) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func box(title: String, items: [CleanItem], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)　\(items.count) 项 · \(Format.bytes(items.reduce(0) { $0 + $1.reclaimableBytes }))").bold()
            ForEach(items) { item in
                HStack {
                    Text(item.title)
                    if item.action.type == .command, let command = item.action.command {
                        Text(command.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(item.reclaimableBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6)))
    }
}
