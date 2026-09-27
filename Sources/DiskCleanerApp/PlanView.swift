import AppKit
import SwiftUI
import CleanerCore
import AppCore

struct PlanView: View {
    @ObservedObject var model: AppModel
    @State private var byApp = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $byApp) {
                Text("按档位").tag(false)
                Text("按应用").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(8)
            List {
                if let plan = model.plan {
                    if byApp {
                        ForEach(plan.byApp, id: \.app) { group in
                            Section(header: Text("\(group.app)　\(Format.bytes(group.bytes))")) {
                                ForEach(group.items) { row($0) }
                            }
                        }
                    } else {
                        ForEach(CleanTier.allCases, id: \.self) { tier in
                            let items = plan.items(in: tier)
                            if !items.isEmpty {
                                Section(header: Text("\(tier.title)（\(items.count) 项）")) {
                                    ForEach(items) { row($0) }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let plan = model.plan, !plan.appsToQuit.isEmpty {
                    Text("需要先退出：" + plan.appsToQuit.map(\.name).joined(separator: "、")).foregroundStyle(.orange)
                }
                Spacer()
                Button("清理已选 \(Format.bytes(actionableItems.reduce(0) { $0 + $1.reclaimableBytes }))") {
                    model.requestClean(useDefaultSelection: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(actionableItems.isEmpty || model.recoveryBusy)
            }
            .padding(12)
        }
    }

    private var actionableItems: [CleanItem] {
        (model.plan?.selectedItems ?? []).filter { $0.tier != .displayOnly && $0.action.type != .noAction }
    }

    private func row(_ item: CleanItem) -> some View {
        ItemRow(item: item,
                selected: model.selectedIDs.contains(item.id),
                expanded: expanded.contains(item.id),
                onToggle: { model.toggle(item.id) },
                onExpand: {
                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                })
    }
}

struct ItemRow: View {
    let item: CleanItem
    let selected: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if item.tier == .displayOnly {
                    Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 18)
                } else {
                    Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggle() })).labelsHidden()
                }
                Text(item.title)
                ForEach(item.blockers, id: \.self) { blocker in
                    Text(blocker.message)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
                Text(Format.bytes(item.tier == .displayOnly ? item.apparentBytes : item.reclaimableBytes)).monospacedDigit()
                Button(expanded ? "收起" : "详情", action: onExpand).buttonStyle(.link)
            }
            if !item.notes.isEmpty {
                Text(item.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("是什么：" + item.copy.what)
                    Text("影响：" + item.copy.impact)
                    if let regrows = item.copy.regrows { Text("会长回来：" + regrows) }
                    if item.action.type == .command, let command = item.action.command {
                        Text("执行命令：" + command.joined(separator: " ")).font(.caption.monospaced())
                    }
                    ForEach(item.paths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 3)
    }
}
