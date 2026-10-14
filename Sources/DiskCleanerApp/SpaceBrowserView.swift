import SwiftUI
import CleanerCore
import AppCore

struct SpaceBrowserView: View {
    @ObservedObject var model: AppModel
    let showRules: () -> Void
    private var path: String { model.spaceListing?.path ?? model.homeDirectory }
    private var breadcrumbs: [String] {
        var result = [model.homeDirectory]
        for component in path.dropFirst(model.homeDirectory.count).split(separator: "/") {
            result.append(result.last! + "/" + component)
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("看清空间去了哪里").font(.title.bold())
            Text("只读目录占用，不等于可释放量。隐私目录、排除目录和符号链接不遍历；跨目录硬链接可能重复计数。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(breadcrumbs, id: \.self) { part in
                        Button(part == model.homeDirectory ? "用户目录" : (part as NSString).lastPathComponent) { model.browseSpace(part) }
                        Text("›").foregroundStyle(.secondary)
                    }
                }
            }.disabled(model.spaceBusy)
            if model.spaceBusy {
                HStack { ProgressView().controlSize(.small); Text("正在统计…"); Button("取消统计") { model.cancelSpaceBrowse() } }
            }
            if let error = model.spaceError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if model.spaceListing?.incomplete == true {
                Text("部分占用未知，未按 0 计算。每次最多检查 5 万项 / 10 秒，可进入子目录单独统计。")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.spaceListing?.entries ?? []) { entry in
                        HStack {
                            Image(systemName: entry.directory ? "folder" : "doc")
                            VStack(alignment: .leading) {
                                Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                                if let note = entry.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(width: 220, alignment: .leading)
                            ProgressView(value: Double(entry.bytes ?? 0), total: Double(max(model.spaceListing?.entries.compactMap(\.bytes).max() ?? 1, 1)))
                            Text(entry.bytes.map(Format.bytes) ?? "未知").monospacedDigit().frame(width: 85, alignment: .trailing)
                            Button("查看") { model.browseSpace(entry.path) }
                                .disabled(!entry.directory || model.spaceBusy)
                                .accessibilityLabel("查看 " + (entry.path as NSString).lastPathComponent)
                        }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.opacity(model.spaceBusy ? 0.5 : 1)
            HStack {
                Button("刷新当前目录") { model.browseSpace(path) }.disabled(model.spaceBusy)
                Spacer()
                Button("查看规则识别的产物 →", action: showRules)
            }
        }.padding(24)
        .onAppear { model.browseSpace(path) }
        .onDisappear { model.cancelSpaceBrowse() }
    }
}
