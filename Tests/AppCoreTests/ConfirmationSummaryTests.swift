import XCTest
import CleanerCore
@testable import AppCore

final class ConfirmationSummaryTests: XCTestCase {
    let chrome = QuitApp(name: "Chrome", bundleID: "com.google.Chrome")
    let pycharm = QuitApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm", mayQuitForUser: false)
    let edge = QuitApp(name: "Edge", bundleID: "com.microsoft.edgemac")

    func testSplitsRecoverableIrreversibleAndApps() {
        let items = [
            makeItem("npm", action: .command(["npm", "cache", "clean", "--force"]), bytes: 100),
            makeItem("chrome", tier: .suggested, bytes: 300, quitApps: [chrome]),
            makeItem("jb", tier: .suggested, bytes: 200, quitApps: [pycharm]),
            makeItem("edge", tier: .suggested, bytes: 50, quitApps: [edge]),
            makeItem("show", tier: .displayOnly, bytes: 999),
        ]
        let summary = ConfirmationSummary.make(items: items, isRunning: { $0 != "com.microsoft.edgemac" })
        XCTAssertEqual(summary.items.map(\.id), ["npm", "chrome", "jb", "edge"])
        XCTAssertEqual(summary.irreversible.map(\.id), ["npm"])
        XCTAssertEqual(summary.recoverable.map(\.id), ["chrome", "jb", "edge"])
        XCTAssertEqual(summary.estimatedBytes, 650)
        XCTAssertEqual(summary.appsWeCanQuit, [chrome])
        XCTAssertEqual(summary.appsUserMustQuit, [pycharm])
    }

    func testDeduplicatesAppsAcrossItems() {
        let items = [makeItem("a", quitApps: [chrome]), makeItem("b", quitApps: [chrome])]
        XCTAssertEqual(ConfirmationSummary.make(items: items, isRunning: { _ in true }).appsWeCanQuit, [chrome])
    }
}
