import XCTest
import CleanerCore
@testable import AppCore

final class RecoveryOverviewTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ path: String, bytes: Int64, item: String?, title: String?, state: RecoveryEntry.State = .stored) -> RecoveryEntry {
        RecoveryEntry(originalPath: path, storedPath: "/r/" + path, bytes: bytes, state: state, identity: nil,
                      contentDigest: nil, itemID: item, itemTitle: title)
    }

    func testGroupsEntriesByItemAndComputesDaysLeft() {
        let recent = RecoveryBatch(id: "new", createdAt: now.addingTimeInterval(-86_400), entries: [
            entry("/a/1", bytes: 10, item: "p", title: "项目 P"),
            entry("/a/2", bytes: 5, item: "p", title: "项目 P"),
            entry("/b", bytes: 7, item: "c", title: "Chrome"),
            entry("/gone", bytes: 99, item: "g", title: "已还原", state: .restored),
        ])
        let old = RecoveryBatch(id: "old", createdAt: now.addingTimeInterval(-8 * 86_400), entries: [
            entry("/x", bytes: 3, item: nil, title: nil),
        ])
        let overview = RecoveryOverview.make(batches: [old, recent], orphans: ["bad"],
                                             occupied: { $0.entries.filter { $0.state == .stored }.reduce(0) { $0 + $1.bytes } },
                                             now: now)
        XCTAssertEqual(overview.batches.map(\.id), ["new", "old"])
        XCTAssertEqual(overview.batches[0].items.map(\.title), ["项目 P", "Chrome"])
        XCTAssertEqual(overview.batches[0].items.map(\.bytes), [15, 7])
        XCTAssertEqual(overview.batches[0].daysLeft, 6)
        XCTAssertEqual(overview.batches[1].daysLeft, 0)
        XCTAssertEqual(overview.batches[1].items.first?.title, "x")
        XCTAssertFalse(overview.batches[1].items.first!.restorableIndividually)
        XCTAssertEqual(overview.totalBytes, 25)
        XCTAssertEqual(overview.expiredBatchIDs, ["old"])
        XCTAssertEqual(overview.orphans, ["bad"])
    }
}
