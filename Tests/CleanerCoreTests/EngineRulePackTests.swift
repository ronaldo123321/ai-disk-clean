import XCTest
@testable import CleanerCore

final class EngineRulePackTests: XCTestCase {
    let home = "/Users/tester"
    lazy var files = InMemoryFileOperations(home: home)
    lazy var safety = PathSafety(home: home, files: files)

    func testBundledPackLoadsWithoutProblems() throws {
        let data = try XCTUnwrap(RulePack.bundledData())
        let loaded = RulePack.load(bundled: data, user: nil, safety: safety)
        XCTAssertEqual(loaded.problems, [])
        XCTAssertGreaterThanOrEqual(loaded.rules.count, 27)
    }

    func testBundledCommandsAreBareNamesResolvedAtRuntime() throws {
        let loaded = RulePack.load(bundled: try XCTUnwrap(RulePack.bundledData()), user: nil, safety: safety)
        for rule in loaded.rules where rule.action.type == .command {
            XCTAssertFalse(rule.action.command!.first!.contains("/"), rule.id)
        }
    }

    func testEditorsAndIDEsAreNeverQuitForUser() throws {
        let loaded = RulePack.load(bundled: try XCTUnwrap(RulePack.bundledData()), user: nil, safety: safety)
        let editors = ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
                        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.apple.dt.Xcode", "com.microsoft.VSCode",
                        "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop"]
        let apps = loaded.rules.flatMap { $0.preconditions?.quitApps ?? [] }
        let presentBundleIDs = Set(apps.map(\.bundleID))
        for bundleID in editors {
            XCTAssertTrue(presentBundleIDs.contains(bundleID), "\(bundleID) 未出现在任何规则里")
        }
        for app in apps where editors.contains(app.bundleID) {
            XCTAssertFalse(app.canQuitForUser, app.bundleID)
        }
    }

    func testInvalidRulesAreDroppedAndReported() {
        let pack = """
        {"version":1,"platform":"macos","rules":[
          {"id":"ok","name":"OK","app":"a","category":"dev","tier":"safe","targets":["~/.npm/_cacache"],
           "action":{"type":"command","command":["npm","cache","clean","--force"]},"copy":{"what":"w","impact":"i"}},
          {"id":"bad","name":"Bad","app":"a","category":"dev","tier":"suggested","targets":["~/Documents"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}
        ]}
        """
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules.map(\.id), ["ok"])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testUserRulesCannotShadowBundledIDsOrEscalate() {
        let bundled = """
        {"version":1,"platform":"macos","rules":[
          {"id":"dup","name":"B","app":"a","category":"dev","tier":"safe","targets":["~/Library/Caches/A"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}]}
        """
        let user = """
        {"version":1,"platform":"macos","rules":[
          {"id":"dup","name":"U","app":"a","category":"dev","tier":"confirm","targets":["~/Library/Caches/B"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}},
          {"id":"mine","name":"M","app":"a","category":"other","tier":"confirm","targets":["~/Library/Caches/C"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}]}
        """
        let loaded = RulePack.load(bundled: Data(bundled.utf8), user: Data(user.utf8), safety: safety)
        XCTAssertEqual(loaded.rules.map(\.name), ["B", "M"])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testNonMacPackIsIgnored() {
        let pack = #"{"version":1,"platform":"windows","rules":[]}"#
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testOneBadRuleInUserFileOnlyDropsThatRule() {
        let bundled = #"{"version":1,"platform":"macos","rules":[]}"#
        let user = """
        {"version":1,"platform":"macos","rules":[
          {"id":"good","name":"G","app":"a","category":"dev","tier":"confirm","targets":["~/Library/Caches/A"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}},
          {"id":"bad","name":"B","app":"a","category":"dev","tier":"Confirm","targets":["~/Library/Caches/B"],
           "action":{"type":"recover"},"copy":{"what":"w","impact":"i"}}
        ]}
        """
        let loaded = RulePack.load(bundled: Data(bundled.utf8), user: Data(user.utf8), safety: safety)
        XCTAssertEqual(loaded.rules.map(\.id), ["good"])
        XCTAssertEqual(loaded.problems.count, 1)
        XCTAssertTrue(loaded.problems[0].contains("第 2 条"), loaded.problems[0])
    }

    func testUnparseableFileYieldsOneProblemAndNoRules() {
        let loaded = RulePack.load(bundled: Data("{not json".utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testUnsupportedVersionIsIgnored() {
        let pack = #"{"version":2,"platform":"macos","rules":[]}"#
        let loaded = RulePack.load(bundled: Data(pack.utf8), user: nil, safety: safety)
        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.problems.count, 1)
    }

    func testJetBrainsRuleNeverTouchesLocalHistoryOrWholeCacheDir() throws {
        let loaded = RulePack.load(bundled: try XCTUnwrap(RulePack.bundledData()), user: nil, safety: safety)
        let jetbrains = try XCTUnwrap(loaded.rules.first { $0.id == "jetbrains-caches" })
        for target in jetbrains.targets {
            XCTAssertFalse(target.contains("LocalHistory"), target)
            XCTAssertFalse(target.hasSuffix("/*"), target)
        }
    }

    func testBundledDataPrefersPackagedResourceBundle() throws {
        let dir = TestEnv.makeTempDir("pack")
        defer { TestEnv.remove(dir) }
        let bundleDir = dir + "/DiskCleaner_CleanerCore.bundle"
        try FileManager.default.createDirectory(atPath: bundleDir, withIntermediateDirectories: true)
        try TestEnv.write(#"{"version":1,"platform":"macos","rules":[]}"#, to: bundleDir + "/RulePack.json")
        let fake = try XCTUnwrap(Bundle(path: dir))
        let data = try XCTUnwrap(RulePack.bundledData(mainBundle: fake))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"version":1,"platform":"macos","rules":[]}"#)
    }

    func testBundledDataFindsResourceBundleInCandidateDirectory() throws {
        let dir = TestEnv.makeTempDir("pack")
        defer { TestEnv.remove(dir) }
        let bundleDir = dir + "/DiskCleaner_CleanerCore.bundle"
        try FileManager.default.createDirectory(atPath: bundleDir, withIntermediateDirectories: true)
        try TestEnv.write(#"{"version":1,"platform":"macos","rules":[]}"#, to: bundleDir + "/RulePack.json")
        let missing = URL(fileURLWithPath: TestEnv.makeTempDir("nopack"))
        defer { TestEnv.remove(missing.path) }
        let data = try XCTUnwrap(RulePack.bundledData(searching: [missing, URL(fileURLWithPath: dir)], fallback: nil))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"version":1,"platform":"macos","rules":[]}"#)
    }

    func testSearchDirectoriesFollowSymlinkedExecutableIntoAppBundle() throws {
        let dir = TestEnv.makeTempDir("symlinked-cli")
        defer { TestEnv.remove(dir) }
        let macOS = dir + "/X.app/Contents/MacOS"
        try TestEnv.write("", to: macOS + "/dclean")
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/bin/dclean", withDestinationPath: macOS + "/dclean")

        let dirs = RulePack.searchDirectories(resourceURL: nil, bundleURL: URL(fileURLWithPath: dir + "/bin"),
                                              executableURL: URL(fileURLWithPath: dir + "/bin/dclean"))
        let real = URL(fileURLWithPath: macOS).resolvingSymlinksInPath()
        XCTAssertTrue(dirs.contains(real))
        XCTAssertTrue(dirs.contains(real.deletingLastPathComponent().appendingPathComponent("Resources")))
    }

    func testBundledDataWithoutResourceBundleOrFallbackIsNil() {
        let empty = TestEnv.makeTempDir("nopack")
        defer { TestEnv.remove(empty) }
        XCTAssertNil(RulePack.bundledData(searching: [URL(fileURLWithPath: empty)], fallback: nil))
    }

    #if DEBUG
    /// 只有 DEBUG 构建才兜底用 Bundle.module
    func testBundledDataFallsBackToModuleBundle() throws {
        let empty = try XCTUnwrap(Bundle(path: TestEnv.makeTempDir("nopack")))
        XCTAssertNotNil(RulePack.bundledData(mainBundle: empty))
    }
    #endif
}
