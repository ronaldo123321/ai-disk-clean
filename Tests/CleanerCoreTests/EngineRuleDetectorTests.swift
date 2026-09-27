import XCTest
@testable import CleanerCore

final class EngineRuleDetectorTests: XCTestCase {
    func testResolverFindsExecutableInFixedDirectoriesNotPATH() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile("/opt/homebrew/bin/uv", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v18.0.0/bin/npm", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v22.1.0/bin/npm", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("uv"), "/opt/homebrew/bin/uv")
        XCTAssertEqual(resolver.resolve("npm"), EngineFixture.home + "/.nvm/versions/node/v22.1.0/bin/npm")
        XCTAssertNil(resolver.resolve("pnpm"))
        XCTAssertNil(resolver.resolve("bin/uv"))
        XCTAssertEqual(resolver.resolve("/opt/homebrew/bin/uv"), "/opt/homebrew/bin/uv")
    }

    func testCommandLineToolShimsAreSkippedUntilToolsInstalled() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile("/usr/bin/git", size: 1)
        files.makeFile("/usr/bin/pip3", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertNil(resolver.resolve("git"))
        XCTAssertNil(resolver.resolve("/usr/bin/pip3"))
        files.makeFile("/Library/Developer/CommandLineTools/usr/bin/git", size: 1)
        XCTAssertEqual(resolver.resolve("git"), "/usr/bin/git")
        XCTAssertEqual(resolver.resolve("pip3"), "/usr/bin/pip3")
    }

    func testNvmVersionsAreOrderedNumericallyNotLexically() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v8.17.0/bin/npm", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v22.9.0/bin/npm", size: 1)
        files.makeFile(EngineFixture.home + "/.nvm/versions/node/v22.10.0/bin/npm", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("npm"), EngineFixture.home + "/.nvm/versions/node/v22.10.0/bin/npm")
    }

    func testBrokenSymlinkIsSkippedInFavorOfLaterDirectory() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeSymlink(at: "/opt/homebrew/bin/uv", target: "/nope/uv")
        files.makeFile("/usr/local/bin/uv", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("uv"), "/usr/local/bin/uv")
    }

    func testSymlinkToDirectoryIsSkipped() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeDirectory("/opt/homebrew/somedir")
        files.makeSymlink(at: "/opt/homebrew/bin/uv", target: "/opt/homebrew/somedir")
        files.makeFile("/usr/local/bin/uv", size: 1)
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("uv"), "/usr/local/bin/uv")
    }

    func testValidSymlinkResolvesToLinkPathItself() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile("/opt/homebrew/Library/brew.sh", size: 1)
        files.makeSymlink(at: "/opt/homebrew/bin/brew", target: "/opt/homebrew/Library/brew.sh")
        let resolver = ExecutableResolver(files: files)
        XCTAssertEqual(resolver.resolve("brew"), "/opt/homebrew/bin/brew")
    }

    func testAbsolutePathThatIsDirectoryReturnsNil() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeDirectory("/opt/homebrew/bin")
        let resolver = ExecutableResolver(files: files)
        XCTAssertNil(resolver.resolve("/opt/homebrew/bin"))
    }

    func testBlockerMessages() {
        XCTAssertEqual(Blocker.appRunning(name: "Chrome", bundleID: "com.google.Chrome").message, "需先退出 Chrome")
        XCTAssertEqual(Blocker.occupied("uv(12)").message, "被占用：uv(12)")
        XCTAssertTrue(Blocker.appRunning(name: "a", bundleID: "b").isAppRunning)
        XCTAssertFalse(Blocker.occupied("x").isAppRunning)
    }

    func rule(_ id: String, tier: CleanTier = .safe, targets: [String], action: RuleAction = .recover,
              detect: [String]? = nil) -> CleanRule {
        CleanRule(id: id, name: id, app: "App", category: .dev, tier: tier, detect: detect, targets: targets,
                  action: action, preconditions: nil, copy: RuleCopy(what: "w", impact: "i", regrows: nil))
    }

    func testExistingTargetsBecomeOneItemPerRule() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.gradle/caches/x", size: 10)
        let items = RuleDetector(rules: [rule("gradle", targets: ["~/.gradle/caches", "~/.gradle/missing"])])
            .detect(EngineFixture.context(files))
        XCTAssertEqual(items.map(\.id), ["rule:gradle"])
        XCTAssertEqual(items[0].paths, [EngineFixture.home + "/.gradle/caches"])
    }

    func testMissingTargetsProduceNoItem() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        XCTAssertEqual(RuleDetector(rules: [rule("g", targets: ["~/.gradle/caches"])]).detect(EngineFixture.context(files)), [])
    }

    func testWildcardExpandsToDirectoriesOnly() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/PyCharm2025.2/a", size: 1)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/IntelliJIdea2025.2/a", size: 1)
        files.makeFile(EngineFixture.home + "/Library/Caches/JetBrains/stray.txt", size: 1)
        files.makeSymlink(at: EngineFixture.home + "/Library/Caches/JetBrains/link", target: "/tmp")
        let items = RuleDetector(rules: [rule("jb", targets: ["~/Library/Caches/JetBrains/*"])]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [EngineFixture.home + "/Library/Caches/JetBrains/IntelliJIdea2025.2",
                                        EngineFixture.home + "/Library/Caches/JetBrains/PyCharm2025.2"])
    }

    func testWildcardInMiddleKeepsSuffix() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let base = EngineFixture.home + "/Library/Application Support/Google/Chrome"
        files.makeFile(base + "/Default/Service Worker/CacheStorage/x", size: 1)
        files.makeFile(base + "/Profile 1/Preferences", size: 1)
        let items = RuleDetector(rules: [rule("c", tier: .suggested, targets: ["~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"])])
            .detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [base + "/Default/Service Worker/CacheStorage"])
    }

    func testCommandRuleNeedsExecutable() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/a", size: 1)
        let r = rule("npm", targets: ["~/.npm/_cacache"], action: .command(["npm", "cache", "clean", "--force"]))
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)), [])
        files.makeFile("/usr/local/bin/npm", size: 1)
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)).count, 1)
    }

    func testDetectPathsGateTheRule() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Library/Caches/Foo/a", size: 1)
        let gated = rule("foo", targets: ["~/Library/Caches/Foo"], detect: ["/Applications/Foo.app"])
        XCTAssertEqual(RuleDetector(rules: [gated]).detect(EngineFixture.context(files)), [])
        files.makeDirectory("/Applications/Foo.app")
        XCTAssertEqual(RuleDetector(rules: [gated]).detect(EngineFixture.context(files)).count, 1)
    }

    func testSymlinkTargetsAreSkipped() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeSymlink(at: EngineFixture.home + "/.gradle/caches", target: EngineFixture.home + "/Documents")
        XCTAssertEqual(RuleDetector(rules: [rule("g", targets: ["~/.gradle/caches"])]).detect(EngineFixture.context(files)), [])
    }

    func testRecoverOlderThanListsOnlyOldChildren() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let dir = EngineFixture.home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/old.ips", size: 5, modifiedAt: EngineFixture.daysBefore(40))
        files.makeFile(dir + "/new.ips", size: 5, modifiedAt: EngineFixture.daysBefore(3))
        let r = rule("diag", targets: ["~/Library/Logs/DiagnosticReports"], action: RuleAction(type: .recoverOlderThan, olderThanDays: 30))
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [dir + "/old.ips"])
    }

    func testDisplayOnlyRulesMayPointIntoForbiddenTrees() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.codex/sessions/2026/a.jsonl", size: 9)
        let r = rule("codex", tier: .displayOnly, targets: ["~/.codex/sessions"], action: .noAction)
        XCTAssertEqual(RuleDetector(rules: [r]).detect(EngineFixture.context(files)).count, 1)
        let actionable = rule("codex2", tier: .confirm, targets: ["~/.codex/sessions"])
        XCTAssertEqual(RuleDetector(rules: [actionable]).detect(EngineFixture.context(files)), [])
    }

    func testDisplayOnlyExpansionNeverLandsInPrivacyRoots() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/Documents/a", size: 1)
        files.makeFile(EngineFixture.home + "/Downloads/a", size: 1)
        // 绕过校验直接构造规则，验证识别器自身的防线
        let r = rule("wide", tier: .displayOnly, targets: ["~/*"], action: .noAction)
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items.first?.paths, [EngineFixture.home + "/Downloads"])
    }

    func testEnginePathChecksIsCanonical() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeDirectory(EngineFixture.home + "/plain")
        XCTAssertTrue(EnginePathChecks.isCanonical(EngineFixture.home + "/plain", files: files))
        files.makeSymlink(at: EngineFixture.home + "/link", target: EngineFixture.home + "/plain")
        XCTAssertFalse(EnginePathChecks.isCanonical(EngineFixture.home + "/link", files: files))
    }

    func testAncestorSymlinkIsRejectedButRealPathIsAccepted() throws {
        let tmp = TestEnv.makeTempDir("dclean-ruledetector")
        defer { TestEnv.remove(tmp) }
        try FileManager.default.createDirectory(atPath: tmp + "/Library/Caches/Real/CacheStorage",
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: tmp + "/Library/Caches/Real/CacheStorage/x"))
        try FileManager.default.createSymbolicLink(atPath: tmp + "/Library/Caches/App",
                                                   withDestinationPath: tmp + "/Library/Caches/Real")
        let files = RealFileOperations(home: tmp)
        let safety = PathSafety(home: tmp, files: files)
        let context = DetectContext(files: files, safety: safety, runner: FakeProcessRunner(), now: Date())

        let viaSymlink = rule("app", targets: ["~/Library/Caches/App/CacheStorage"])
        XCTAssertEqual(RuleDetector(rules: [viaSymlink]).detect(context), [])

        let viaReal = rule("real", targets: ["~/Library/Caches/Real/CacheStorage"])
        XCTAssertEqual(RuleDetector(rules: [viaReal]).detect(context).count, 1)
    }

    func testRecoverOlderThanExcludesDirectoriesAndForbiddenNames() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let dir = EngineFixture.home + "/Library/Logs/DiagnosticReports"
        files.makeFile(dir + "/old.ips", size: 5, modifiedAt: EngineFixture.daysBefore(40))
        files.makeDirectory(dir + "/old-dir")
        files.makeFile(dir + "/.git", size: 3, modifiedAt: EngineFixture.daysBefore(40))
        let r = rule("diag", targets: ["~/Library/Logs/DiagnosticReports"],
                    action: RuleAction(type: .recoverOlderThan, olderThanDays: 30))
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [dir + "/old.ips"])
    }

    func testNestedTargetPathsCollapseToOuter() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/X/sub/a", size: 1)
        let r = rule("nest", targets: ["~/X", "~/X/sub"])
        let items = RuleDetector(rules: [r]).detect(EngineFixture.context(files))
        XCTAssertEqual(items[0].paths, [EngineFixture.home + "/X"])
    }
}
