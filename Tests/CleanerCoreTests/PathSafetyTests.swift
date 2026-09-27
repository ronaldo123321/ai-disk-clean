import XCTest
@testable import CleanerCore

/// spec §10 用例表：围栏（层 2、4）、禁区（层 3）、路径断言（层 5）
final class PathSafetyTests: XCTestCase {
    private var root: String!
    private var files: RealFileOperations!
    private var safety: PathSafety!

    override func setUpWithError() throws {
        root = TestEnv.makeTempDir("dclean-safety")
        files = RealFileOperations()
        safety = PathSafety(home: root, files: files)
    }

    override func tearDown() {
        TestEnv.remove(root!)
        root = nil
        files = nil
        safety = nil
    }

    // ---- 展开 / 规范化 / 深度 ----

    func testExpandTilde() {
        XCTAssertEqual(safety.expandTilde("~"), root)
        XCTAssertEqual(safety.expandTilde("~/.cache/uv"), root + "/.cache/uv")
        XCTAssertEqual(safety.expandTilde("/usr/bin"), "/usr/bin")
        XCTAssertEqual(safety.expandTilde("~other/x"), "~other/x") // 不支持 ~user，原样返回
    }

    func testNormalizeResolvesDotDotLexically() {
        XCTAssertEqual(safety.normalize("/a/b/../c"), "/a/c")
        XCTAssertEqual(safety.normalize("/a/./b/"), "/a/b")
        XCTAssertEqual(safety.normalize("a//b"), "a/b")
        XCTAssertEqual(safety.normalize("/..", ), "/")
        XCTAssertEqual(safety.normalize("~", ), root)
    }

    func testDepthCounting() {
        XCTAssertEqual(safety.depth(of: "/"), 0)
        XCTAssertEqual(safety.depth(of: "/Users"), 1)
        XCTAssertEqual(safety.depth(of: root), PathSafety.depth(of: root))
        XCTAssertGreaterThanOrEqual(safety.depth(of: root + "/a/b"), 3)
    }

    // ---- 第 3 层：禁区两分类（2026-09-17 修订） ----

    func testExactForbiddenHitsOnlyThePathItself() {
        // 精确匹配：/ 、/Users、$HOME 本身
        XCTAssertThrowsError(try safety.assertAllowed("/")) { error in
            guard case PathSafetyError.forbiddenExact("/") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try safety.assertAllowed("/Users")) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try safety.assertAllowed(root)) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
    }

    func testUsersDescendantsAreNotForbidden() {
        // 修正前缀匹配 bug 的回归用例：/Users 的后代不是禁区
        XCTAssertNoThrow(try safety.assertAllowed("/Users/me/.cache/uv"))
        XCTAssertNoThrow(try safety.assertAllowed(root + "/.cache/uv"))
    }

    func testTreeForbiddenCoversDescendants() {
        let forbidden: [String] = [
            "/System",
            "/System/Library/x",
            root + "/Documents",
            root + "/Documents/2024/report.pdf",
            root + "/.ssh",
            root + "/.ssh/id_rsa",
            root + "/Library/Keychains",
        ]
        for p in forbidden {
            XCTAssertThrowsError(try safety.assertAllowed(p), p) { error in
                guard case PathSafetyError.forbiddenTree = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testGitDirectoriesAreForbiddenAnywhere() {
        XCTAssertThrowsError(try safety.assertAllowed(root + "/proj/.git"))
        XCTAssertThrowsError(try safety.assertAllowed(root + "/proj/.git/objects/ab/cdef"))
        XCTAssertNoThrow(try safety.assertAllowed(root + "/proj/repo.git")) // .git 后缀不算
        XCTAssertNoThrow(try safety.assertAllowed(root + "/proj/.github/workflows/x.yml"))
    }

    // ---- 第 5 层：路径断言 ----

    func testTooShallowPathsAreRejected() {
        // "/h" 只有 1 层且不等于任何禁区 → 浅路径拒绝
        XCTAssertThrowsError(try safety.assertAllowed("/h")) { error in
            guard case PathSafetyError.tooShallow = error else { return XCTFail("\(error)") }
        }
        // 禁区判定先于深度判定：把 home 抬到浅层路径时，home 本身报精确禁区而非浅路径
        let shallowSafety = PathSafety(home: "/h", files: files)
        XCTAssertThrowsError(try shallowSafety.assertAllowed("/h")) { error in
            guard case PathSafetyError.forbiddenExact = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try shallowSafety.assertAllowed("/h/a")) { error in
            guard case PathSafetyError.tooShallow = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try shallowSafety.assertAllowed("/h/a/b"))
    }

    // ---- 第 2、4 层：围栏 ----

    func testFenceAllowsSymlinkLeafButFlagsIt() throws {
        let outside = root + "/outside-target"
        try TestEnv.write("precious", to: outside)
        let insideRoot = root + "/rule-root"
        let link = insideRoot + "/link"
        try FileManager.default.createDirectory(atPath: insideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        // macOS 的 /var → /private/var，所以与 realpath 结果比对
        let result = try safety.checkFence(candidate: link, roots: [insideRoot])
        XCTAssertEqual(result, .symlinkLeaf(resolved: files.realPath(ofPath: outside)))
    }

    func testFenceRejectsEscapeThroughIntermediateDirectorySymlink() throws {
        let realDir = root + "/real-dir"
        try FileManager.default.createDirectory(atPath: realDir + "/sub", withIntermediateDirectories: true)
        try TestEnv.write("x", to: realDir + "/sub/file.txt")

        let insideRoot = root + "/rule-root"
        try FileManager.default.createDirectory(atPath: insideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: insideRoot + "/dirlink", withDestinationPath: realDir)

        // 候选本身是常规文件，但路径中段穿过符号链接 → realpath 逃逸
        XCTAssertThrowsError(try safety.checkFence(candidate: insideRoot + "/dirlink/sub/file.txt",
                                                   roots: [insideRoot])) { error in
            guard case PathSafetyError.escapedFence = error else { return XCTFail("\(error)") }
        }
    }

    func testFenceRejectsCandidateOutsideAllRoots() throws {
        XCTAssertThrowsError(try safety.checkFence(candidate: root + "/elsewhere/file",
                                                   roots: [root + "/rule-root"])) { error in
            guard case PathSafetyError.outsideAllRoots = error else { return XCTFail("\(error)") }
        }
    }

    func testFenceReportsMissingCandidate() throws {
        XCTAssertThrowsError(try safety.checkFence(candidate: root + "/rule-root/ghost",
                                                   roots: [root + "/rule-root"])) { error in
            guard case PathSafetyError.candidateMissing = error else { return XCTFail("\(error)") }
        }
    }

}
