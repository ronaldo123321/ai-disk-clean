import Foundation

/// 路径的任何一层都不能是符号链接：realpath 结果必须与路径本身一致（不区分大小写，允许 macOS 的 /private 前缀别名）。
enum EnginePathChecks {
    static func isCanonical(_ path: String, files: FileOperations) -> Bool {
        guard let resolved = files.realPath(ofPath: path)?.lowercased() else { return false }
        let expected = path.lowercased()
        return resolved == expected || resolved == "/private" + expected
    }
}
