import SwiftUI
import CleanerCore
import AppCore

struct AppDetailView: View {
    let name: String
    let items: [CleanItem]
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(name, systemImage: "app").font(.title2.bold()); Spacer(); Button("关闭", action: close) }
            Text("规则识别的关联内容，不代表完整应用占用；不卸载应用或删除个人资料。")
                .foregroundStyle(.secondary)
            Text("\(items.count) 个条目 · 已统计 \(Format.bytes(items.reduce(0) { $0 + $1.apparentBytes }))\(items.contains { $0.sizeIncomplete == true } ? "（不完整）" : "")")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.title).font(.headline)
                            Text(item.copy.what)
                            Text("影响：" + item.copy.impact)
                            if let regrows = item.copy.regrows { Text("再次使用：" + regrows) }
                            Text(!item.isSelectable ? "已保护 / 不提供清理" : item.action.type == .command ? "原生命令 · 不可撤销 · 无恢复副本" : "移入恢复区 · 仍占空间")
                                .foregroundStyle(.secondary)
                            ForEach(item.preconditions.quitApps ?? [], id: \.bundleID) { app in
                                Text("需要退出：\(app.name)（\(app.bundleID)）").font(.caption)
                            }
                            ForEach(item.paths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            ForEach(item.blockers, id: \.self) { Text($0.message).foregroundStyle(.orange) }
                        }
                        Divider()
                    }
                }
            }
        }.padding(24).frame(width: 650, height: 540)
    }
}
