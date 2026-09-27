import Foundation

/// 只在本机 unix socket 上的 Docker 已运行时识别，绝不通过 -H 连接远程或 tcp daemon，也绝不替用户启动 Docker。
/// 容器只删容器本身（docker rm 不带 -v），数据卷一律保留。
/// 镜像删除用 docker rmi 不带 -f：被扩展容器等看不见的使用者占用时，由 Docker 自己拒绝。
public struct DockerDetector: Detector {
    public var failedContainerMinAgeDays: Double = 30
    public var name: String { "Docker" }

    public init() {}

    public func detect(_ context: DetectContext) -> [CleanItem] {
        guard let docker = ExecutableResolver(files: context.files).resolve("docker") else { return [] }

        func rawRun(_ args: [String]) -> String? {
            guard let result = context.runner.run(launchPath: docker, arguments: args), result.exitStatus == 0 else { return nil }
            return result.stdout
        }

        // 只信任本机 unix socket；context 指向 tcp:// 等远程端点时直接放弃，不发起任何后续探测。
        guard let endpointOutput = rawRun(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]) else { return [] }
        let host = endpointOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.hasPrefix("unix://") else { return [] }

        func run(_ args: [String]) -> String? { rawRun(["-H", host] + args) }
        func command(_ args: [String]) -> [String] { [docker, "-H", host] + args }

        guard run(["info", "--format", "{{.ServerVersion}}"]) != nil else { return [] }
        var items: [CleanItem] = []

