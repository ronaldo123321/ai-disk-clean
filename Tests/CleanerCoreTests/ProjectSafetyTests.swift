import XCTest
@testable import CleanerCore

final class ProjectSafetyTests: XCTestCase {
    let home = EngineFixture.home
    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var root: String { home + "/work/app" }
    var artifact: String { root + "/.next" }
    override func setUp() {
        files = InMemoryFileOperations(home: home)
        runner = FakeProcessRunner()
        files.makeFile(root + "/package.json", size: 2, modifiedAt: EngineFixture.daysBefore(100))
        files.makeFile(artifact + "/cache.bin", size: 2 << 20, modifiedAt: EngineFixture.daysBefore(100))
    }
    func capture() throws -> ProjectEvidence {
        try ProjectProtection.capture(root: root, artifact: artifact, files: files, runner: runner, now: EngineFixture.context(files).now)
    }
    func testStableEvidenceAndSameSizeModification() throws {
        let first = try capture()
        XCTAssertEqual(first.digest, try capture().digest)
        files.makeFile(artifact + "/cache.bin", size: 2 << 20, modifiedAt: EngineFixture.daysBefore(1))
        XCTAssertNotEqual(first.digest, try capture().digest)
    }
    func testSourceChangeOutsideArtifactInvalidatesEvidence() throws {
        files.makeFile(root + "/app.ts", size: 20, modifiedAt: EngineFixture.daysBefore(100))
        let before = try capture()
        files.makeFile(root + "/app.ts", size: 20, modifiedAt: EngineFixture.daysBefore(1))
        XCTAssertNotEqual(before.digest, try capture().digest)
    }
    func testSensitiveContentNestedRepositoryAndEnvironmentProtected() {
        for name in ["deploy/program-keypair.json", ".env", "cert.pem", "nested/.git/index"] {
            setUp()
            files.makeFile(artifact + "/" + name, size: 10)
            XCTAssertThrowsError(try capture(), name)
        }
    }
    func testTrackedContentAndUnknownGitRefused() throws {
        files.makeDirectory(root + "/.git")
        files.makeFile("/opt/homebrew/bin/git", size: 1)
        XCTAssertThrowsError(try capture())
        runner.handler = { _, args in
            XCTAssertTrue(args.contains("ls-files"))
            XCTAssertTrue(args.contains("--literal-pathspecs"))
            return ProcessResult(exitStatus: 0, stdout: ".next/source.js\u{0}", stderr: "")
        }
        XCTAssertThrowsError(try capture())
        runner.handler = { _, _ in ProcessResult(exitStatus: 0, stdout: "", stderr: "") }
        XCTAssertNoThrow(try capture())
    }
    func testBuildSourceIsProtectedAndMarkerRequired() throws {
        let build = root + "/build"
        files.makeFile(build + "/source.swift", size: 10)
        XCTAssertThrowsError(try ProjectProtection.capture(root: root, artifact: build, files: files, runner: runner, now: Date()))
        try files.removeItem(atPath: build + "/source.swift")
        try files.removeItem(atPath: root + "/package.json")
        XCTAssertThrowsError(try ProjectProtection.capture(root: root, artifact: build, files: files, runner: runner, now: Date()))
    }
    private struct FixtureDetector: Detector {
        var name = "fixture"
        let item: CleanItem
        func detect(_ context: DetectContext) -> [CleanItem] { [item] }
    }
    func scan(options: ScanOptions = ScanOptions(), onStep: ((ScanStep) -> Void)? = nil) -> ScanResult {
        files.makeFile(root + "/node_modules/a.js", size: 2 << 20)
        let item = CleanItem(id: "project:" + root, app: "项目：app", category: .dev, tier: .suggested,
            title: "app", paths: [artifact, root + "/node_modules"], action: .recover, preconditions: .empty,
            copy: RuleCopy(what: "cache", impact: "rebuild", regrows: nil))
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: runner,
            now: EngineFixture.context(files).now, options: options)
        let checker = PreconditionChecker(apps: FakeAppControl(), guards: GuardEvaluator(files: files, runner: runner), home: home)
        return EngineScanner(context: context, detectors: [FixtureDetector(item: item)], spaceMap: nil, checker: checker).scan(onStep: onStep)
    }
    func testScannerSplitsArtifactsAndStreamsReadOnlyPreview() {
        var previews = 0
        let result = scan { if case .preview = $0 { previews += 1 } }
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.paths.count == 1 && $0.projectRoot == root && $0.projectEvidence != nil })
        XCTAssertGreaterThan(previews, 1)
        let plan = CleanPlan(items: result.items, selectedIDs: ["artifact:" + artifact])
        XCTAssertEqual(plan.selectedItems.flatMap(\.paths), [artifact])
        XCTAssertEqual(plan.estimatedImmediateBytes, 0)
        XCTAssertEqual(plan.recoveryMoveBytes, 2 << 20)
    }
    func testKeptAndExcludedCannotEnterDefaultPlan() {
        let result = scan(options: ScanOptions(excludedPaths: [root + "/node_modules"], keptPaths: [artifact]))
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(PlanBuilder.build(from: result).selectedIDs.isEmpty)
    }
    func testProtectedItemNotSelectedButOtherArtifactStillUsable() {
        files.makeFile(artifact + "/.env", size: 10)
        let result = scan()
        XCTAssertEqual(PlanBuilder.build(from: result).selectedIDs, ["artifact:" + root + "/node_modules"])
        XCTAssertEqual(result.items.first { $0.paths == [artifact] }?.tier, .displayOnly)
    }
    func testExecutorRejectsChangedMissingAndExpiredEvidence() throws {
        var item = try XCTUnwrap(scan().items.first { $0.paths == [artifact] })
        let executor = PlanExecutor(files: files, safety: PathSafety(home: home, files: files), runner: runner,
            commandRunner: runner, apps: FakeAppControl(), recovery: RecoveryStore(directory: home + "/.dclean/recovery", files: files),
            audit: AuditLog(files: files, path: home + "/audit"), now: { EngineFixture.context(self.files).now })
        if case .failure = executor.revalidate(item) { XCTFail("unchanged evidence should pass") }
        files.makeFile(artifact + "/new.bin", size: 4)
        if case .success = executor.revalidate(item) { XCTFail("changed tree must fail") }
        item.projectEvidence = nil
        if case .success = executor.revalidate(item) { XCTFail("missing evidence must fail") }
        item.projectEvidence = try capture()
        item.projectEvidence?.capturedAt = EngineFixture.daysBefore(1)
        if case .success = executor.revalidate(item) { XCTFail("expired evidence must fail") }
    }
    func testScopeExclusionsAndMissingRootAreReported() {
        let context = DetectContext(files: files, safety: PathSafety(home: home, files: files), runner: runner,
            now: EngineFixture.context(files).now,
            options: ScanOptions(projectRoots: [root, home + "/missing"], excludedPaths: [artifact]))
        let found = ProjectArtifactDetector().findArtifacts(context)
        XCTAssertFalse(found.contains(artifact))
        XCTAssertTrue(context.diagnostics.issues.contains { $0.path == home + "/missing" })
    }

    func testRecoveryAdmissionRejectsReplacedScanIdentity() throws {
        let evidence = try capture()
        try files.removeItem(atPath: artifact)
        files.makeFile(artifact + "/new-file", size: 4, modifiedAt: EngineFixture.daysBefore(1))
        // In-memory directory identity has no inode; explicitly use a different reviewed inode.
        var identity = evidence.rootIdentity
        identity.inode = 12345
        let store = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
        let writer = try store.begin(batchID: "run-test", now: Date())
        XCTAssertThrowsError(try writer.admit(path: artifact, bytes: 4, expectedIdentity: identity))
        XCTAssertTrue(files.fileExists(artifact + "/new-file"))
    }
}
