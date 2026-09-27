import XCTest
@testable import CleanerCore

final class EngineProjectDetectorTests: XCTestCase {
    let home = EngineFixture.home
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var dirty: [String: Int] = [:]
    /// 项目根 → `git config --show-scope --get-regexp ^filter\.` 的模拟结果（exitStatus, stdout）。
    /// 不设置时默认无过滤器：exit 1、空输出。
    var filterConfig: [String: (Int32, String)] = [:]

    override func setUp() {
        files = InMemoryFileOperations(home: home)
        files.makeFile("/opt/homebrew/bin/git", size: 1)
        runner = FakeProcessRunner()
        dirty = [:]
        filterConfig = [:]
        runner.handler = { [unowned self] path, args in
            guard path == "/opt/homebrew/bin/git",
                  let cIndex = args.firstIndex(of: "-C"), cIndex + 1 < args.count else { return nil }
            let root = args[cIndex + 1]
            if args.contains("config") {
                let (status, stdout) = self.filterConfig[root] ?? (1, "")
                return ProcessResult(exitStatus: status, stdout: stdout, stderr: "")
            }
            if args.contains("status") {
                let lines = Array(repeating: " M f", count: self.dirty[root] ?? 0).joined(separator: "\n")
                return ProcessResult(exitStatus: 0, stdout: lines, stderr: "")
            }
            return ProcessResult(exitStatus: 128, stdout: "", stderr: "")
        }
    }

    /// 写一条形如 `.git/logs/HEAD` 的合法 reflog 记录，最后提交时间距今 idleDays 天。
    func writeReflog(_ root: String, idleDays: Double) {
        let ts = Int(EngineFixture.daysBefore(idleDays).timeIntervalSince1970)
        let line = "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Tester <t@x> \(ts) +0800\tcommit: msg\n"
        files.makeFile(root + "/.git/logs/HEAD", size: Int64(line.utf8.count), content: line.data(using: .utf8))
    }

    func gitProject(_ rel: String, idleDays: Double, lock: String? = "package-lock.json") -> String {
        let root = home + "/" + rel
        files.makeDirectory(root + "/.git")
        if let lock { files.makeFile(root + "/" + lock, size: 1) }
        files.makeFile(root + "/package.json", size: 1)
        writeReflog(root, idleDays: idleDays)
        return root
    }

    func detect() -> [CleanItem] {
        ProjectArtifactDetector().detect(EngineFixture.context(files, runner: runner))
    }

    func testIdleProjectOver90DaysIsSuggested() {
        let root = gitProject("work/app", idleDays: 100)
        files.makeFile(root + "/node_modules/x/index.js", size: 50)
        files.makeFile(root + "/backend/.venv/lib/a.py", size: 50)
        let items = detect()
        XCTAssertEqual(items.map(\.id), ["project:" + root])
        XCTAssertEqual(items[0].tier, .suggested)
        XCTAssertEqual(items[0].paths, [root + "/backend/.venv", root + "/node_modules"])
        XCTAssertEqual(items[0].action.type, .recover)
        XCTAssertTrue(items[0].notes.contains("闲置 100 天"))
    }

    func test30To90DaysIsConfirmAndUnder30IsIgnored() {
        let mid = gitProject("work/mid", idleDays: 45)
        files.makeFile(mid + "/node_modules/a", size: 1)
        let fresh = gitProject("work/fresh", idleDays: 5)
        files.makeFile(fresh + "/node_modules/a", size: 1)
        let items = detect()
        XCTAssertEqual(items.map(\.id), ["project:" + mid])
        XCTAssertEqual(items[0].tier, .confirm)
    }

