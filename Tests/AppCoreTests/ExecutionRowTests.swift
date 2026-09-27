import XCTest
import CleanerCore
@testable import AppCore

final class ExecutionRowTests: XCTestCase {
    func result(_ id: String, _ outcome: RunOutcome) -> ItemRunResult {
        ItemRunResult(itemID: id, title: id, outcome: outcome, estimatedBytes: 0, recoveredBytes: 0, reason: nil)
    }

    func testEveryItemHasAStatus() {
        var progress = AppModel.ExecutionProgress(total: 5)
        progress.finished = [result("a", .done), result("b", .skipped("Chrome 在运行")), result("c", .failed("命令失败"))]
        progress.currentIndex = 3
        progress.currentStep = "正在暂停 记忆服务…"
        let rows = ExecutionRow.make(items: ["a", "b", "c", "d", "e"].map { makeItem($0) }, progress: progress)
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(rows.map(\.status), [.done, .skipped("Chrome 在运行"), .failed("命令失败"),
                                            .running(step: "正在暂停 记忆服务…"), .waiting])
        XCTAssertEqual(rows.map(\.status.title), ["完成", "跳过", "失败", "进行中", "等待"])
    }

    func testFinishedResultWinsOverCurrentIndex() {
        var progress = AppModel.ExecutionProgress(total: 1)
        progress.currentIndex = 0
        progress.finished = [result("a", .done)]
        XCTAssertEqual(ExecutionRow.make(items: [makeItem("a")], progress: progress).map(\.status), [.done])
    }
}
