import XCTest
@testable import CleanerCore

final class ScanScopeValidationTests: XCTestCase {
    func testHomeAllowedWithoutWeakeningDeletionGuard() throws {
        let files = InMemoryFileOperations(home: "/Users/tester")
        files.makeDirectory("/Users/tester")
        XCTAssertEqual(try ScanScopeValidation.validate("/Users/tester/", files: files), "/Users/tester")
        XCTAssertThrowsError(try PathSafety(home: "/Users/tester", files: files).assertAllowed("/Users/tester"))
    }
    func testWorkDirectoryAllowedButOutsideAndProtectedRejected() throws {
        let files = InMemoryFileOperations(home: "/Users/tester")
        for path in ["/Users/tester/work", "/Users/tester/Documents", "/Users/tester-other/work", "/Users/other"] { files.makeDirectory(path) }
        XCTAssertEqual(try ScanScopeValidation.validate("~/work", files: files), "/Users/tester/work")
        for path in ["/Users/tester/Documents", "/Users/tester-other/work", "/Users/other", "/Users/tester/missing"] {
            XCTAssertThrowsError(try ScanScopeValidation.validate(path, files: files), path)
        }
    }
    func testArbitrarySymlinkRejected() {
        let files = InMemoryFileOperations(home: "/Users/tester")
        files.makeDirectory("/Users/tester/work")
        files.makeSymlink(at: "/Users/tester/link", target: "/Users/tester/work")
        XCTAssertThrowsError(try ScanScopeValidation.validate("/Users/tester/link", files: files))
    }
    func testRealTemporaryHomeAliasesAcceptedAndIsolated() throws {
        let root = URL(fileURLWithPath: "/private/tmp/dclean-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/work"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").resolvingSymlinksInPath().path
        let files = RealFileOperations(home: home)
        let privateHome = root.appendingPathComponent("home").path
        XCTAssertEqual(try ScanScopeValidation.validate(privateHome, files: files), home)
        XCTAssertEqual(try ScanScopeValidation.validate(privateHome + "/work", files: files), home + "/work")
        XCTAssertThrowsError(try ScanScopeValidation.validate(NSHomeDirectory(), files: files))
    }
}
