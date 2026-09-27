import Foundation

/// 新引擎的数据目录。用户保护位置与操作锁仍在 V2Paths（~/.dclean-v2），新旧界面共用一把锁。
public enum EnginePaths {
    public static let directoryName = ".dclean-v3"

    public static func dataDirectory(home: String) -> String { home + "/" + directoryName }
    public static func recoveryDirectory(home: String) -> String { dataDirectory(home: home) + "/recovery" }
    public static func auditLog(home: String) -> String { dataDirectory(home: home) + "/audit.log" }
    public static func userRules(home: String) -> String { dataDirectory(home: home) + "/user-rules.json" }
}
