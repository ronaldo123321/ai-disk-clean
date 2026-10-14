import AppKit
import SwiftUI
import CleanerCore
import AppCore

struct ScanScopeView: View {
    @ObservedObject var model: AppModel
    private var roots: [String] { model.scanOptions.projectRoots ?? [model.homeDirectory] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("从你熟悉的目录开始").font(.title.bold())
            Text("项目扫描限于家目录内的工作目录；应用缓存仍按内置规则扫描。添加范围不会解除系统保护。")
                .foregroundStyle(.secondary)
            Text(model.isIsolated ? "临时验收模式：仅允许下方测试 Home，不接受真实家目录。" : "允许选择 Home 本身作为扫描范围；受保护的子目录仍会跳过。")
                .font(.callout).foregroundStyle(model.isIsolated ? Color.orange : Color.secondary)
            Text("当前允许的 Home：\(model.homeDirectory)").font(.caption.monospaced()).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("项目目录") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(roots, id: \.self) { path in
                                pathRow(path) {
                                    var options = model.scanOptions
                                    options.projectRoots = roots.filter { $0 != path }
                                    model.setScanOptions(options)
                                }
                            }
                            if roots.isEmpty { Text("不扫描项目，仅扫描应用与缓存规则").foregroundStyle(.secondary) }
                            Button("添加项目目录…") { choose(exclusion: false) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("排除目录 · 不扫描其项目内容") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.scanOptions.excludedPaths, id: \.self) { path in
                                pathRow(path) {
                                    var options = model.scanOptions
                                    options.excludedPaths.removeAll { $0 == path }
                                    model.setScanOptions(options)
                                }
                            }
                            Button("添加排除目录…") { choose(exclusion: true) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("长期保留 · 仍显示占用，不进入清理选择") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.scanOptions.keptPaths, id: \.self) { path in
                                pathRow(path) {
                                    var options = model.scanOptions
                                    options.keptPaths.removeAll { $0 == path }
                                    model.setScanOptions(options)
                                }
                            }
                            if model.scanOptions.keptPaths.isEmpty { Text("在条目详情点击「始终保留此项」。").foregroundStyle(.secondary) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("设置自动保存在本机；范围或排除规则更改后旧方案失效，必须重新扫描。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("开始扫描 →") { model.startScan() }.buttonStyle(.borderedProminent) }
        }.padding(24).disabled(!model.canEditScope)
    }

    private func pathRow(_ path: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("移除", action: remove).buttonStyle(.link).accessibilityLabel("移除 \(path)")
        }
    }

    private func choose(exclusion: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.homeDirectory)
        panel.title = model.isIsolated ? "选择临时测试 Home 或其工作目录" : "选择 Home 或家目录内的工作目录"
        panel.message = "允许的 Home：\(model.homeDirectory)\n选择扫描范围不会解除受保护子目录的限制。"
        panel.prompt = exclusion ? "排除" : "添加"
        guard panel.runModal() == .OK else { return }
        let files = RealFileOperations(home: model.homeDirectory)
        var paths: [String] = []
        for url in panel.urls {
            do { paths.append(try ScanScopeValidation.validate(url.path, files: files)) }
            catch {
                let alert = NSAlert()
                alert.messageText = model.isIsolated ? "临时验收模式：目录未通过范围检查" : "无法添加所选目录"
                alert.informativeText = "\(error)\n\n所选目录：\(url.path)\n允许的 Home：\(model.homeDirectory)\n\n"
                    + (model.isIsolated ? "如需扫描真实家目录，请退出临时验收版，打开正常 P2 版本。" : "Home 本身可以作为扫描范围；Documents、Desktop、密钥等受保护位置不会因此开放清理。")
                alert.runModal()
                return
            }
        }
        var options = model.scanOptions
        if exclusion { options.excludedPaths = Array(Set(options.excludedPaths + paths)).sorted() }
        else { options.projectRoots = Array(Set(roots + paths)).sorted() }
        model.setScanOptions(options)
    }
}
