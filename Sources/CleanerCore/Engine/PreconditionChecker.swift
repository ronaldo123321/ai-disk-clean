import Foundation

/// 当前能否处理：应用是否在运行、锁文件是否被占用。扫描时用于展示，执行前再查一次。
public struct PreconditionChecker {
    public let apps: AppControl
    public let guards: GuardEvaluator
    public let home: String

    public init(apps: AppControl, guards: GuardEvaluator, home: String) {
        self.apps = apps
        self.guards = guards
        self.home = home
    }

    public func blockers(for item: CleanItem) -> [Blocker] {
        var blockers: [Blocker] = []
        for app in item.preconditions.quitApps ?? [] where apps.isRunning(bundleID: app.bundleID) {
            blockers.append(.appRunning(name: app.name, bundleID: app.bundleID))
        }
        for lock in item.preconditions.lockfiles ?? [] {
            let status = guards.status(of: [GuardSpec(type: .lockfile, path: lock)], home: home)
            switch status {
            case .clear:
                continue
            case .blocked(let occupiers):
                blockers.append(.occupied(occupiers.map(\.description).joined(separator: ", ")))
            case .unknown(let reason):
                blockers.append(.unavailable("无法确认是否被占用：" + reason))
            }
        }
        return blockers
    }
}
