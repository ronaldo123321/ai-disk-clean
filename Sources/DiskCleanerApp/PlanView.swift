import AppKit
import SwiftUI
import CleanerCore
import AppCore

struct PlanView: View {
    @ObservedObject var model: AppModel
    var projects = true
    @State private var query = ""
    @State private var filter = PlanFilter.all
    @State private var sort = PlanSort.size
    @State private var focusedID: String?
    @State private var showIssues = false
    @State private var detailApp: String?

    private var visible: [CleanItem] {
        PlanPresentation.visible(model.plan?.items ?? [], projects: projects, query: query,
                                 filter: filter, sort: sort, isKept: model.isKept)
    }
    private var groupKeys: [String] {
        var seen = Set<String>()
        return visible.map { $0.projectRoot ?? $0.app }.filter { seen.insert($0).inserted }
    }
    private var focused: CleanItem? { visible.first { $0.id == focusedID } ?? visible.first }
    private var editable: Bool { model.phase == .ready && !model.requiresRescan }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(projects ? "给项目留出呼吸的空间" : "应用与缓存").font(.title.bold())
                Text(projects ? "先看项目，再选产物。每一项都能单独保留。" : "只处理规则识别的条目，不把大目录等同于垃圾。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                metric("预计立即释放", Format.bytes(model.plan?.estimatedImmediateBytes ?? 0), "原生命令 · 不可撤销")
                Divider()
                metric("将移入恢复区", Format.bytes(model.plan?.recoveryMoveBytes ?? 0), "仍占空间 · 到期手动清空")
                Divider()
                metric("执行前再检查", "待复核", "变化或无法验证的项跳过")
            }.frame(height: 100).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            if let reason = model.rescanReason {
                HStack {
                    Label(reason, systemImage: "arrow.clockwise").foregroundStyle(.orange)
                    Spacer()
                    Button("重新扫描以启用勾选") { model.startScan() }.disabled(!model.canEditScope)
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let issues = model.scanResult?.issues, !issues.isEmpty {
                HStack {
                    Label("\(issues.count) 处扫描不完整，未知占用未计为 0；" + (model.requiresRescan ? "这是上次扫描的记录，请先重新扫描。" : "未受影响且可勾选的条目可单独处理。"), systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("查看详情") { showIssues = true }
                }.font(.caption).padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                TextField("搜索项目、产物或路径", text: $query).textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) { ForEach(PlanFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 145)
                Picker("排序", selection: $sort) { ForEach(PlanSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                Button("选择当前结果") { model.select(Set(visible.map(\.id)), selected: true) }.disabled(!editable)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if visible.isEmpty { Text("没有符合条件的条目").foregroundStyle(.secondary).padding(30) }
                        ForEach(groupKeys, id: \.self) { key in
                            let children = visible.filter { ($0.projectRoot ?? $0.app) == key }
                            groupHeader(key, children)
                            ForEach(children) { item in artifactRow(item) }
                        }
                    }
                }.frame(minWidth: 300)
                if let item = focused { detail(item).frame(width: 240) }
            }
            .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选 \(model.selectedIDs.count) 项").bold()
                    let outside = model.selectedIDs.subtracting(Set(visible.map(\.id))).count
                    Text("当前视图外 \(outside) 项 · 确认单会列出全部选择").font(.caption).foregroundStyle(.secondary)
                }
                Button("清空选择") { model.select(model.selectedIDs, selected: false) }.buttonStyle(.link)
                Spacer()
                Button("查看清理确认单 →") { model.requestClean(useDefaultSelection: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editable || model.selectedIDs.isEmpty || model.recoveryBusy)
            }
        }
        .padding(24)
        .sheet(isPresented: Binding(get: { detailApp != nil }, set: { if !$0 { detailApp = nil } })) {
            if let name = detailApp {
                AppDetailView(name: name, items: (model.plan?.items ?? []).filter { $0.projectRoot == nil && $0.app == name }, close: { detailApp = nil })
            }
        }
        .sheet(isPresented: $showIssues) {
            VStack(alignment: .leading, spacing: 14) {
                Text("扫描覆盖情况").font(.title2.bold())
                Text("未读取的内容未计入完整大小。请按具体错误检查目录或系统隐私权限后重扫。").foregroundStyle(.secondary)
                List(model.scanResult?.issues ?? []) { issue in
                    VStack(alignment: .leading) { Text(issue.path).font(.caption.monospaced()); Text(issue.message).font(.caption) }
                }
                Button("关闭") { showIssues = false }.keyboardShortcut(.cancelAction)
            }.padding(22).frame(width: 600, height: 420)
        }
    }

