import Foundation

/// 平台层：应用运行状态与退出。Windows 版替换实现即可。
public protocol AppControl: AnyObject {
    func isRunning(bundleID: String) -> Bool
    /// 正常退出（等同用户按 ⌘Q），等待至多 timeout 秒；返回是否已退出。
    /// 会阻塞调用线程直至超时或应用退出；在 GUI 应用中请勿在主线程调用。
    func requestQuit(bundleID: String, timeout: TimeInterval) -> Bool
    /// 强制结束。只能在用户对该应用单独确认后调用。
    /// 会阻塞调用线程直至超时或应用退出；在 GUI 应用中请勿在主线程调用。
    func forceQuit(bundleID: String) -> Bool
}
