import Foundation

public struct LoadedRules: Sendable {
    public var rules: [CleanRule]
    public var problems: [String]
}

/// 解码单条规则时不让整份文件因为一条坏规则失败：解码错误被捕获为 `.failure`，调用方逐条上报。
private struct LossyRule: Decodable {
    let result: Result<CleanRule, Error>

    init(from decoder: Decoder) throws {
        do {
            result = .success(try CleanRule(from: decoder))
        } catch {
            result = .failure(error)
        }
    }
}

private struct RawRulePackFile: Decodable {
    var version: Int
    var platform: String
    var rules: [LossyRule]
}

/// 内置规则在前、自定义规则在后；不合格的规则逐条丢弃并报告，不影响其余规则。
public enum RulePack {
    /// 安装后的 .app 里，SwiftPM 资源包在 Contents/Resources/DiskCleaner_CleanerCore.bundle；
    /// 命令行程序的资源包与可执行文件同目录（Bundle.main.bundleURL）。两处都找不到就返回 nil，由调用方报「找不到内置规则」。
    /// Bundle.module 找不到资源包会直接终止进程，还会读开发机的 .build 目录，所以只在 DEBUG 构建里兜底访问它。
    public static func bundledData(mainBundle: Bundle = .main) -> Data? {
        #if DEBUG
        let fallback: (() -> Bundle)? = { Bundle.module }
        #else
        let fallback: (() -> Bundle)? = nil
        #endif
        let dirs = searchDirectories(resourceURL: mainBundle.resourceURL, bundleURL: mainBundle.bundleURL,
                                     executableURL: mainBundle.executableURL)
        return bundledData(searching: dirs, fallback: fallback)
    }

    /// 发行包里 dclean 放在 .app 的 Contents/MacOS，用户常用符号链接把它放进 PATH；
    /// 这时 Bundle.main 指向链接所在目录，所以还要按解析后的真实位置找（同目录及 ../Resources）。
    static func searchDirectories(resourceURL: URL?, bundleURL: URL?, executableURL: URL?) -> [URL] {
        var dirs = [resourceURL, bundleURL].compactMap { $0 }
        if let realDir = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            dirs += [realDir, realDir.deletingLastPathComponent().appendingPathComponent("Resources")]
        }
        return dirs
    }

    /// 依次在各目录里找 DiskCleaner_CleanerCore.bundle，都没有才用 fallback
    static func bundledData(searching directories: [URL], fallback: (() -> Bundle)?) -> Data? {
        let packaged = directories.lazy
            .map { $0.appendingPathComponent("DiskCleaner_CleanerCore.bundle") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap(Bundle.init(url:))
        guard let bundle = packaged ?? fallback?(),
              let url = bundle.url(forResource: "RulePack", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func load(bundled: Data, user: Data?, safety: PathSafety) -> LoadedRules {
        var rules: [CleanRule] = []
        var problems: [String] = []
        var seen = Set<String>()
        func report(_ label: String, _ message: String) {
            problems.append("\(label)：\(message)")
        }
        func add(_ data: Data, origin: RuleOrigin, label: String) {
            let file: RawRulePackFile
            do {
                file = try JSONDecoder().decode(RawRulePackFile.self, from: data)
            } catch {
                report(label, "无法解析：\(error)")
                return
            }
            guard file.platform == "macos" else {
                report(label, "不是 macOS 规则包，已忽略")
                return
            }
            guard file.version == 1 else {
                report(label, "版本 \(file.version) 不受支持，已忽略")
                return
            }
            for (index, lossy) in file.rules.enumerated() {
                let rule: CleanRule
                switch lossy.result {
                case .failure(let error):
                    report(label, "第 \(index + 1) 条规则无法解析：\(error)")
                    continue
                case .success(let decoded):
                    rule = decoded
                }
                let issues = RuleValidator.problems(in: rule, origin: origin, safety: safety)
                guard issues.isEmpty else {
                    for issue in issues { report(label, issue) }
                    continue
                }
                guard seen.insert(rule.id).inserted else {
                    report(label, "规则 \(rule.id)：id 重复，已忽略")
                    continue
                }
                rules.append(rule)
            }
        }
        add(bundled, origin: .bundled, label: "内置规则包")
        if let user { add(user, origin: .user, label: "自定义规则文件") }
        return LoadedRules(rules: rules, problems: problems)
    }
}