    private func metric(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private func groupHeader(_ key: String, _ children: [CleanItem]) -> some View {
        let eligible = Set(children.filter { $0.isSelectable && !model.isKept($0) }.map(\.id))
        let count = eligible.intersection(model.selectedIDs).count
        return HStack {
            Button {
                model.select(eligible, selected: count != eligible.count)
            } label: {
                Image(systemName: count == 0 ? "square" : count == eligible.count ? "checkmark.square.fill" : "minus.square.fill")
            }.buttonStyle(.plain).disabled(eligible.isEmpty || !editable)
                .accessibilityLabel("选择 \(children.first?.app ?? key) 当前可见产物")
            Image(systemName: projects ? "folder" : "app").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(children.first?.app ?? key).font(.callout.bold())
                if projects { Text(key).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            if !projects { Button("应用详情") { detailApp = children.first?.app ?? key } }
            Text(children.contains { $0.sizeIncomplete == true } ? "占用不完整" : Format.bytes(children.reduce(0) { $0 + $1.apparentBytes }))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color.primary.opacity(0.04))
    }

    private func artifactRow(_ item: CleanItem) -> some View {
        HStack(spacing: 10) {
            Toggle("选择 \(item.title)", isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggle(item.id) }))
                .labelsHidden().disabled(!item.isSelectable || model.isKept(item) || !editable)
                .help(model.selectionUnavailableReason(item) ?? "勾选后加入清理确认单，不会立即清理")
            Button { focusedID = item.id } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).lineLimit(1)
                    Text(!item.isSelectable ? "不提供清理" : item.action.type == .command ? "原生命令 · 不可撤销" : "移入恢复区 · 仍占空间").font(.caption2).foregroundStyle(.secondary)
                    if let reason = model.selectionUnavailableReason(item) {
                        Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(model.requiresRescan ? "需重扫" : model.isKept(item) ? "已保留" : !item.isSelectable ? "不可选" : item.tier.title)
                .font(.caption2).foregroundStyle(item.isSelectable ? Color.secondary : Color.orange)
            Text(item.sizeIncomplete == true ? "不完整" : Format.bytes(item.apparentBytes)).font(.caption).monospacedDigit()
        }.padding(12).background(focused?.id == item.id ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    private func detail(_ item: CleanItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass").font(.title).foregroundStyle(Color.accentColor)
                Text(item.title).font(.headline)
                Text(item.app).font(.caption).foregroundStyle(.secondary)
                if let reason = model.selectionUnavailableReason(item) {
                    Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
                Divider()
                Text("是什么 / 清理影响").font(.caption).foregroundStyle(.secondary)
                Text(item.copy.what).font(.callout)
                Text(item.copy.impact).font(.callout)
                Divider()
                Text("判断依据").font(.caption).foregroundStyle(.secondary)
                ForEach(item.notes, id: \.self) { Text($0).font(.caption) }
                ForEach(item.blockers, id: \.self) { Text($0.message).font(.caption).foregroundStyle(.orange) }
                ForEach(item.paths, id: \.self) { path in
                    Text(path).font(.caption2.monospaced()).textSelection(.enabled)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.buttonStyle(.link)
                }
                if !model.isKept(item) {
                    Button("始终保留此项") { model.keep(item) }.disabled(!model.canEditScope)
                } else { Text("已长期保留，可在扫描范围中管理").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}
