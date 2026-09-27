import XCTest
@testable import AppCore

final class FormatTests: XCTestCase {
    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-20), now: now), "刚刚")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-600), now: now), "10 分钟前")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-7_200), now: now), "2 小时前")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-259_200), now: now), "3 天前")
    }

    func testBytesUsesEngineFormatting() {
        XCTAssertEqual(Format.bytes(0), "0 B")
        XCTAssertEqual(Format.bytes(1_572_864), "1.5 MB")
    }
}
