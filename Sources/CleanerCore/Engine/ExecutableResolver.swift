import Foundation

/// 在固定目录中查找命令。菜单栏应用继承的 PATH 不完整，不能依赖它。
/// 用户可写目录故意排在系统目录之前（与登录 shell 的 PATH 顺序一致）；
/// 能 resolve 到路径不代表它是系统自带二进制。
public struct ExecutableResolver {
    public let files: FileOperations

    public init(files: FileOperations) { self.files = files }

    public func searchDirectories() -> [String] {
        let home = files.homeDirectory()
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin", home + "/.cargo/bin"]
        if let versions = try? files.childrenOfDirectory(atPath: home + "/.nvm/versions/node") {
            dirs += Self.sortedByVersionDescending(versions).map { $0 + "/bin" }
        }
        return dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// 解析末段形如 `vMAJOR.MINOR.PATCH` 的版本号，新到旧排序；解析不了的名字保持原有相对顺序排在最后。
    static func sortedByVersionDescending(_ paths: [String]) -> [String] {
        var parsed: [(path: String, version: (Int, Int, Int))] = []
        var unparsed: [String] = []
        for path in paths {
            if let version = parseVersion(path) {
                parsed.append((path, version))
            } else {
                unparsed.append(path)
            }
        }
        parsed.sort { isNewer($0.version, $1.version) }
        return parsed.map { $0.path } + unparsed
    }

    private static func parseVersion(_ path: String) -> (Int, Int, Int)? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("v") else { return nil }
        let parts = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        return (major, minor, patch)
    }

    private static func isNewer(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 > b.0 }
        if a.1 != b.1 { return a.1 > b.1 }
        return a.2 > b.2
    }

    /// 没装命令行工具时，/usr/bin 下这几个只是弹出安装对话框的占位程序，运行即打扰用户。
    static let commandLineToolShims: Set<String> = ["git", "pip3", "python3"]

    func commandLineToolsInstalled() -> Bool {
        files.fileExists("/Library/Developer/CommandLineTools/usr/bin/git")
            || files.fileExists("/Applications/Xcode.app/Contents/Developer/usr/bin/git")
    }

    func isShim(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return (path as NSString).deletingLastPathComponent == "/usr/bin"
            && Self.commandLineToolShims.contains(name) && !commandLineToolsInstalled()
    }

    /// 候选算作找到：本身是常规文件；或是符号链接且解析后的目标存在且是常规文件。
    /// 坏链接、指向目录的链接一律跳过，好让后面的目录有机会命中。
    func isUsableExecutable(_ path: String) -> Bool {
        guard let attributes = files.attributesIfExist(atPath: path) else { return false }
        if attributes.isRegularFile { return true }
        guard attributes.isSymbolicLink, let resolved = files.realPath(ofPath: path) else { return false }
        return files.attributesIfExist(atPath: resolved)?.isRegularFile == true
    }

    /// 绝对路径原样校验存在；裸命令名按固定目录查找；含 / 的相对路径一律拒绝。
    public func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") {
            let normalized = PathSafety.normalize(name, home: files.homeDirectory())
            return isUsableExecutable(normalized) && !isShim(normalized) ? normalized : nil
        }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in searchDirectories() {
            let candidate = dir + "/" + name
            if isShim(candidate) { continue }
            if isUsableExecutable(candidate) { return candidate }
        }
        return nil
    }
}
