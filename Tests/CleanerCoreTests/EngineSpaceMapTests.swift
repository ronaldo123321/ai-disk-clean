import XCTest
@testable import CleanerCore

final class EngineSpaceMapTests: XCTestCase {
    let home = EngineFixture.home

    func testLargeUnknownDirectoriesAreDisplayOnly() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Application Support/VBLobsterAI/data.bin", size: 3_000)
        files.makeFile(home + "/Library/Application Support/Small/a", size: 10)
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:])
        XCTAssertEqual(items.map(\.title), ["未识别：~/Library/Application Support/VBLobsterAI"])
        XCTAssertEqual(items[0].tier, .displayOnly)
        XCTAssertEqual(items[0].category, .other)
        XCTAssertEqual(items[0].apparentBytes, 3_000)
        XCTAssertEqual(items[0].action.type, .noAction)
    }

    func testCoveredBytesAreSubtractedAndCoveredDirectoriesSkipped() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 5_000)
        files.makeFile(home + "/.codex/logs.sqlite", size: 2_000)
        files.makeFile(home + "/.cache/uv/a", size: 9_000)
        let covered = [home + "/.codex/sessions": Int64(5_000), home + "/.cache/uv": Int64(9_000)]
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: covered)
        XCTAssertEqual(items.map(\.id), ["space:" + home + "/.codex"])
        XCTAssertEqual(items[0].apparentBytes, 2_000)
    }

    func testPrivacyAndForbiddenAreasAreNeverShown() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Documents/big", size: 9_000)
        files.makeFile(home + "/Desktop/big", size: 9_000)
        files.makeFile(home + "/.ssh/big", size: 9_000)
        files.makeFile(home + "/.Trash/big", size: 9_000)
        XCTAssertEqual(SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:]), [])
    }

    func testContainersDirectoryIsNotListed() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Containers/com.some.app/big", size: 9_000)
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:])
        XCTAssertEqual(items, [])
    }

    func testDownloadsDirectoryIsNotListed() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Downloads/big-file.zip", size: 9_000)
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:])
        XCTAssertEqual(items, [])
    }

    func testCoveredKeyMatchIsCaseInsensitive() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.codex/sessions/a", size: 5_000)
        files.makeFile(home + "/.codex/logs.sqlite", size: 2_000)
        let covered = [home + "/.CODEX/sessions": Int64(5_000)]
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: covered)
        XCTAssertEqual(items.map(\.id), ["space:" + home + "/.codex"])
        XCTAssertEqual(items[0].apparentBytes, 2_000)
    }

    func testCaseVariantForbiddenRootIsNotListed() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.SSH/big", size: 9_000)
        XCTAssertEqual(SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:]), [])
    }

    func testGroupContainersDirectoryIsNotListed() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/Library/Group Containers/x/big", size: 9_000)
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: [:])
        XCTAssertEqual(items, [])
    }

    func testNestedCoveredKeysAreNotDoubleSubtracted() {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/.x/a/b/c", size: 4_000)
        files.makeFile(home + "/.x/other", size: 1_000)
        let covered = [home + "/.x/a": Int64(2_000), home + "/.x/a/b": Int64(1_000)]
        let items = SpaceMapDetector(threshold: 1_000).detect(EngineFixture.context(files), covered: covered)
        XCTAssertEqual(items.map(\.id), ["space:" + home + "/.x"])
        XCTAssertEqual(items[0].apparentBytes, 3_000)
    }
}
