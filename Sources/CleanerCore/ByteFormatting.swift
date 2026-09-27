import Foundation

// MARK: - 磁盘字节的人类可读格式

public enum ByteFormatting {
    public static func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units: [(String, Int64)] = [("B", 1), ("KB", 1 << 10), ("MB", 1 << 20), ("GB", 1 << 30), ("TB", 1 << 40)]
        var name = "B"
        var factor: Int64 = 1
        for unit in units where bytes >= unit.1 {
            name = unit.0
            factor = unit.1
        }
        let value = Double(bytes) / Double(factor)
        if factor == 1 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, name)
    }
}