    func testNonGitProjectUsesSourceModificationTime() {
        let root = home + "/scratch/tool"
        files.makeFile(root + "/requirements.txt", size: 1, modifiedAt: EngineFixture.daysBefore(120))
        files.makeFile(root + "/main.py", size: 1, modifiedAt: EngineFixture.daysBefore(95))
        files.makeFile(root + "/venv/bin/python", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        let items = detect()
        XCTAssertEqual(items.first?.tier, .suggested)
        XCTAssertEqual(items.first?.paths, [root + "/venv"])
    }

    func testMissingLockfileDowngradesToConfirmWithNote() {
        let root = gitProject("work/nolock", idleDays: 200, lock: nil)
        files.makeFile(root + "/node_modules/a", size: 1)
        let item = detect()[0]
        XCTAssertEqual(item.tier, .confirm)
        XCTAssertTrue(item.notes.contains { $0.contains("lockfile") })
    }

    func testDirtySourceIsNotedButNotBlocking() {
        let root = gitProject("work/dirty", idleDays: 100)
        files.makeFile(root + "/node_modules/a", size: 1)
        dirty[root] = 3
        let item = detect()[0]
        XCTAssertEqual(item.tier, .suggested)
        XCTAssertTrue(item.notes.contains { $0.contains("3 处未提交改动") })
    }

    func testBuildDirectoryNeedsProjectMarker() {
        let root = home + "/notes"
        files.makeFile(root + "/build/report.pdf", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        XCTAssertEqual(detect(), [])
    }

    func testToolDirectoriesAppBundlesAndDocumentsAreExcluded() {
        let hidden = home + "/.hermes/agent"
        files.makeFile(hidden + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(hidden + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        let app = home + "/tmp/Tool.app/Contents/Resources/app"
        files.makeFile(app + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(app + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        let docs = home + "/Documents/proj"
        files.makeFile(docs + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(docs + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        XCTAssertEqual(detect(), [])
    }

    func testStaleProjectUnderDownloadsIsSkipped() {
        let dl = home + "/Downloads/proj"
        files.makeFile(dl + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        files.makeFile(dl + "/node_modules/a", size: 1, modifiedAt: EngineFixture.daysBefore(300))
        XCTAssertEqual(detect(), [])
    }

    func testWithoutUsableGitFallsBackToReflogAndNeverRunsShim() throws {
        try files.removeItem(atPath: "/opt/homebrew/bin/git")
        files.makeFile("/usr/bin/git", size: 1) // 未装命令行工具时的占位程序
        let root = gitProject("work/old", idleDays: 1)
        files.makeFile(root + "/index.js", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/node_modules/a", size: 1)
        // 最后提交时间直接读 reflog（1 天前，比文件修改时间更新），不需要任何 git 可执行文件；
        // 太新（< 30 天）因此不出现在结果里，且全程不执行占位 shim。
        XCTAssertNil(detect().first)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNestedArtifactsAreNotDescendedInto() {
        let root = gitProject("work/nested", idleDays: 100)
        files.makeFile(root + "/node_modules/pkg/node_modules/deep/a", size: 1)
        XCTAssertEqual(detect()[0].paths, [root + "/node_modules"])
    }

    func testGitCallsAreReadOnlyAndSafe() {
        let root = gitProject("work/safe", idleDays: 100)
        files.makeFile(root + "/node_modules/a", size: 1)
        dirty[root] = 1
        _ = detect()
        XCTAssertFalse(runner.calls.isEmpty)
        for call in runner.calls {
            XCTAssertTrue(call.arguments.contains("--no-optional-locks"))
            XCTAssertFalse(call.arguments.contains("log"))
        }
    }

    func testStatusNotCalledForFreshProject() {
        let root = gitProject("work/fresh2", idleDays: 5)
        files.makeFile(root + "/node_modules/a", size: 1)
        _ = detect()
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testLocalFilterSkipsStatusCall() {
        let root = gitProject("work/localfilter", idleDays: 100)
        files.makeFile(root + "/node_modules/a", size: 1)
        filterConfig[root] = (0, "local filter.x.clean ./x.sh")
        dirty[root] = 2 // 若真跑了 status 就会体现出来
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("status") })
        XCTAssertFalse(item?.notes.contains { $0.contains("未提交改动") } ?? true)
    }

    func testGlobalFilterAllowsStatusCall() {
        let root = gitProject("work/globalfilter", idleDays: 100)
        files.makeFile(root + "/node_modules/a", size: 1)
        filterConfig[root] = (0, "global filter.lfs.clean git-lfs clean -- %f")
        dirty[root] = 2
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertTrue(runner.calls.contains { $0.arguments.contains("status") })
        XCTAssertTrue(item?.notes.contains { $0.contains("2 处未提交改动") } ?? false)
    }

    func testReflogWorksWithoutGitExecutable() throws {
        try files.removeItem(atPath: "/opt/homebrew/bin/git")
        let root = gitProject("work/noexe", idleDays: 200)
        files.makeFile(root + "/node_modules/a", size: 1)
        XCTAssertEqual(detect().first?.tier, .suggested)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMalformedReflogCapsAtConfirm() {
        let root = home + "/work/malformed"
        files.makeDirectory(root + "/.git")
        files.makeFile(root + "/package.json", size: 1)
        files.makeFile(root + "/package-lock.json", size: 1)
        files.makeFile(root + "/index.js", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/node_modules/a", size: 1)
        files.makeFile(root + "/.git/logs/HEAD", size: 1, content: "not a valid reflog line".data(using: .utf8))
        let item = detect().first
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertTrue(item?.notes.contains("无法读取 git 提交时间，按文件修改时间估计") ?? false)
    }

    func testTargetNeedsRustOrJavaMarker() {
        let root = home + "/work/rusty"
        files.makeDirectory(root + "/.git")
        files.makeFile(root + "/package.json", size: 1)
        files.makeFile(root + "/target/x", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        writeReflog(root, idleDays: 200)
        XCTAssertEqual(detect(), [])

        files.makeFile(root + "/Cargo.toml", size: 1)
        XCTAssertEqual(detect().first?.paths, [root + "/target"])
    }

    func testHomeLevelArtifactWithoutProjectRootIsSkipped() {
        files.makeFile(home + "/venv/bin/python", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        XCTAssertEqual(detect(), [])
    }

    func testGlobalNpmPrefixNodeModulesIsSkipped() {
        files.makeFile(home + "/tools/node/lib/node_modules/pkg/index.js", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        XCTAssertEqual(detect(), [])
    }

    func testDistOnlyWithoutLockfileStaysSuggested() {
        let root = gitProject("work/distonly", idleDays: 100, lock: nil)
        files.makeFile(root + "/dist/bundle.js", size: 1)
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertEqual(item?.tier, .suggested)
    }

    func testDependencyArtifactWithoutMatchingLockfileDowngradesToConfirm() {
        let root = gitProject("work/mixed", idleDays: 100, lock: nil)
        files.makeFile(root + "/frontend/package-lock.json", size: 1)
        files.makeFile(root + "/frontend/node_modules/a", size: 1)
        files.makeFile(root + "/backend/.venv/lib/a.py", size: 1)
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertEqual(item?.tier, .confirm)
    }

    func testBuildNextToOnlyPackageJsonCapsAtConfirm() {
        let root = gitProject("work/buildpkg", idleDays: 100)
        files.makeFile(root + "/build/output.js", size: 1)
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertTrue(item?.notes.contains("build 目录可能含 Electron 等工具的源资源，请确认后再清理") ?? false)
    }

    func testBuildNextToGradleStaysSuggested() {
        let root = gitProject("work/buildgradle", idleDays: 100)
        files.makeFile(root + "/build.gradle", size: 1)
        files.makeFile(root + "/build/output.class", size: 1)
        let item = detect().first { $0.id == "project:" + root }
        XCTAssertEqual(item?.tier, .suggested)
    }

    /// 深层子目录里紧挨着产物的最近编辑（这里是与 __pycache__ 同级的 x.py，1 天前）应该被
    /// artifactParentActivity 信号捕捉到，让整个项目视为「新鲜」而不出现在结果里——即使
    /// newestSourceModification 那一层浅扫描够不到这么深的路径。
    func testDeepRecentSourceEditKeepsProjectFresh() {
        let root = home + "/code/deep"
        files.makeFile(root + "/requirements.txt", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/app/pkg/a/x.py", size: 1, modifiedAt: EngineFixture.daysBefore(1))
        files.makeFile(root + "/app/pkg/a/__pycache__/c.pyc", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        XCTAssertEqual(detect(), [])
    }

    /// 缓存类产物（__pycache__ 等）可以按最近的工程标记文件向上聚合，但聚合不能落到家目录的
    /// 直接子目录——那通常是无关子项目共同的容器，不该把散落各处的缓存都吸过去。
    /// 依赖类产物（node_modules、.venv 等）完全不做这种聚合：找不到 .git 就以自己所在目录为项目，
    /// 即使旁边有更上层的标记文件。
    func testCacheArtifactsDoNotGroupToDirectHomeChildMarkerRoot() {
        let code = home + "/code"
        files.makeFile(code + "/package.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/node_modules/pkg/index.js", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/scripts/tool/main.py", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/scripts/tool/.venv/bin/python", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/scripts/other/keep.txt", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(code + "/scripts/other/__pycache__/c.pyc", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        let items = detect()
        XCTAssertEqual(Set(items.map(\.id)), Set([
            "project:" + code,
            "project:" + code + "/scripts/tool",
            "project:" + code + "/scripts/other",
        ]))
        // node_modules：没有 .git，依赖类产物不做标记聚合，落回自己的父目录 ~/code（本来就是家目录直接子目录，
        // 这是既有行为，予以保留）；~/code 有 lockfile，判为建议。
        XCTAssertEqual(items.first { $0.id == "project:" + code }?.tier, .suggested)
        // .venv：自己的父目录 scripts/tool 里没有 lockfile，判为需要确认。
        XCTAssertEqual(items.first { $0.id == "project:" + code + "/scripts/tool" }?.tier, .confirm)
        // __pycache__：向上找标记文件时跳过家目录的直接子目录 ~/code（即使那里有 package.json/lockfile），
        // 找不到更近的标记，落回自己的父目录 scripts/other，而不是被 ~/code 吸走。
        XCTAssertNotNil(items.first { $0.id == "project:" + code + "/scripts/other" },
                         "缓存产物不应被聚合到家目录直接子目录的标记根 ~/code")
    }

    /// 非 git 的 monorepo：多个子包各自有自己的依赖产物时，即使根目录也有 package.json，
    /// 依赖类产物不做标记聚合，每个子包仍各自成为独立的项目条目。
    func testNestedMonorepoPackagesWithoutGitEachGetOwnItem() {
        let root = home + "/mono"
        files.makeFile(root + "/package.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/a/package.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/a/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/a/node_modules/x", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/b/package.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/b/package-lock.json", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/packages/b/node_modules/x", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        let items = detect()
        XCTAssertEqual(Set(items.map(\.id)), Set([
            "project:" + root + "/packages/a",
            "project:" + root + "/packages/b",
        ]))
        XCTAssertTrue(items.allSatisfy { $0.tier == .suggested })
    }

    /// 非 git 项目，产物散落在深层子目录（如多个 Python 子包各自的 __pycache__）时，
    /// 应统一按最近的工程标记文件（这里是根目录的 requirements.txt）聚合成同一个项目，
    /// 而不是把每个子目录各自当成一个项目。
    func testNonGitArtifactsAreGroupedByNearestProjectMarker() {
        let root = home + "/code/app"
        files.makeFile(root + "/requirements.txt", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/.venv/bin/python", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/app/pkg/a/__pycache__/x.pyc", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        files.makeFile(root + "/app/pkg/b/__pycache__/y.pyc", size: 1, modifiedAt: EngineFixture.daysBefore(200))
        let items = detect()
        XCTAssertEqual(items.map(\.id), ["project:" + root])
        XCTAssertEqual(items[0].paths, [
            root + "/.venv",
            root + "/app/pkg/a/__pycache__",
            root + "/app/pkg/b/__pycache__",
        ])
    }
}
