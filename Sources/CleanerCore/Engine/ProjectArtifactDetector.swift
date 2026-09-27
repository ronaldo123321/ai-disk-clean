import Foundation

/// 按项目聚合 node_modules、.venv 等产物，按最后活跃时间分档。
/// 最后活跃 = git 最后提交、.git/index、.git/HEAD 修改时间、源码（项目根及下一层，排除产物目录）修改时间、
/// 以及每个产物所在父目录（及其直属普通文件）的修改时间，取其中最新者。
public struct ProjectArtifactDetector: Detector {
    public static let artifactNames: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".nuxt", "dist", "build", "coverage", "__pycache__",
        ".turbo", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".ruff_cache", "Pods", "DerivedData", ".gradle"]
    /// 这些名字太常见，同级必须有对应生态的工程标记文件才算产物；未列出的名字不需要标记。
    static let artifactMarkers: [String: [String]] = [
        "target": ["Cargo.toml", "pom.xml"],
        "build": ["build.gradle", "build.gradle.kts", "package.json", "pyproject.toml", "setup.py", "CMakeLists.txt"],
        "dist": ["package.json", "pyproject.toml", "setup.py"],
        "coverage": ["package.json", "pyproject.toml"],
    ]
    /// 依赖类产物：必须能在自身父目录或项目根找到 lockfile，否则降档。构建/缓存类产物不需要。
    static let dependencyArtifactNames: Set<String> = ["node_modules", ".venv", "venv", "Pods"]
    /// 缓存类产物：体积小、分散在多层子包里，可以按最近的工程标记文件向上聚合到同一个项目。
    /// 依赖/构建类产物不参与这种聚合——避免把无关子项目误聚到共同的上级标记目录。
    static let cacheArtifactNames: Set<String> = [
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".turbo", ".parcel-cache"]
    static let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "uv.lock",
                            "poetry.lock", "Pipfile.lock", "requirements.txt", "Cargo.lock", "Podfile.lock", "pom.xml",
                            "build.gradle", "build.gradle.kts", "go.sum"]
    static let skippedHomeChildren: Set<String> = [
        "Library", "Applications", "Movies", "Music", "Pictures", "Public", "Downloads",
        "miniconda3", "anaconda3", "miniforge3", "flutter", "go", "google-cloud-sdk", "n"]
    /// 找不到 .git 时，缓存类产物用来识别「非 git 项目根」的标记文件：lockfile 与各生态的产物标记文件之外，
    /// 再加上常见的工程清单文件。
    static let projectMarkers: Set<String> = Set(lockfiles)
        .union(artifactMarkers.values.flatMap { $0 })
        .union(["go.mod", "Podfile"])

    public var maxDepth = 6
    public var suggestAfterDays = 90
    public var confirmAfterDays = 30
    public var name: String { "项目" }

    public init() {}

    public func detect(_ context: DetectContext) -> [CleanItem] {
        let gitPath = ExecutableResolver(files: context.files).resolve("git")
        var byProject: [String: [String]] = [:]
        for artifact in findArtifacts(context) {
            let root = projectRoot(of: artifact, context)
            // ~ 下直接散落的产物（如 ~/venv）不属于任何项目，不当项目处理。
            guard root != context.home else { continue }
            byProject[root, default: []].append(artifact)
        }
        var items: [CleanItem] = []
        for root in byProject.keys.sorted() {
            if context.isCancelled { break }
            if let item = makeItem(root: root, artifacts: byProject[root]!.sorted(), gitPath: gitPath, context) {
                items.append(item)
            }
        }
        return items
    }

    func findArtifacts(_ context: DetectContext) -> [String] {
        var found: [String] = []
        let forbiddenRoots = context.safety.treeForbiddenRoots
        var stack: [(String, Int)] = [(context.home, 0)]
        while let entry = stack.popLast() {
            if context.isCancelled { break }
            let (dir, depth) = entry
            guard depth < maxDepth, let children = try? context.files.childrenOfDirectory(atPath: dir) else { continue }
            for child in children {
                let name = (child as NSString).lastPathComponent
                guard let attributes = context.files.attributesIfExist(atPath: child),
                      attributes.isDirectory, !attributes.isSymbolicLink else { continue }
                // 家目录下的隐藏目录是各工具自己的安装与数据目录（如 ~/.hermes、~/.nvm），不当项目处理
                if depth == 0 && (name.hasPrefix(".") || Self.skippedHomeChildren.contains(name)) { continue }
                if name == ".git" || name.hasSuffix(".app") { continue }
                if forbiddenRoots.contains(where: { PathSafety.isInside(child, root: $0) }) { continue }
                if Self.artifactNames.contains(name) {
                    // 全局 npm 前缀（如 ~/tools/node/lib/node_modules）不是某个项目的依赖目录。
                    if name == "node_modules" && isGlobalNpmPrefix(dir, context) { continue }
                    if let markers = Self.artifactMarkers[name] {
                        let hasMarker = markers.contains { context.files.fileExists(dir + "/" + $0) }
                        if !hasMarker {
                            stack.append((child, depth + 1))
                            continue
                        }
                    }
                    found.append(child)
                    continue
                }
                stack.append((child, depth + 1))
            }
        }
        return found
    }

    /// 全局 npm 安装前缀形如 <prefix>/lib/node_modules，旁边不会有 package.json。
    func isGlobalNpmPrefix(_ dir: String, _ context: DetectContext) -> Bool {
        (dir as NSString).lastPathComponent == "lib" && !context.files.fileExists(dir + "/package.json")
    }

    /// 向上找最近的 git 仓库根；找不到时，缓存类产物再向上找最近的含工程标记文件的目录（但不取家目录的
    /// 直接子目录，太浅的标记目录很可能是无关子项目共同的上级容器，不该把散落各处的缓存都聚过去）；
    /// 依赖/构建类产物不做这一步聚合，直接以产物所在目录为项目，避免误聚到无关子项目。
    func projectRoot(of artifact: String, _ context: DetectContext) -> String {
        let parent = (artifact as NSString).deletingLastPathComponent
        var current = parent
        while current != context.home && PathSafety.isInside(current, root: context.home) {
            if context.files.fileExists(current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        let name = (artifact as NSString).lastPathComponent
        guard Self.cacheArtifactNames.contains(name) else { return parent }
        current = parent
        while current != context.home && PathSafety.isInside(current, root: context.home) {
            let isDirectHomeChild = (current as NSString).deletingLastPathComponent == context.home
            if !isDirectHomeChild, Self.projectMarkers.contains(where: { context.files.fileExists(current + "/" + $0) }) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return parent
    }

    func makeItem(root: String, artifacts: [String], gitPath: String?, _ context: DetectContext) -> CleanItem? {
        let allowed = artifacts.filter {
            (try? context.safety.assertAllowed($0)) != nil && EnginePathChecks.isCanonical($0, files: context.files)
        }
        guard !allowed.isEmpty else { return nil }

        let hasGitDir = context.files.fileExists(root + "/.git")
        // 不执行任何 git 命令：最后提交时间直接读 reflog 文件。
        let lastCommit = hasGitDir ? lastCommitDateFromReflog(root, context) : nil
        // .git 存在但读不到最后提交（reflog 缺失/损坏、空仓库）：只能按文件修改时间估计，不给出「建议」档的确定性。
        let gitDirWithoutCommit = hasGitDir && lastCommit == nil

        let gitIndexMtime = context.files.attributesIfExist(atPath: root + "/.git/index")?.modificationDate
        let gitHeadMtime = context.files.attributesIfExist(atPath: root + "/.git/HEAD")?.modificationDate

        let candidates: [Date?] = [
            lastCommit, newestSourceModification(root, context), gitIndexMtime, gitHeadMtime,
            artifactParentActivity(allowed, context),
        ]
        guard let lastActive = candidates.compactMap({ $0 }).max() else { return nil }

        let idleDays = Int(context.now.timeIntervalSince(lastActive) / 86_400)

        let dependencyArtifacts = allowed.filter { Self.dependencyArtifactNames.contains(($0 as NSString).lastPathComponent) }
        // 非 git 项目根：只看产物自己的父目录（marker 聚合不适用于依赖类产物，父目录即产物实际所在处）；
        // git 项目根沿用旧口径，父目录或项目根任一处有 lockfile 即可。
        let hasLockfile = dependencyArtifacts.allSatisfy { artifact in
            let artifactParent = (artifact as NSString).deletingLastPathComponent
            let dirsToCheck = hasGitDir ? [artifactParent, root] : [artifactParent]
            return dirsToCheck.contains { dir in
                Self.lockfiles.contains { context.files.fileExists(dir + "/" + $0) }
            }
        }

        var tier: CleanTier
        if idleDays >= suggestAfterDays {
            tier = hasLockfile ? .suggested : .confirm
        } else if idleDays >= confirmAfterDays {
            tier = .confirm
        } else {
            return nil
        }
        if gitDirWithoutCommit && tier == .suggested {
            tier = .confirm
        }
        // build 仅靠 package.json 判定（可能是 Electron 之类工具的源资源目录），需要用户确认。
        let buildOnlyPackageJson = allowed.contains { buildMarkedOnlyByPackageJson($0, context) }
        if buildOnlyPackageJson && tier == .suggested {
            tier = .confirm
        }

        let name = (root as NSString).lastPathComponent
        var notes = ["闲置 \(idleDays) 天"]
        if !hasLockfile { notes.append("未找到 lockfile，重建后依赖版本可能变化") }
        if gitDirWithoutCommit { notes.append("无法读取 git 提交时间，按文件修改时间估计") }
        if buildOnlyPackageJson { notes.append("build 目录可能含 Electron 等工具的源资源，请确认后再清理") }
        // 只对最终会展示的项才查未提交改动，且只在确认本地没有会执行任意命令的 clean/smudge 过滤器时才跑，
        // 避免为被过滤掉的新鲜项目白跑一次 git status，也避免触发仓库配置的过滤器命令。
        if hasGitDir, let gitPath, isStatusSafe(root, git: gitPath, context),
           let dirty = dirtyCount(root, git: gitPath, context), dirty > 0 {
            notes.append("源码有 \(dirty) 处未提交改动（本次只清理依赖与构建产物，不影响源码）")
        }
        let kinds = Set(allowed.map { ($0 as NSString).lastPathComponent }).sorted().joined(separator: "、")
        return CleanItem(
            id: "project:" + root, app: "项目：" + name, category: .dev, tier: tier,
            title: "项目 \(name) 的依赖与构建产物", paths: allowed, action: .recover, preconditions: .empty,
            copy: RuleCopy(what: "\(kinds)，共 \(allowed.count) 个目录",
                           impact: "删后需在项目内重新安装依赖或重新构建（如 uv sync、npm i）", regrows: nil),
            notes: notes)
    }

    /// 直接读 `.git/logs/HEAD` 拿最后一次提交时间，不执行任何 git 命令。
    /// 行格式：`<old> <new> <name> <<email>> <unix-ts> <tz>\t<message>`；取 tab 之前部分按空格切分的倒数第二段。
    func lastCommitDateFromReflog(_ root: String, _ context: DetectContext) -> Date? {
        guard context.files.attributesIfExist(atPath: root + "/.git")?.isDirectory == true else { return nil }
        let path = root + "/.git/logs/HEAD"
        guard let attributes = context.files.attributesIfExist(atPath: path),
              attributes.isRegularFile, !attributes.isSymbolicLink,
              let data = context.files.readFile(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = text.split(separator: "\n", omittingEmptySubsequences: true).last else { return nil }
        let prePart = lastLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let tokens = prePart.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2, let seconds = TimeInterval(tokens[tokens.count - 2]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 仅在确认本地/工作树没有配置 clean/smudge 之类过滤器时才跑 status：这类过滤器可执行仓库指定的任意命令。
    /// 全局/系统级过滤器（如用户自己装的 git-lfs）视为可信，不拦。
    func isStatusSafe(_ root: String, git: String, _ context: DetectContext) -> Bool {
        guard let result = context.runner.run(launchPath: git, arguments: [
            "--no-optional-locks", "-C", root, "config", "--show-scope", "--get-regexp", "^filter\\.",
        ]) else { return false }
        if result.exitStatus == 1, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard result.exitStatus == 0 else { return false }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        return !lines.contains { $0.hasPrefix("local") || $0.hasPrefix("worktree") }
    }

    func dirtyCount(_ root: String, git: String, _ context: DetectContext) -> Int? {
        guard let result = context.runner.run(launchPath: git, arguments: [
            "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
            "-C", root, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules",
        ]), result.exitStatus == 0 else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).count
    }

    /// build 目录如果只是靠 package.json 判定为产物（旁边没有其它构建生态的标记文件），
    /// 可能是 Electron 应用打包携带的源资源，不能直接当构建缓存清理。
    func buildMarkedOnlyByPackageJson(_ artifact: String, _ context: DetectContext) -> Bool {
        guard (artifact as NSString).lastPathComponent == "build" else { return false }
        let dir = (artifact as NSString).deletingLastPathComponent
        guard context.files.fileExists(dir + "/package.json") else { return false }
        let otherMarkers = (Self.artifactMarkers["build"] ?? []).filter { $0 != "package.json" }
        return !otherMarkers.contains { context.files.fileExists(dir + "/" + $0) }
    }

    /// 每个产物所在父目录本身、以及父目录里直属的普通文件（不下钻、不跟随符号链接）的修改时间中最新者。
    /// 用来兜住深层子包里紧挨着产物的最近编辑（如 pkg/a/x.py 与 pkg/a/__pycache__ 同级），
    /// newestSourceModification 只扫项目根下一层，够不到这么深。
    func artifactParentActivity(_ artifacts: [String], _ context: DetectContext) -> Date? {
        var newest: Date?
        var visitedParents = Set<String>()
        for artifact in artifacts {
            let parent = (artifact as NSString).deletingLastPathComponent
            guard visitedParents.insert(parent).inserted else { continue }
            if let attributes = context.files.attributesIfExist(atPath: parent), !attributes.isSymbolicLink,
               let modified = attributes.modificationDate {
                newest = max(newest ?? modified, modified)
            }
            guard let children = try? context.files.childrenOfDirectory(atPath: parent) else { continue }
            for child in children {
                guard let attributes = context.files.attributesIfExist(atPath: child), !attributes.isSymbolicLink,
                      attributes.isRegularFile, let modified = attributes.modificationDate else { continue }
                newest = max(newest ?? modified, modified)
            }
        }
        return newest
    }

    func newestSourceModification(_ root: String, _ context: DetectContext) -> Date? {
        var newest: Date?
        var stack: [(String, Int)] = [(root, 0)]
        while let entry = stack.popLast() {
            if context.isCancelled { break }
            let (dir, depth) = entry
            guard let children = try? context.files.childrenOfDirectory(atPath: dir) else { continue }
            for child in children {
                let name = (child as NSString).lastPathComponent
                guard let attributes = context.files.attributesIfExist(atPath: child), !attributes.isSymbolicLink else { continue }
                if attributes.isDirectory {
                    guard !Self.artifactNames.contains(name), name != ".git" else { continue }
                    if let modified = attributes.modificationDate {
                        newest = max(newest ?? modified, modified)
                    }
                    if depth < 1 { stack.append((child, depth + 1)) }
                } else if let modified = attributes.modificationDate {
                    newest = max(newest ?? modified, modified)
                }
            }
        }
        return newest
    }
}
