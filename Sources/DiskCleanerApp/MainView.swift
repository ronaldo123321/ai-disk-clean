import SwiftUI
import CleanerCore
import AppCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showRecovery = false
    @State private var section = "项目清理"

    /// macOS 一个窗口只显示一个 sheet：确认单优先于恢复区，所以恢复区打开时点一键清理会切换到确认单。
    private enum SheetKind: Identifiable {
        case confirm, recovery
        var id: Self { self }
    }

    private var activeSheet: Binding<SheetKind?> {
        Binding(
            get: {
                if model.phase == .confirming { return .confirm }
                if showRecovery { return .recovery }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    if model.phase == .confirming { model.cancelConfirmation() }
                    if showRecovery { showRecovery = false }
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model, showRecovery: $showRecovery)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("AI工具清理大师", systemImage: "leaf.fill").font(.headline).padding(.bottom, 24)
                    ForEach(["项目清理", "应用与缓存", "扫描范围", "空间浏览", "历史与恢复"], id: \.self) { name in
                        Button { section = name } label: {
                            Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(section == name ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text("只读扫描 · 逐项确认").font(.caption2).foregroundStyle(.secondary)
                }.padding(16).frame(width: 170).background(Color.primary.opacity(0.025))
                Divider()
                Group {
                if section == "空间浏览" && model.canEditScope {
                    SpaceBrowserView(model: model, showRules: { section = "项目清理" })
                } else if section == "历史与恢复" && model.canEditScope {
                    RecoveryView(model: model, onClose: { section = "项目清理" }, embedded: true)
                } else if section == "扫描范围" && model.canEditScope {
                    ScanScopeView(model: model)
                } else {
                switch model.phase {
                case .idle:
                    VStack { Spacer(); Button("开始扫描") { model.startScan() }; Spacer() }
                case .scanning:
                    ScanningView(model: model)
                case .ready, .confirming:
                    PlanView(model: model, projects: section != "应用与缓存")
                case .executing:
                    ExecutingView(model: model)
                case .finished:
                    ResultView(model: model, showRecovery: $showRecovery)
                }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1060, minHeight: 680)
        .tint(Color(red: 0.18, green: 0.42, blue: 0.32))
        .onChange(of: model.phase) { phase in
            if phase == .scanning { section = "项目清理" }
        }
        .sheet(item: activeSheet) { kind in
            switch kind {
            case .confirm:
                if let summary = model.confirmation {
                    ConfirmView(summary: summary, onCancel: model.cancelConfirmation, onStart: model.startClean(consentedApps:))
                }
            case .recovery:
                RecoveryView(model: model, onClose: { showRecovery = false })
            }
        }
        .alert(model.message ?? "", isPresented: Binding(
            get: { model.message != nil && activeSheet.wrappedValue == nil },
            set: { if !$0 { model.clearMessage() } })) {
            Button("好") { model.clearMessage() }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var model: AppModel
    @Binding var showRecovery: Bool

    var body: some View {
        HStack(spacing: 16) {
            if let disk = model.scanResult?.disk { DiskSummaryView(disk: disk) }
            if let date = model.scanResult?.generatedAt {
                Text("上次成功扫描：\(Format.relative(date, now: Date()))\(model.requiresRescan ? " · 结果待更新" : "")").foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新扫描") { model.startScan() }
                .disabled(model.phase == .scanning || model.phase == .executing || model.phase == .confirming || model.recoveryBusy)
            Button("恢复区 \(Format.bytes(model.recovery.totalBytes))") { showRecovery = true }
        }
        .padding(12)
    }
}

struct DiskSummaryView: View {
    let disk: DiskSummary

    var body: some View {
        let used = disk.totalBytes - disk.freeBytes
        VStack(alignment: .leading, spacing: 4) {
            Text("已用 \(Format.bytes(used)) / \(Format.bytes(disk.totalBytes))")
            ProgressView(value: Double(used), total: Double(max(disk.totalBytes, 1))).frame(width: 220)
            Text("可用 \(Format.bytes(disk.freeBytes))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScanningView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.scanStep?.title ?? "正在扫描…")
            Text("已发现 \(model.scanPreview.count) 项；完整检查前不可选择或清理。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.scanPreview.prefix(100)) { item in
                        HStack {
                            Text(item.app + " / " + item.title).lineLimit(1)
                            Spacer()
                            Text("待验证").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: 700, maxHeight: 260)
            Button("取消") { model.cancelScan() }
        }
    }
}
