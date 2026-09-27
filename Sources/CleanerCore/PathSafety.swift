import Foundation
import Darwin

// MARK: - PathSafety：spec §5 的第 2、3、4、5 层

public enum PathSafetyError: Error, CustomStringConvertible, Equatable {
    case forbiddenExact(String)
    case forbiddenTree(String)
    case escapedFence(candidate: String, resolvedRoot: String)
    case outsideAllRoots(candidate: String, roots: [String])
    case candidateMissing(String)
    case tooShallow(String, depth: Int)

    public var description: String {
        switch self {
        case .forbiddenExact(let p):
            return "\(p) 是硬编码禁区（精确匹配）"
        case .forbiddenTree(let p):
            return "\(p) 位于整棵树禁区或 .git 目录内"
        case .escapedFence(let c, let root):
            return "\(c) 经符号链接解析后逃逸出规则根 \(root)"
        case .outsideAllRoots(let c, let roots):
            return "\(c) 不在任何规则根 \(roots.joined(separator: ", ")) 之内"
        case .candidateMissing(let p):
            return "\(p) 已不存在"
        case .tooShallow(let p, let d):
            return "\(p) 路径深度仅 \(d) 层（要求 ≥ 3），疑似变量为空拼接"
        }
    }
}

public enum FenceResult: Equatable {
    /// 候选本身是符号链接：只删 link 本身，不触碰指向的目标（spec §5 第 4 层）
    case symlinkLeaf(resolved: String?)
    /// 常规路径，realpath 解析后仍在规则根内
    case insideRoot(resolved: String)
}

/// 全部为纯路径运算 + lstat/realpath，不产生任何写操作。
public final class PathSafety {
    public let home: String
    private let files: FileOperations
    /// 自定义保护位置的按实例缓存。assertAllowed 是逐路径调用的（识别时每个候选 1 次、
    /// 执行时每条路径复核），每次都读盘解 JSON 会让大批候选付出成千上万次文件读。
    /// 实例生命周期 = 一次扫描或一次执行（LiveEngineService 每次操作新建）。
    /// 只缓存成功结果：文件损坏时每次都重新抛错，保持失败关闭。
    private var cachedProtectedRoots: [String]?

    public init(home: String, files: FileOperations) {
        self.home = PathSafety.normalize(home, home: home)
        self.files = files
    }

    private func protectedRoots() throws -> [String] {
        if let cachedProtectedRoots { return cachedProtectedRoots }
        let roots = try ProtectedLocations(files: files).read()
        cachedProtectedRoots = roots
        return roots
    }

    // MARK: 禁区清单（spec §5 第 3 层，2026-09-17 修订：两分类匹配）

    /// 精确匹配：路径本身等于禁区才命中，后代不受影响。
    public var exactForbiddenPaths: [String] {
        ["/", "/Users", home]
    }

    /// 整棵树禁止：该目录及其所有后代都命中。
    public var treeForbiddenRoots: [String] {
        ["/System",
         home + "/Documents",
         home + "/Desktop",
         home + "/Pictures",
         home + "/.ssh",
         home + "/.gnupg",
         home + "/Library/Keychains",
         home + "/.codex/sessions", home + "/.codex/memories",
         home + "/.claude/projects", home + "/.claude/plugins",
         home + "/Library/Mobile Documents", home + "/Library/CloudStorage",
         home + "/" + V2Paths.directoryName, home + "/" + EnginePaths.directoryName]
    }

    // MARK: 路径展开与规范化

    /// 展开 ~ 与 ~/（不支持 ~user）。
    public func expandTilde(_ raw: String) -> String {
        Self.expandTilde(raw, home: home)
    }

    /// 纯词法规范化：合并 `.`、解析 `..`、去掉多余斜杠。不解析符号链接。
    public func normalize(_ raw: String) -> String {
        Self.normalize(raw, home: home)
    }

    /// 路径组件数（不含根 "/"；"/" 为 0）。
    public func depth(of normalizedPath: String) -> Int {
        Self.depth(of: normalizedPath)
    }

    public func isInside(_ path: String, root: String) -> Bool {
        Self.isInside(path, root: root)
    }

    // MARK: 纯函数版本（无实例状态依赖）

    public static func expandTilde(_ raw: String, home: String) -> String {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + raw.dropFirst() }
        return raw
    }

    public static func normalize(_ raw: String, home: String) -> String {
        let expanded = expandTilde(raw, home: home)
        let isAbsolute = expanded.hasPrefix("/")
        var stack: [String] = []
        for comp in expanded.split(separator: "/") {
            switch comp {
            case ".":
                continue
            case "..":
                if !stack.isEmpty {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(String(comp))
                }
                // 绝对路径在根部再上跳仍留在根
            default:
                stack.append(String(comp))
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    public static func depth(of normalizedPath: String) -> Int {
        guard normalizedPath.hasPrefix("/") else { return 0 }
        return normalizedPath.split(separator: "/").count
    }

    public static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // MARK: 第 3 层：禁区断言（plan 与 apply 各跑一遍）

    /// 校验候选路径合法并返回规范化后的路径。命中禁区抛错（调用方据此 abort 整个计划）。
    @discardableResult
    public func assertAllowed(_ raw: String) throws -> String {
        let p = normalize(raw)
        if exactForbiddenPaths.contains(p) {
            throw PathSafetyError.forbiddenExact(p)
        }
        let custom = try protectedRoots()
        let resolved = files.realPath(ofPath: p) ?? p
        if custom.contains(where: { isInside(p, root: $0) || isInside($0, root: p) || isInside(resolved, root: $0) || isInside($0, root: resolved) }) {
            throw PathSafetyError.forbiddenTree(p)
        }
        if treeForbiddenRoots.contains(where: { isInside(p, root: $0) || isInside($0, root: p) || isInside(resolved, root: $0) }) {
            throw PathSafetyError.forbiddenTree(p)
        }
        if p.split(separator: "/").contains(".git") {
            throw PathSafetyError.forbiddenTree(p)
        }
        let d = depth(of: p)
        guard d >= 3 else {
            throw PathSafetyError.tooShallow(p, depth: d)
        }
        return p
    }

    // MARK: 第 2、4 层：围栏

    /// 候选必须词法上落在某个 root 内；随后：
    /// - 候选本身是符号链接 → 只删 link，放行（symlinkLeaf）；
    /// - 否则 realpath 全量解析（可暴露路径中段的目录符号链接），逃逸出根则抛错。
    public func checkFence(candidate: String, roots: [String]) throws -> FenceResult {
        let c = normalize(candidate)
        let normRoots = roots.map { normalize($0) }
        guard let root = normRoots.first(where: { isInside(c, root: $0) }) else {
            throw PathSafetyError.outsideAllRoots(candidate: c, roots: normRoots)
        }
        guard let attrs = files.attributesIfExist(atPath: c) else {
            throw PathSafetyError.candidateMissing(c)
        }
        if attrs.isSymbolicLink {
            return .symlinkLeaf(resolved: files.realPath(ofPath: c))
        }
        let resolvedCandidate = files.realPath(ofPath: c) ?? c
        let resolvedRoot = files.realPath(ofPath: root) ?? root
        guard isInside(resolvedCandidate, root: resolvedRoot) else {
            throw PathSafetyError.escapedFence(candidate: c, resolvedRoot: resolvedRoot)
        }
        return .insideRoot(resolved: resolvedCandidate)
    }
}