        if context.isCancelled { return items }
        if let df = run(["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"]) {
            for line in df.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count == 2, fields[0] == "Build Cache", let bytes = Self.parseReclaimableSize(fields[1]), bytes > 0 {
                    items.append(item(id: "docker:build-cache", tier: .safe, title: "Docker 构建缓存",
                                      command: command(["builder", "prune", "-a", "-f"]), bytes: bytes,
                                      what: "构建镜像时留下的中间层", impact: "下次构建会慢一些，不影响已有镜像和容器"))
                }
            }
        }

        if context.isCancelled { return items }
        if let exited = run(["ps", "-a", "-q", "--filter", "status=exited"]) {
            let ids = exited.split(whereSeparator: \.isNewline).map(String.init)
            if !ids.isEmpty,
               let details = run(["inspect", "--format", "{{.Id}}\t{{.State.ExitCode}}\t{{.State.FinishedAt}}\t{{.Name}}"] + ids) {
                let cutoff = context.now.addingTimeInterval(-failedContainerMinAgeDays * 86_400)
                let failed = details.split(whereSeparator: \.isNewline).compactMap { line -> (id: String, name: String)? in
                    let fields = line.split(separator: "\t").map(String.init)
                    guard fields.count == 4, let code = Int(fields[1]), (1...127).contains(code),
                          let finished = Self.parseDate(fields[2]), finished < cutoff else { return nil }
                    let name = fields[3].hasPrefix("/") ? String(fields[3].dropFirst()) : fields[3]
                    return (String(fields[0].prefix(12)), name)
                }
                if !failed.isEmpty {
                    items.append(item(id: "docker:failed-containers", tier: .confirm,
                                      title: "Docker 中启动失败的旧容器（\(failed.count) 个）",
                                      command: command(["rm"] + failed.map(\.id)), bytes: 0,
                                      what: "30 天前异常退出的容器：" + failed.map(\.name).joined(separator: "、"),
                                      impact: "只删容器本身，数据卷保留"))
                }
            }
        }

        // 失败就当作「不知道」，绝不把已在用的镜像误判为未用：
        // ps 失败，或 ps 有结果但随后 inspect 失败，都不产出未用镜像项；只有 ps 成功且为空才代表确实没有容器在用镜像。
        var used: Set<String>?
        if context.isCancelled { return items }
        if let all = run(["ps", "-a", "-q"]) {
            let ids = all.split(whereSeparator: \.isNewline).map(String.init)
            if ids.isEmpty {
                used = []
            } else if let images = run(["inspect", "--format", "{{.Image}}"] + ids) {
                used = Set(images.split(whereSeparator: \.isNewline).map(String.init))
            }
        }

        if context.isCancelled { return items }
        if let used, let listing = run(["images", "--no-trunc", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"]) {
            var order: [String] = []
            var sizeByID: [String: Int64] = [:]
            var refsByID: [String: [String]] = [:]
            for line in listing.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count == 3 else { continue }
                let id = fields[0]
                guard !used.contains(id) else { continue }
                if sizeByID[id] == nil {
                    order.append(id)
                    sizeByID[id] = Self.parseSize(fields[2]) ?? 0
                }
                let ref = fields[1]
                if !ref.hasPrefix("<none>:"), !ref.hasSuffix(":<none>"), !(refsByID[id] ?? []).contains(ref) {
                    refsByID[id, default: []].append(ref)
                }
            }
            if !order.isEmpty {
                var rmiArgs: [String] = []
                var names: [String] = []
                var total: Int64 = 0
                for id in order {
                    total += sizeByID[id] ?? 0
                    let refs = refsByID[id] ?? []
                    if refs.isEmpty {
                        // 没有任何完整 repo:tag 引用（如 <none>:<none> 或按摘要拉取的 foo:<none>），只能用镜像 ID 本身来删除和展示。
                        rmiArgs.append(id)
                        names.append(Self.shortImageID(id))
                    } else {
                        rmiArgs.append(contentsOf: refs)
                        names.append(contentsOf: refs)
                    }
                }
                items.append(item(id: "docker:unused-images", tier: .confirm,
                                  title: "未被任何容器使用的 Docker 镜像（\(order.count) 个）",
                                  command: command(["rmi"] + rmiArgs), bytes: total, what: names.joined(separator: "、"),
                                  impact: "需要时可重新拉取或构建；被 Docker Desktop 扩展使用的镜像 Docker 会拒绝删除；多标签镜像若被隐藏容器使用，可能只被去掉部分标签",
                                  notes: ["镜像大小含与其他镜像共用的层，实际释放可能更少"]))
            }
        }
        return items
    }

    func item(id: String, tier: CleanTier, title: String, command: [String], bytes: Int64,
              what: String, impact: String, notes: [String] = []) -> CleanItem {
        var item = CleanItem(id: id, app: "Docker", category: .dev, tier: tier, title: title, paths: [],
                             action: .command(command), preconditions: .empty,
                             copy: RuleCopy(what: what, impact: impact, regrows: nil), notes: notes)
        item.apparentBytes = bytes
        item.reclaimableBytes = bytes
        item.sizedByDetector = true
        return item
    }

    /// `<none>:<none>` 镜像没有可读名字，退回展示去掉 "sha256:" 前缀后的短 ID。
    static func shortImageID(_ id: String) -> String {
        let prefix = "sha256:"
        let digest = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        return String(digest.prefix(12))
    }

    /// Docker 用十进制单位：1kB = 1000B。
    static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where trimmed.hasSuffix(unit) {
            guard let value = Double(trimmed.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// `system df` 的 Reclaimable 列带百分比后缀，如 "4.2GB (83%)"，去掉括号部分再按体积解析。
    static func parseReclaimableSize(_ text: String) -> Int64? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if let parenIndex = trimmed.firstIndex(of: "(") {
            trimmed = String(trimmed[..<parenIndex]).trimmingCharacters(in: .whitespaces)
        }
        return parseSize(trimmed)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// FinishedAt 可能带任意位数的小数秒（常见 9 位纳秒），ISO8601DateFormatter 不认；
    /// 去掉小数部分，但保留小数点后紧跟的时区后缀（"Z" 或 "+08:00"）。
    static func parseDate(_ text: String) -> Date? {
        guard let dotIndex = text.firstIndex(of: ".") else { return isoFormatter.date(from: text) }
        var suffixStart = text.index(after: dotIndex)
        while suffixStart < text.endIndex, text[suffixStart].isNumber {
            suffixStart = text.index(after: suffixStart)
        }
        let value = String(text[..<dotIndex]) + String(text[suffixStart...])
        return isoFormatter.date(from: value)
    }
}
