import AppKit
import Combine
import SwiftUI
import AppCore

@main
struct DiskCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// 菜单栏图标用 NSStatusItem（MenuBarExtra 在 macOS 26 上曾不显示图标）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["DCLEAN_UI_TEST_HOME"] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let parent = url.deletingLastPathComponent()
            // Explicit debug-only, freshly generated fixture; never fall back to the real home.
            let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
            precondition(parent.deletingLastPathComponent().path == temporaryRoot.path
                         && parent.lastPathComponent.hasPrefix("dclean-ui-") && url.lastPathComponent == "home"
                         && FileManager.default.fileExists(atPath: parent.appendingPathComponent(".ui-fixture").path))
            return AppModel(engine: LiveEngineService(homeOverride: url.path), preferences: nil)
        }
        #endif
        return AppModel(engine: LiveEngineService(), preferences: .standard)
    }()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "清"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        updateStatusTitle()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            model: model,
            openMain: { [weak self] in self?.showMainWindow() },
            openMainAndClean: { [weak self] in
                self?.showMainWindow()
                self?.model.requestClean(useDefaultSelection: true)
            }))
        // objectWillChange 在属性变化之前触发，下一轮主循环再读取新值
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusTitle() } }
            .store(in: &cancellables)
        model.startScan()
        model.refreshRecovery()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.canTerminate else { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)   // 从程序坞退出时应用可能不在前台
        let alert = NSAlert()
        alert.messageText = "正在清理，不能退出"
        alert.informativeText = "正在清理，请先点「停止」并等当前项完成后再退出"
        alert.runModal()
        return .terminateCancel
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showMainWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "AI工具清理大师"
            #if DEBUG
            if ProcessInfo.processInfo.environment["DCLEAN_UI_TEST_HOME"] != nil { w.title = "AI工具清理大师 · 临时目录验收" }
            #endif
            w.isReleasedWhenClosed = false   // 关闭只是隐藏，执行在后台继续
            w.contentView = NSHostingView(rootView: MainView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateStatusTitle() {
        let meaning: String
        switch model.phase {
        case .executing:
            statusItem.button?.title = "清 \(model.progress.finished.count)/\(model.progress.total)"
            meaning = "正在清理 \(model.progress.finished.count)/\(model.progress.total)"
        case .scanning:
            statusItem.button?.title = "清 …"
            meaning = "正在扫描"
        default:
            if let disk = model.scanResult?.disk, disk.totalBytes > 0 {
                let used = Double(disk.totalBytes - disk.freeBytes) / Double(disk.totalBytes)
                let percent = Int((used * 100).rounded())
                statusItem.button?.title = "清 \(percent)%"
                meaning = "磁盘已用 \(percent)%"
            } else {
                statusItem.button?.title = "清"
                meaning = "未扫描"
            }
        }
        let label = "AI工具清理大师，\(meaning)"
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }
}
