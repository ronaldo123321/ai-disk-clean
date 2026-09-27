import XCTest
@testable import CleanerCore

/// spec §10：隔离往返、purge、命令委托等测试所依赖的文件层语义
final class FileOperationsTests: XCTestCase {
    private var root: String!

    override func setUp() {
        root = TestEnv.makeTempDir("dclean-files")
    }

    override func tearDown() {
        TestEnv.remove(root!)
        root = nil
    }

    // ---- 真实实现：符号链接语义（spec §5 第 4 层） ----

    func testRealRemoveSymlinkOnlyRemovesTheLink() throws {
        let target = root + "/target.txt"
        try TestEnv.write("precious", to: target)
        let link = root + "/nested/link"
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let files = RealFileOperations()
        try files.removeItem(atPath: link)

        XCTAssertFalse(files.fileExists(link))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "precious")
    }

    func testRealRemoveDirectoryDoesNotFollowSymlinksInside() throws {
        let outsideTarget = root + "/outside-target"
        try TestEnv.write("precious", to: outsideTarget)

        let dir = root + "/dir"
        try TestEnv.makeTree(root: dir, files: ["a.txt": "a", "sub/b.txt": "b"])
        try FileManager.default.createSymbolicLink(atPath: dir + "/sub/link",
                                                   withDestinationPath: outsideTarget)

        let files = RealFileOperations()
        try files.removeItem(atPath: dir)

        XCTAssertFalse(files.fileExists(dir))
        XCTAssertEqual(try String(contentsOfFile: outsideTarget, encoding: .utf8), "precious")
    }

    func testRealTruncateRefusesSymlink() throws {
        let target = root + "/target.txt"
        try TestEnv.write("precious", to: target)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let files = RealFileOperations()
        XCTAssertThrowsError(try files.truncateFile(atPath: link)) { error in
            guard case FileOpError.refuseSymlink = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "precious")
    }

    func testRealTruncateEmptiesRegularFile() throws {
        let file = root + "/deep/path/log.txt"
        try TestEnv.makeTree(root: root, files: ["deep/path/log.txt": "0123456789"])
        let files = RealFileOperations()
        try files.truncateFile(atPath: file)
        XCTAssertEqual(files.attributesIfExist(atPath: file)?.size, 0)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "")
    }

    func testRealAttributesUseLstatSemantics() throws {
        let target = root + "/t.txt"
        try TestEnv.write("12345", to: target)
        let link = root + "/l.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let files = RealFileOperations()

        let linkAttrs = try XCTUnwrap(files.attributesIfExist(atPath: link))
        XCTAssertTrue(linkAttrs.isSymbolicLink)
        XCTAssertFalse(linkAttrs.isDirectory)
        XCTAssertTrue(files.fileExists(link))

        try FileManager.default.createSymbolicLink(atPath: root + "/broken", withDestinationPath: "/nonexistent-xyz")
        XCTAssertTrue(files.fileExists(root + "/broken")) // 坏链接 lstat 仍存在
        XCTAssertNil(files.realPath(ofPath: root + "/broken"))
    }

    func testRealMoveAndChildren() throws {
        try TestEnv.makeTree(root: root, files: ["a/2.txt": "2", "a/1.txt": "1", "b/.keep": ""])
        let files = RealFileOperations()
        XCTAssertEqual(try files.childrenOfDirectory(atPath: root + "/a"),
                       [root + "/a/1.txt", root + "/a/2.txt"])
        try files.moveItem(fromPath: root + "/a/1.txt", toPath: root + "/b/1.txt")
        XCTAssertTrue(files.fileExists(root + "/b/1.txt"))
        XCTAssertFalse(files.fileExists(root + "/a/1.txt"))
    }

    func testRealVolumeSummary() {
        let files = RealFileOperations()
        let summary = files.volumeSummary(atPath: root)
        XCTAssertNotNil(summary)
        XCTAssertGreaterThan(summary!.totalBytes, 0)
    }

    func testRealAllocatedSizeIsReported() throws {
        // 稀疏大文件的逻辑大小会虚高（如 Docker.raw 标称 460G），报告必须用磁盘占用口径
        let file = root + "/f.bin"
        FileManager.default.createFile(atPath: file, contents: Data())
        let files = RealFileOperations()
        let attrs = try XCTUnwrap(files.attributesIfExist(atPath: file))
        XCTAssertEqual(attrs.size, 0)
        XCTAssertGreaterThanOrEqual(attrs.allocatedSize, 0)
        // 有内容的文件，占用 >= 逻辑大小所在块
        try TestEnv.write("0123456789", to: root + "/g.bin")
        let g = try XCTUnwrap(files.attributesIfExist(atPath: root + "/g.bin"))
        XCTAssertGreaterThan(g.allocatedSize, 0)
        XCTAssertEqual(g.size, 10)
    }

    // ---- 内存实现：等价语义（spec §10：单测用内存假文件树） ----

    func testInMemoryTreeAndSubtreeRemoval() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/data/store/a.txt", size: 3)
        mem.makeFile("/Users/t/data/store/sub/b.txt", size: 5)
        mem.makeFile("/Users/t/data/keep.txt", size: 1)

        XCTAssertEqual(mem.apparentSize(of: "/Users/t/data/store"), 8)
        try mem.removeItem(atPath: "/Users/t/data/store")
        XCTAssertFalse(mem.fileExists("/Users/t/data/store"))
        XCTAssertFalse(mem.fileExists("/Users/t/data/store/sub/b.txt"))
        XCTAssertTrue(mem.fileExists("/Users/t/data/keep.txt"))
    }

    func testInMemorySymlinkAndRealPath() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/outside.txt", size: 7)
        mem.makeSymlink(at: "/Users/t/data/link", target: "/Users/t/outside.txt")

        let attrs = try XCTUnwrap(mem.attributesIfExist(atPath: "/Users/t/data/link"))
        XCTAssertTrue(attrs.isSymbolicLink)
        XCTAssertEqual(mem.realPath(ofPath: "/Users/t/data/link"), "/Users/t/outside.txt")
        // 只删链接
        try mem.removeItem(atPath: "/Users/t/data/link")
        XCTAssertTrue(mem.fileExists("/Users/t/outside.txt"))
        XCTAssertNil(mem.entry(at: "/Users/t/data/link"))
    }

    func testInMemoryMoveRenamesSubtree() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        mem.makeFile("/Users/t/a/x.txt", size: 1)
        mem.makeFile("/Users/t/a/sub/y.txt", size: 2)
        mem.makeDirectory("/Users/t/b")

        try mem.moveItem(fromPath: "/Users/t/a", toPath: "/Users/t/b/a")
        XCTAssertTrue(mem.fileExists("/Users/t/b/a/x.txt"))
        XCTAssertTrue(mem.fileExists("/Users/t/b/a/sub/y.txt"))
        XCTAssertFalse(mem.fileExists("/Users/t/a"))
        // 目标已存在应报错
        XCTAssertThrowsError(try mem.moveItem(fromPath: "/Users/t/b/a", toPath: "/Users/t/b"))
    }

    func testInMemoryReadWriteAppend() throws {
        let mem = InMemoryFileOperations(home: "/Users/t")
        try mem.writeFile(Data("line1\n".utf8), toPath: "/Users/t/log")
        try mem.appendFile(Data("line2\n".utf8), toPath: "/Users/t/log")
        XCTAssertEqual(mem.readFile(atPath: "/Users/t/log"), Data("line1\nline2\n".utf8))
        // truncate 后为 0 字节
        try mem.truncateFile(atPath: "/Users/t/log")
        XCTAssertEqual(mem.readFile(atPath: "/Users/t/log"), Data())
        // 符号链接拒绝 truncate
        mem.makeSymlink(at: "/Users/t/link", target: "/Users/t/log")
        XCTAssertThrowsError(try mem.truncateFile(atPath: "/Users/t/link"))
    }
}
