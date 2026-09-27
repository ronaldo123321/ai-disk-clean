import XCTest
import CleanerCore
@testable import AppCore

final class ResultSummaryTests: XCTestCase {
    func result(_ id: String, _ outcome: RunOutcome, reason: OutcomeReason? = nil, estimated: Int64 = 0) -> ItemRunResult {
        ItemRunResult(itemID: id, title: id, outcome: outcome, estimatedBytes: estimated, recoveredBytes: 0, reason: reason)
    }

    func report(_ results: [ItemRunResult], freed: Int64) -> RunReport {
        RunReport(batchID: "b", startedAt: Date(), finishedAt: Date(), freeBefore: 0, freeAfter: freed,
                  results: results, serviceIssues: [], regrowNotes: [])
    }

    func testGroupsSkippedAndFailedByReason() {
        let summary = ResultSummary(report: report([
            result("a", .done),
            result("b", .skipped("PyCharm 在运行"), reason: .appRunning),
            result("c", .skipped("Chrome 在运行"), reason: .appRunning),
            result("d", .failed("命令失败"), reason: .commandFailed),
        ], freed: 10), commandItemIDs: [])
        XCTAssertEqual(summary.skippedGroups.map(\.reason), [.appRunning])
        XCTAssertEqual(summary.skippedGroups.first?.results.map(\.itemID), ["b", "c"])
        XCTAssertEqual(summary.failedGroups.map(\.reason), [.commandFailed])
        XCTAssertEqual(summary.doneCount, 1)
    }

    func testGapHintWhenFreedFarBelowCommandEstimate() {
        let big: Int64 = 2 << 30
        let summary = ResultSummary(report: report([result("npm", .done, estimated: big)], freed: big / 4),
                                    commandItemIDs: ["npm"])
        XCTAssertNotNil(summary.gapHint)
        let fine = ResultSummary(report: report([result("npm", .done, estimated: big)], freed: big),
                                 commandItemIDs: ["npm"])
        XCTAssertNil(fine.gapHint)
    }

    func testNoGapHintWhenFreeSpaceUnmeasured() {
        let big: Int64 = 2 << 30
        let unmeasured = RunReport(batchID: "b", startedAt: Date(), finishedAt: Date(), freeBefore: nil, freeAfter: nil,
                                   results: [result("npm", .done, estimated: big)], serviceIssues: [], regrowNotes: [])
        XCTAssertNil(ResultSummary(report: unmeasured, commandItemIDs: ["npm"]).gapHint)
    }
}
