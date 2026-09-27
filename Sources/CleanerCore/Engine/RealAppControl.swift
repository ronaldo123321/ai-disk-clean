#if canImport(AppKit)
import AppKit
import Darwin

public final class RealAppControl: AppControl {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        !pids(bundleID).isEmpty
    }

    public func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let targetPIDs = apps.map(\.processIdentifier)
        guard !apps.isEmpty else { return true }
        let accepted = apps.map { $0.terminate() }
        guard accepted.contains(true) else { return false }
        return waitUntilGone(targetPIDs, timeout: timeout)
    }

    public func forceQuit(bundleID: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let targetPIDs = apps.map(\.processIdentifier)
        guard !apps.isEmpty else { return true }
        apps.forEach { _ = $0.forceTerminate() }
        return waitUntilGone(targetPIDs, timeout: 5)
    }

    private func pids(_ bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
            .filter(isAlive) // 列表同样依赖 run loop 刷新，以进程实际存活为准
    }

    /// 轮询已捕获的 PID 是否仍存活，不重新查询 NSRunningApplication——
    /// 其状态依赖主 run loop 刷新，CLI 场景下不会转起来。
    private func waitUntilGone(_ pids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !pids.contains(where: isAlive) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !pids.contains(where: isAlive)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
#endif
