import XCTest
@testable import CleanerCore

final class PriorityTwoTests: XCTestCase {
    let home = "/Users/tester"
    func testSpaceBrowserDescendsWithoutFollowingLinksOrPrivateAndExcludedTrees() throws {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/work/app/cache.bin", size: 42)
        files.makeFile(home + "/Documents/private", size: 99)
        files.makeFile(home + "/excluded/data", size: 99)
        files.makeSymlink(at: home + "/link", target: home + "/Documents")
        let browser = SpaceBrowser(files: files)
        let result = try browser.list(home, options: ScanOptions(excludedPaths: [home + "/excluded"]), cancellation: OperationCancellation())
        XCTAssertEqual(result.entries.first { $0.path == home + "/work" }?.bytes, 42)
        for name in ["Documents", "excluded", "link"] {
            let row = try XCTUnwrap(result.entries.first { $0.path == home + "/" + name })
            XCTAssertNil(row.bytes)
            XCTAssertFalse(row.directory)
        }
        XCTAssertTrue(result.incomplete)
        XCTAssertThrowsError(try browser.list(home + "/Documents", options: ScanOptions(), cancellation: OperationCancellation()))
        let child = try browser.list(home + "/work", options: ScanOptions(), cancellation: OperationCancellation())
        XCTAssertEqual(child.entries.first?.bytes, 42)
    }
    func testSpaceBudgetAndCancellationAreUnknownNotZero() throws {
        let files = InMemoryFileOperations(home: home)
        files.makeFile(home + "/work/a", size: 42)
        let browser = SpaceBrowser(files: files)
        XCTAssertNil(try browser.list(home, options: ScanOptions(), cancellation: OperationCancellation(), limit: 0).entries.first?.bytes)
        let cancelled = OperationCancellation(); cancelled.cancel()
        XCTAssertTrue(try browser.list(home, options: ScanOptions(), cancellation: cancelled).incomplete)
    }
    func testAlternateRestorePreservesConflictAndPersistsAudit() throws {
        let files = InMemoryFileOperations(home: home)
        let path = home + "/work/app/cache"
        files.makeFile(path + "/old", size: 42)
        let audit = AuditLog(files: files, path: EnginePaths.auditLog(home: home))
        let store = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files, audit: audit)
        try store.begin(batchID: "p2", now: Date()).admit(path: path, bytes: 42, itemID: "cache", itemTitle: "Cache")
        files.makeFile(path + "/new", size: 7)
        XCTAssertFalse(store.restore(batchID: "p2").errors.isEmpty)
        let alternate = home + "/restored"
        files.makeDirectory(alternate)
        let result = store.restore(batchID: "p2", itemIDs: ["cache"], destinationDirectory: alternate)
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        XCTAssertTrue(files.fileExists(path + "/new"))
        XCTAssertTrue(files.fileExists(alternate + "/cache/old"))
        XCTAssertFalse(files.fileExists(path + "/old"))
        let recorded = AuditLog(files: files, path: audit.path).readAll().last
        XCTAssertEqual(recorded?.op, "restore.done")
        XCTAssertEqual(recorded?.action, "alternate")
        XCTAssertEqual(recorded?.paths, [path])
    }
    func testAlternateRestoreRejectsNonemptyOutsideAndProtectedDestinations() throws {
        let files = InMemoryFileOperations(home: home)
        let path = home + "/work/cache"
        files.makeFile(path + "/old", size: 42)
        let store = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
        try store.begin(batchID: "p2", now: Date()).admit(path: path, bytes: 42, itemID: "cache", itemTitle: "Cache")
        files.makeFile(home + "/nonempty/keep", size: 1)
        files.makeDirectory(home + "/Documents/empty")
        files.makeDirectory("/tmp/empty")
        for destination in [home + "/nonempty", home + "/Documents/empty", "/tmp/empty"] {
            XCTAssertFalse(store.restore(batchID: "p2", itemIDs: ["cache"], destinationDirectory: destination).errors.isEmpty)
            XCTAssertEqual(store.list().count, 1)
        }
    }
    func testLegacyAuditStillDecodes() throws {
        let data = Data(#"{"ts":"2026-10-14T00:00:00Z","op":"run.finish","detail":"old"}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(AuditEvent.self, from: data)
        XCTAssertNil(event.paths)
        XCTAssertNil(event.batchID)
    }
}
