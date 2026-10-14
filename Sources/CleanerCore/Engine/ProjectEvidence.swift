import Foundation
import CryptoKit

/// Metadata evidence, not a backup or a full content hash. Unknown is never permission to clean.
public struct ProjectEvidence: Codable, Equatable, Sendable {
    public var digest: String
    public var capturedAt: Date
    public var rootIdentity: FileAttributes
}

public struct ProjectProtectionError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

enum ProjectProtection {
    static func capture(root: String, artifact: String, files: FileOperations, runner: ProcessRunner,
                        now: Date, cancellation: OperationCancellation? = nil) throws -> ProjectEvidence {
        guard PathSafety.isInside(artifact, root: root), artifact != root,
              EnginePathChecks.isCanonical(artifact, files: files) else {
            throw ProjectProtectionError("产物归属或真实路径无法验证")
        }
        guard let rootIdentity = files.attributesIfExist(atPath: artifact), rootIdentity.isDirectory,
              !rootIdentity.isSymbolicLink else { throw ProjectProtectionError("产物已不存在或不再是真实目录") }
        let parent = (artifact as NSString).deletingLastPathComponent
        let kind = (artifact as NSString).lastPathComponent
        if let markers = ProjectArtifactDetector.artifactMarkers[kind],
           !markers.contains(where: { files.fileExists(parent + "/" + $0) }) {
            throw ProjectProtectionError("工程标记已不存在，请重新扫描")
        }
        if files.fileExists(root + "/.git") {
            guard let git = ExecutableResolver(files: files).resolve("git"),
                  let result = runner.run(launchPath: git, arguments: [
                    "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                    "-C", root, "ls-files", "--cached", "-z", "--", String(artifact.dropFirst(root.count + 1))
                  ]), result.exitStatus == 0 else {
                throw ProjectProtectionError("无法验证 Git 跟踪内容，保持原位")
            }
            guard result.stdout.isEmpty else { throw ProjectProtectionError("产物内含 Git 跟踪内容，已保护") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        let context = DetectContext(files: files, safety: PathSafety(home: files.homeDirectory(), files: files), runner: runner, now: now, cancellation: cancellation)
        // Source edits outside the artifact also invalidate an idle-project decision.
        let sourceDate = ProjectArtifactDetector().newestSourceModification(root, context)
        guard context.diagnostics.issues.isEmpty else { throw ProjectProtectionError("源码活跃状态无法完整验证，保持原位") }
        hash.update(data: try encoder.encode(sourceDate))
        // Include project markers, lockfiles and git identity; absence is also evidence.
        for dir in Set([root, parent]).sorted() {
            for name in ProjectArtifactDetector.projectMarkers.union([".git", ".git/index", ".git/HEAD", ".git/logs/HEAD"]).sorted() {
                let path = dir + "/" + name
                hash.update(data: Data(path.utf8))
                if let attributes = files.attributesIfExist(atPath: path) {
                    guard !attributes.isSymbolicLink else { throw ProjectProtectionError("工程标记是符号链接，无法验证") }
                    hash.update(data: try encoder.encode(attributes))
                }
            }
        }
        var stack = [artifact]
        var count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let sourceExtensions: Set<String> = ["swift", "rs", "go", "py", "ts", "tsx", "jsx", "vue", "c", "cpp", "h", "java", "kt"]
        while let path = stack.popLast() {
            count += 1
            guard cancellation?.isCancelled != true, count <= 300_000,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProjectProtectionError("内容验证未完成（取消或超过检查上限），保持原位")
            }
            guard let a = files.attributesIfExist(atPath: path) else {
                throw ProjectProtectionError("内容读取失败或扫描中变化：" + path)
            }
            let name = (path as NSString).lastPathComponent.lowercased()
            if path != artifact && (name == ".git" || name == ".env" || name.hasPrefix(".env.")
                || name.contains("keypair") || name == "id_rsa" || name == "id_ed25519"
                || ["pem", "key", "p12", "pfx"].contains((name as NSString).pathExtension)) {
                throw ProjectProtectionError("发现仓库、环境配置或密钥，已保护：" + name)
            }
            if ["build", "dist", "target"].contains(kind), a.isRegularFile,
               sourceExtensions.contains((name as NSString).pathExtension) {
                throw ProjectProtectionError("构建目录含可能的源码，已保护：" + name)
            }
            hash.update(data: Data((path + "\u{0}").utf8))
            hash.update(data: try encoder.encode(a))
            if a.isDirectory && !a.isSymbolicLink {
                do { stack.append(contentsOf: try files.childrenOfDirectory(atPath: path).sorted().reversed()) }
                catch { throw ProjectProtectionError("目录无法完整读取：" + path) }
            }
        }
        guard let finalIdentity = files.attributesIfExist(atPath: artifact), rootIdentity.matches(finalIdentity) else {
            throw ProjectProtectionError("验证期间目录发生变化，保持原位")
        }
        return ProjectEvidence(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), capturedAt: now, rootIdentity: rootIdentity)
    }
}
