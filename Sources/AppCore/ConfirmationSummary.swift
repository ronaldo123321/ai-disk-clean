import Foundation
import CleanerCore

public struct ConfirmationSummary: Equatable {
    public var items: [CleanItem]
    public var recoverable: [CleanItem]
    public var irreversible: [CleanItem]
    /// 正在运行、可由工具正常退出的应用
    public var appsWeCanQuit: [QuitApp]
    /// 正在运行、需要用户自己退出的应用（IDE、编辑器、Claude 等）
    public var appsUserMustQuit: [QuitApp]

    public var estimatedBytes: Int64 { items.reduce(0) { $0 + $1.reclaimableBytes } }
    public var immediateBytes: Int64 { irreversible.reduce(0) { $0 + $1.reclaimableBytes } }
    public var recoveryBytes: Int64 { recoverable.reduce(0) { $0 + $1.apparentBytes } }

    public static func make(items: [CleanItem], isRunning: (String) -> Bool) -> ConfirmationSummary {
        let actionable = items.filter { $0.tier != .displayOnly && $0.action.type != .noAction }
        var seen = Set<String>()
        var weQuit: [QuitApp] = []
        var userQuits: [QuitApp] = []
        for app in actionable.flatMap({ $0.preconditions.quitApps ?? [] }) {
            guard seen.insert(app.bundleID).inserted, isRunning(app.bundleID) else { continue }
            if app.canQuitForUser { weQuit.append(app) } else { userQuits.append(app) }
        }
        return ConfirmationSummary(items: actionable,
                                   recoverable: actionable.filter { $0.action.type != .command },
                                   irreversible: actionable.filter { $0.action.type == .command },
                                   appsWeCanQuit: weQuit, appsUserMustQuit: userQuits)
    }
}
