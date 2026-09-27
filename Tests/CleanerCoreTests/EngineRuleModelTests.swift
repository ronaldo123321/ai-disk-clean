import XCTest
@testable import CleanerCore

final class EngineRuleModelTests: XCTestCase {
    let home = "/Users/tester"
    lazy var files = InMemoryFileOperations(home: home)
    lazy var safety = PathSafety(home: home, files: files)

    func rule(id: String = "r", tier: CleanTier = .safe, targets: [String] = ["~/.npm/_cacache"],
              action: RuleAction = .command(["npm", "cache", "clean", "--force"]),
              preconditions: RulePreconditions? = nil) -> CleanRule {
        CleanRule(id: id, name: "名称", app: "npm", category: .dev, tier: tier, detect: nil,
                  targets: targets, action: action, preconditions: preconditions,
                  copy: RuleCopy(what: "是什么", impact: "影响", regrows: nil))
    }

    func problems(_ r: CleanRule, _ origin: RuleOrigin = .bundled) -> [String] {
        RuleValidator.problems(in: r, origin: origin, safety: safety)
    }

    func testValidCommandRulePasses() {
        XCTAssertEqual(problems(rule()), [])
    }

    func testCommandOnlyWithSafeOrConfirm() {
        XCTAssertEqual(problems(rule(tier: .confirm)), [])
        XCTAssertFalse(problems(rule(tier: .suggested)).isEmpty)
    }

    func testDisplayOnlyMustHaveNoAction() {
        XCTAssertEqual(problems(rule(tier: .displayOnly, targets: ["~/.codex/sessions"], action: .noAction)), [])
        XCTAssertFalse(problems(rule(tier: .displayOnly, action: .recover)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, action: .noAction)).isEmpty)
    }

    func testActionableRuleCannotTargetForbiddenTree() {
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/.codex/sessions"], action: .recover)).isEmpty)
    }

    func testNoRuleMayTouchPrivacyRoots() {
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/Documents/big"], action: .noAction)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/.ssh"], action: .noAction)).isEmpty)
    }

    func testWildcardMustBeWholeSingleComponent() {
        XCTAssertEqual(problems(rule(tier: .safe, targets: ["~/Library/Caches/JetBrains/*"], action: .recover)), [])
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/Caches/Jet*"], action: .recover)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/*/x/*"], action: .recover)).isEmpty)
    }

    func testRelativeTargetsRejected() {
        XCTAssertFalse(problems(rule(targets: ["Library/Caches"])).isEmpty)
    }

    func testWildcardParentMustNotBeTooShallowOrProtected() {
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/*"], action: .noAction)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["/*"], action: .noAction)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/Library/*"], action: .recover)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/*/big"], action: .recover)).isEmpty)

        XCTAssertEqual(problems(rule(tier: .safe, targets: ["~/Library/Caches/JetBrains/*"], action: .recover)), [])
        XCTAssertEqual(problems(rule(tier: .suggested,
                                      targets: ["~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"],
                                      action: .recover)), [])
    }

    func testPrivacyCheckIsCaseInsensitive() {
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/documents/big"], action: .noAction)).isEmpty)
    }

    func testTargetCannotBeARootBoundaryItself() {
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["/"], action: .noAction)).isEmpty)
        XCTAssertFalse(problems(rule(tier: .displayOnly, targets: ["~/"], action: .noAction)).isEmpty)
    }

    func testRuleCannotTargetToolDataDirectories() {
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/.dclean-v2"], action: .recover), .user).isEmpty)
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/.dclean-v3/recovery"], action: .recover), .user).isEmpty)
    }

    func testDisplayOnlyCodexSessionsStillPasses() {
        XCTAssertEqual(problems(rule(tier: .displayOnly, targets: ["~/.codex/sessions"], action: .noAction)), [])
    }

    func testActionableRuleForbiddenTreeCheckIsCaseInsensitive() {
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/.Codex/Sessions"], action: .recover)).isEmpty)
    }

    func testActionableRuleTargetMustBeInsideHome() {
        let outside = problems(rule(tier: .confirm, targets: ["/opt/cache/big"], action: .recover), .user)
        XCTAssertTrue(outside.contains("规则 r：可执行规则的目标必须在家目录内：/opt/cache/big"), "\(outside)")
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["/Library/Caches/Foo"], action: .recover)).isEmpty)
        // 只展示项不执行，允许指向家目录外。
        XCTAssertEqual(problems(rule(tier: .displayOnly, targets: ["/Library/Caches/Foo"], action: .noAction)), [])
    }

    func testRecoverOlderThanNeedsPositiveDays() {
        XCTAssertFalse(problems(rule(tier: .safe, action: RuleAction(type: .recoverOlderThan, olderThanDays: 0))).isEmpty)
        XCTAssertEqual(problems(rule(tier: .safe, targets: ["~/Library/Logs/DiagnosticReports"], action: RuleAction(type: .recoverOlderThan, olderThanDays: 30))), [])
    }

    func testUserRulesAreConfinedToConfirmRecover() {
        XCTAssertEqual(problems(rule(tier: .confirm, targets: ["~/Library/Caches/Foo"], action: .recover), .user), [])
        XCTAssertFalse(problems(rule(tier: .confirm), .user).isEmpty)
        XCTAssertFalse(problems(rule(tier: .safe, targets: ["~/Library/Caches/Foo"], action: .recover), .user).isEmpty)
        let service = PausableService(name: "s", processPattern: "p", stop: ["a"], start: ["b"])
        XCTAssertFalse(problems(rule(tier: .confirm, targets: ["~/Library/Caches/Foo"], action: .recover,
                                     preconditions: RulePreconditions(pausableServices: [service])), .user).isEmpty)
    }

    func testRuleDecodesFromJSON() throws {
        let json = """
        {"id":"x","name":"X","app":"Chrome","category":"browser","tier":"suggested",
         "targets":["~/Library/Caches/X"],"action":{"type":"recover"},
         "preconditions":{"quitApps":[{"name":"Chrome","bundleID":"com.google.Chrome"}]},
         "copy":{"what":"w","impact":"i"}}
        """
        let decoded = try JSONDecoder().decode(CleanRule.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.action.type, .recover)
        XCTAssertEqual(decoded.preconditions?.quitApps?.first?.canQuitForUser, true)
        XCTAssertNil(decoded.copy.regrows)
    }
}
