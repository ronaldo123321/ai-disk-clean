import SwiftUI
import CleanerCore
import AppCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showRecovery = false

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
            Group {
                switch model.phase {
                case .idle:
                    VStack { Spacer(); Button("开始扫描") { model.startScan() }; Spacer() }
                case .scanning:
                    ScanningView(model: model)
                case .ready, .confirming:
                    PlanView(model: model)
                case .executing:
                    ExecutingView(model: model)
                case .finished:
                    ResultView(model: model, showRecovery: $showRecovery)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
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
                Text("上次扫描：\(Format.relative(date, now: Date()))").foregroundStyle(.secondary)
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
            Button("取消") { model.cancelScan() }
        }
    }
}
