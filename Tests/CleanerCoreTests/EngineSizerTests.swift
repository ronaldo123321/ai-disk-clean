import XCTest
@testable import CleanerCore

final class EngineSizerTests: XCTestCase {
    func testRealAttributesReportHardLinkCount() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write("hello", to: dir + "/a")
        try FileManager.default.linkItem(atPath: dir + "/a", toPath: dir + "/b")
        let files = RealFileOperations(home: dir)
        XCTAssertEqual(files.attributesIfExist(atPath: dir + "/a")?.linkCount, 2)
    }

    func testEnginePathsLiveUnderDcleanV3() {
        XCTAssertEqual(EnginePaths.recoveryDirectory(home: "/Users/t"), "/Users/t/.dclean-v3/recovery")
        XCTAssertEqual(EnginePaths.auditLog(home: "/Users/t"), "/Users/t/.dclean-v3/audit.log")
        XCTAssertEqual(EnginePaths.userRules(home: "/Users/t"), "/Users/t/.dclean-v3/user-rules.json")
    }

    func testHardLinksInsideScopeCountOnceAndAreReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/scope/a")
        try FileManager.default.linkItem(atPath: dir + "/scope/a", toPath: dir + "/scope/b")
        let files = RealFileOperations(home: dir)
        let size = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/scope/a")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/scope"])
        XCTAssertEqual(m.apparent, size)
        XCTAssertEqual(m.reclaimable, size)
        XCTAssertEqual(m.perPath[dir + "/scope"], size)
    }

    func testHardLinkWithCopyOutsideScopeIsNotReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/cache/a")
        try TestEnv.write(String(repeating: "y", count: 10_000), to: dir + "/cache/plain")
        try FileManager.default.createDirectory(atPath: dir + "/venv", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: dir + "/cache/a", toPath: dir + "/venv/a")
        let files = RealFileOperations(home: dir)
        let linked = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/cache/a")).allocatedSize
        let plain = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/cache/plain")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/cache"])
        XCTAssertEqual(m.apparent, linked + plain)
        XCTAssertEqual(m.reclaimable, plain)
    }

    func testMissingPathsCountZero() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        let m = Sizer(files: files).measure([EngineFixture.home + "/nope"])
        XCTAssertEqual(m.apparent, 0)
        XCTAssertEqual(m.reclaimable, 0)
    }

    func testUnreadableDirectoriesAreReportedNotGuessed() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/scope/locked")
            TestEnv.remove(dir)
        }
        try TestEnv.write("secret", to: dir + "/scope/locked/f")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir + "/scope/locked")
        let m = Sizer(files: RealFileOperations(home: dir)).measure([dir + "/scope"])
        XCTAssertEqual(m.unreadable, [dir + "/scope/locked"])
        XCTAssertEqual(m.apparent, 0)
    }

    func testInMemoryFilesWithoutLinkInfoAreFullyReclaimable() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/a", size: 300)
        files.makeFile(EngineFixture.home + "/.npm/_cacache/sub/b", size: 200)
        let m = Sizer(files: files).measure([EngineFixture.home + "/.npm/_cacache"])
        XCTAssertEqual(m.apparent, 500)
        XCTAssertEqual(m.reclaimable, 500)
    }

    func testOverlappingRootDropsNestedDuplicateAndExcludesOutsideLinkFromReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/scope/sub/f")
        try FileManager.default.createDirectory(atPath: dir + "/outside", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: dir + "/scope/sub/f", toPath: dir + "/outside/f")
        let files = RealFileOperations(home: dir)
        let size = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/scope/sub/f")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/scope", dir + "/scope/sub"])
        XCTAssertEqual(m.apparent, size)
        XCTAssertEqual(m.reclaimable, 0)
        XCTAssertEqual(m.perPath.keys.sorted(), [dir + "/scope"])
    }

    func testDuplicateRootIsMeasuredOnce() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/scope/a")
        let files = RealFileOperations(home: dir)
        let once = Sizer(files: files).measure([dir + "/scope"])
        let twice = Sizer(files: files).measure([dir + "/scope", dir + "/scope"])
        XCTAssertEqual(twice, once)
    }

    func testHardLinkSplitAcrossTwoRootsCountsOnceAndIsReclaimable() throws {
        let dir = TestEnv.makeTempDir("sizer")
        defer { TestEnv.remove(dir) }
        try TestEnv.write(String(repeating: "x", count: 10_000), to: dir + "/rootA/a")
        try FileManager.default.createDirectory(atPath: dir + "/rootB", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: dir + "/rootA/a", toPath: dir + "/rootB/b")
        let files = RealFileOperations(home: dir)
        let size = try XCTUnwrap(files.attributesIfExist(atPath: dir + "/rootA/a")).allocatedSize
        let m = Sizer(files: files).measure([dir + "/rootA", dir + "/rootB"])
        XCTAssertEqual(m.apparent, size)
        XCTAssertEqual(m.reclaimable, size)
    }

    func testCancelledSizerStopsEarly() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/a/b", size: 10)
        let cancellation = OperationCancellation()
        cancellation.cancel()
        XCTAssertEqual(Sizer(files: files, cancellation: cancellation).measure([EngineFixture.home + "/a"]).apparent, 0)
    }

    func testCancellingAfterFirstRootStopsSubsequentMeasurement() {
        let files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(EngineFixture.home + "/rootA/a", size: 100)
        files.makeFile(EngineFixture.home + "/rootB/b", size: 200)
        let cancellation = OperationCancellation()
        let sizer = Sizer(files: files, cancellation: cancellation)
        let first = sizer.measure([EngineFixture.home + "/rootA"])
        XCTAssertEqual(first.apparent, 100)
        cancellation.cancel()
        let second = sizer.measure([EngineFixture.home + "/rootB"])
        XCTAssertEqual(second.apparent, 0)
    }

    func testIsVanishedRecognizesNotFoundVariantsOnly() {
        XCTAssertTrue(Sizer.isVanished(FileOpError.notFound("x")))
        XCTAssertTrue(Sizer.isVanished(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(Sizer.isVanished(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertTrue(Sizer.isVanished(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))))
        XCTAssertFalse(Sizer.isVanished(CocoaError(.fileReadNoPermission)))
    }
}
