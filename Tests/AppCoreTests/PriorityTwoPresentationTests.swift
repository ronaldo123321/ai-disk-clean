import XCTest
import CleanerCore
@testable import AppCore

final class PriorityTwoPresentationTests: XCTestCase {
    func testSuccessfulRestoreInvalidatesSelectionUntilRescan() {
        let engine = FakeEngineService()
        engine.scanResult.items = [makeItem("a")]
        let model = AppModel(engine: engine, now: { FakeEngineService.scannedAt }, background: { $0() }, main: { $0() })
        model.startScan()
        XCTAssertFalse(model.selectedIDs.isEmpty)
        model.restore(batchID: "fixture", itemIDs: nil)
        XCTAssertTrue(model.requiresRescan)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        model.select(["a"], selected: true)
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    func testHistoryGroupsStructuredEventsAndKeepsLegacyUnknown() {
        let groups = HistoryBatch.make([
            AuditEvent(op: "run.start", detail: "old 2 项"),
            AuditEvent(op: "run.item.result", detail: "legacy done"),
            AuditEvent(op: "run.item.result", detail: "new done", batchID: "new"),
            AuditEvent(op: "restore.done", detail: "destination", batchID: "new"),
            AuditEvent(op: "restore.intent", detail: "not a success", batchID: "new")
        ])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.id == "new" }?.events.count, 2)
        XCTAssertEqual(groups.first { $0.id == "旧记录（批次未知）" }?.events.count, 1)
    }
}
