import Foundation

/// V2 独立数据目录（单一来源，GUI/CLI/核心组件统一引用）。
/// 与 V1（master 分支构建，~/.dclean）隔离：V1 扫描会清除 7 天以上的隔离批次，
/// 而 V2 恢复中心保留 30 天且到期只提醒——共用目录会让 V1 提前物理删除 V2 的恢复中心批次。
public enum V2Paths {
    public static let directoryName = ".dclean-v2"

    public static func dataDirectory(home: String) -> String { home + "/" + directoryName }

    /// 当前用户的数据目录；缺失时创建（首次运行、锁文件写入前均安全）。
    @discardableResult
    public static func ensureDataDirectory(home: String, files: FileOperations) throws -> String {
        let directory = dataDirectory(home: home)
        try files.createDirectory(atPath: directory, intermediate: true)
        return directory
    }
}
