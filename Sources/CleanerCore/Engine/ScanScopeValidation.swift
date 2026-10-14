import Foundation

/// Scan roots are not deletion targets: Home itself is allowed, but its protected children remain protected.
public enum ScanScopeValidation {
    public static func validate(_ path: String, files: FileOperations) throws -> String {
        let home = PathSafety.normalize(files.homeDirectory(), home: files.homeDirectory())
        let selected = PathSafety.normalize(path, home: home)
        guard let attributes = files.attributesIfExist(atPath: selected), attributes.isDirectory,
              let resolved = files.realPath(ofPath: selected), let resolvedHome = files.realPath(ofPath: home) else {
            throw ValidationError("目录不存在或无法读取，请重新选择一个现有目录。")
        }
        guard !attributes.isSymbolicLink, alias(selected) == alias(resolved) else {
            throw ValidationError("不能通过符号链接选择扫描范围，请选择目录的实际位置。")
        }
        guard PathSafety.isInside(resolved, root: resolvedHome) else {
            throw ValidationError("所选目录不在当前允许的 Home 范围内。")
        }
        let normalized = home + resolved.dropFirst(resolvedHome.count)
        if normalized == home { return home }
        do { _ = try PathSafety(home: home, files: files).assertAllowed(normalized) }
        catch { throw ValidationError("此目录受保护、包含受保护位置，或保护配置无法确认。请选择其他工作目录。\n原因：\(error)") }
        return normalized
    }

    // macOS system aliases only; do not silently resolve arbitrary user-created links.
    private static func alias(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var"] where PathSafety.isInside(path, root: root) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    public struct ValidationError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
