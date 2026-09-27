import Foundation

// MARK: - 占用守卫评估（spec §5 第 6 层）

/// lockfile 守卫：lsof 查锁文件持有者；process 守卫：pgrep 查进程是否运行中。
/// 评估不通过 → 该项 blocked，UI 禁用勾选，执行时跳过。无绕过入口。
public final class GuardEvaluator {
    private let files: FileOperations
    private let runner: ProcessRunner

    public init(files: FileOperations, runner: ProcessRunner) {
        self.files = files
        self.runner = runner
    }

    public static let lsofPath = "/usr/sbin/lsof"
    public static let pgrepPath = "/usr/bin/pgrep"

    /// 合并一条规则所有守卫：全部 clear 才 clear。
    public func status(of guards: [GuardSpec], home: String) -> GuardStatus {
        var all: [Occupier] = []
        for g in guards {
            switch evaluate(g, home: home) {
            case .clear:
                continue
            case .unknown(let reason):
                return .unknown(reason)
            case .blocked(let occupiers):
                all.append(contentsOf: occupiers)
            }
        }
        return all.isEmpty ? .clear : .blocked(all)
    }

    public func evaluate(_ guardSpec: GuardSpec, home: String) -> GuardStatus {
        switch guardSpec.type {
        case .lockfile:
            return evaluateLockfile(guardSpec, home: home)
        case .process:
            return evaluateProcess(guardSpec)
        }
    }

    private func evaluateLockfile(_ guardSpec: GuardSpec, home: String) -> GuardStatus {
        guard let rawPath = guardSpec.path else { return .unknown("缺少锁文件路径") }
        let path = PathSafety.normalize(rawPath, home: home)
        // 锁文件不存在 → 无人持有
        guard files.fileExists(path) else { return .clear }
        // 目录目标（如浏览器缓存目录、锁目录）：+D 递归检测子树内被打开的文件；
        // 注意 +D 必须紧跟目录路径，不能与 -- 混用。
        let arguments: [String]
        if files.attributesIfExist(atPath: path)?.isDirectory == true {
            arguments = ["-F", "pcn0", "+D", path]
        } else {
            // -F pcn0：以 NUL 分隔输出 pid(p)、命令名(c)、文件名(n)；-- 结束选项防路径被当参数
            arguments = ["-F", "pcn0", "--", path]
        }
        guard let result = runner.run(launchPath: Self.lsofPath, arguments: arguments) else {
            return .unknown("lsof 无法启动")
        }
        let occupiers = parseLsofFields(result.stdout)
        if !occupiers.isEmpty { return .blocked(occupiers) }
        guard result.exitStatus == 1, result.stdout.isEmpty, result.stderr.isEmpty else {
            return .unknown("lsof 未能确认目标空闲")
        }
        return .clear
    }

    /// 解析 `lsof -F pcn0` 输出：记录集以 p 开头，p 后跟 pid，c 后跟命令名。
    func parseLsofFields(_ output: String) -> [Occupier] {
        var occupiers: [Occupier] = []
        var currentPID: Int32?
        var currentCommand: String?
        for rawRecord in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let record = rawRecord.drop(while: { $0 == "\n" || $0 == "\r" })
            guard let first = record.first else { continue }
            let value = String(record.dropFirst())
            switch first {
            case "p":
                currentPID = Int32(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "n":
                if let pid = currentPID {
                    occupiers.append(Occupier(pid: pid, command: currentCommand ?? "?"))
                }
                currentPID = nil
                currentCommand = nil
            default:
                continue
            }
        }
        // 去重（同一进程可能持有多把锁/多个 fd）
        var seen = Set<String>()
        return occupiers.filter { seen.insert($0.description).inserted }
    }

    private func evaluateProcess(_ guardSpec: GuardSpec) -> GuardStatus {
        guard let name = guardSpec.process, !name.isEmpty else { return .unknown("缺少进程名") }
        guard let result = runner.run(launchPath: Self.pgrepPath, arguments: ["-x", name]) else {
            return .unknown("pgrep 无法启动")
        }
        if result.exitStatus == 1 && result.stdout.isEmpty && result.stderr.isEmpty { return .clear }
        guard result.exitStatus == 0, result.stderr.isEmpty else { return .unknown("pgrep 检查失败") }
        let pids = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        guard !pids.isEmpty else { return .unknown("进程结果无法解析") }
        return .blocked(pids.map { Occupier(pid: $0, command: name) })
    }
}
