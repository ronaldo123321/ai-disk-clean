import XCTest
@testable import CleanerCore

final class EngineDockerDetectorTests: XCTestCase {
    let docker = "/usr/local/bin/docker"
    let host = "unix:///var/run/docker.sock"

    let failedContainerFormat = "{{.Id}}\t{{.State.ExitCode}}\t{{.State.FinishedAt}}\t{{.Name}}"
    let usedImageFormat = "{{.Image}}"
    let imagesListFormat = "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"
    let dfFormat = "{{.Type}}\t{{.Reclaimable}}"

    var files: InMemoryFileOperations!
    var runner: FakeProcessRunner!
    var outputs: [String: String] = [:]
    var failing: Set<String> = []
    var daemonUp = true
    var endpoint = ""

    override func setUp() {
        files = InMemoryFileOperations(home: EngineFixture.home)
        files.makeFile(docker, size: 1)
        runner = FakeProcessRunner()
        outputs = [:]
        failing = []
        daemonUp = true
        endpoint = host
        runner.handler = { [unowned self] path, args in
            guard path == self.docker else { return nil }
            if args == ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"] {
                return ProcessResult(exitStatus: 0, stdout: self.endpoint + "\n", stderr: "")
            }
            guard args.first == "-H", args.count > 1, args[1] == self.host else { return nil }
            let rest = Array(args.dropFirst(2))
            if rest == ["info", "--format", "{{.ServerVersion}}"] {
                return self.daemonUp ? ProcessResult(exitStatus: 0, stdout: "28.0.1\n", stderr: "")
                                     : ProcessResult(exitStatus: 1, stdout: "", stderr: "Cannot connect")
            }
            let key = rest.joined(separator: " ")
            if self.failing.contains(key) {
                return ProcessResult(exitStatus: 1, stdout: "", stderr: "boom")
            }
            return ProcessResult(exitStatus: 0, stdout: self.outputs[key] ?? "", stderr: "")
        }
    }

    func detect() -> [CleanItem] { DockerDetector().detect(EngineFixture.context(files, runner: runner)) }

    func testTcpEndpointYieldsNothingAndProbesNoFurther() {
        endpoint = "tcp://127.0.0.1:2375"
        XCTAssertEqual(detect(), [])
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.arguments, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
    }

    func testDaemonNotRunningYieldsNothingAndNeverStartsDocker() {
        daemonUp = false
        XCTAssertEqual(detect(), [])
        XCTAssertFalse(runner.calls.contains { $0.launchPath == "/usr/bin/open" })
    }

    func testBuildCacheIsSafeCommand() {
        outputs["system df --format \(dfFormat)"] = "Images\t19.28GB\nBuild Cache\t5.017GB\n"
        let item = detect().first { $0.id == "docker:build-cache" }
        XCTAssertEqual(item?.tier, .safe)
        XCTAssertEqual(item?.action.command, [docker, "-H", host, "builder", "prune", "-a", "-f"])
        XCTAssertEqual(item?.reclaimableBytes, 5_017_000_000)
        XCTAssertEqual(item?.sizedByDetector, true)
    }

    func testBuildCacheHandlesReclaimablePercentageSuffix() {
        outputs["system df --format \(dfFormat)"] = "Build Cache\t4.2GB (83%)\n"
        let item = detect().first { $0.id == "docker:build-cache" }
        XCTAssertEqual(item?.reclaimableBytes, 4_200_000_000)
    }

    func testSystemDfFailureYieldsNoBuildCacheItem() {
        failing.insert("system df --format \(dfFormat)")
        XCTAssertNil(detect().first { $0.id == "docker:build-cache" })
    }

    func testOnlyOldFailedContainersAreListedAndVolumesKept() {
        outputs["ps -a -q --filter status=exited"] = "aaa\nbbb\nccc\n"
        outputs["inspect --format \(failedContainerFormat) aaa bbb ccc"] = """
        aaaaaaaaaaaaaaaa\t1\t2025-01-01T00:00:00.123456789Z\t/charming_bell
        bbbbbbbbbbbbbbbb\t0\t2025-01-01T00:00:00Z\t/mysql8
        cccccccccccccccc\t137\t2025-01-01T00:00:00Z\t/gateway
        """
        let item = detect().first { $0.id == "docker:failed-containers" }
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertEqual(item?.action.command, [docker, "-H", host, "rm", "aaaaaaaaaaaa"])
        XCTAssertTrue(item?.copy.what.contains("charming_bell") == true)
        XCTAssertEqual(item?.copy.impact, "只删容器本身，数据卷保留")
    }

    func testRecentFailedContainerIsExcluded() {
        let recentFinishedAt = ISO8601DateFormatter().string(from: EngineFixture.daysBefore(10))
        outputs["ps -a -q --filter status=exited"] = "aaa\n"
        outputs["inspect --format \(failedContainerFormat) aaa"] = "aaaaaaaaaaaaaaaa\t1\t\(recentFinishedAt)\t/demo"
        XCTAssertNil(detect().first { $0.id == "docker:failed-containers" })
    }

    func testUnusedImagesExcludeThoseReferencedByContainersAndUseReferences() {
        outputs["ps -a -q"] = "aaa\n"
        outputs["inspect --format \(usedImageFormat) aaa"] = "sha256:used\n"
        outputs["images --no-trunc --format \(imagesListFormat)"] =
            "sha256:used\tpostgres:16\t411MB\nsha256:free\trust:1.90\t4.22GB\nsha256:free\trust:latest\t4.22GB\n"
        let item = detect().first { $0.id == "docker:unused-images" }
        XCTAssertEqual(item?.action.command, [docker, "-H", host, "rmi", "rust:1.90", "rust:latest"])
        XCTAssertEqual(item?.tier, .confirm)
        XCTAssertEqual(item?.reclaimableBytes, 4_220_000_000)
        XCTAssertEqual(item?.notes, ["镜像大小含与其他镜像共用的层，实际释放可能更少"])
    }

    func testUnusedImageWithNoTagsShowsShortID() {
        outputs["ps -a -q"] = ""
        outputs["images --no-trunc --format \(imagesListFormat)"] = "sha256:abcdefabcdefabcdefabcdefabcdef01\t<none>:<none>\t100MB\n"
        let item = detect().first { $0.id == "docker:unused-images" }
        XCTAssertEqual(item?.action.command, [docker, "-H", host, "rmi", "sha256:abcdefabcdefabcdefabcdefabcdef01"])
        XCTAssertTrue(item?.copy.what.contains("abcdefabcdef") == true)
    }

    func testUnusedImageWithDigestPulledTagFallsBackToBareID() {
        outputs["ps -a -q"] = ""
        outputs["images --no-trunc --format \(imagesListFormat)"] = "sha256:x\tfoo:<none>\t10MB\n"
        let item = detect().first { $0.id == "docker:unused-images" }
        XCTAssertEqual(item?.action.command, [docker, "-H", host, "rmi", "sha256:x"])
    }

    func testPsFailureYieldsNoUnusedImagesItem() {
        failing.insert("ps -a -q")
        outputs["images --no-trunc --format \(imagesListFormat)"] = "sha256:free\trust:1.90\t4.22GB\n"
        XCTAssertNil(detect().first { $0.id == "docker:unused-images" })
    }

    func testInspectFailureAfterPsYieldsNoUnusedImagesItem() {
        outputs["ps -a -q"] = "aaa\n"
        failing.insert("inspect --format \(usedImageFormat) aaa")
        outputs["images --no-trunc --format \(imagesListFormat)"] = "sha256:free\trust:1.90\t4.22GB\n"
        XCTAssertNil(detect().first { $0.id == "docker:unused-images" })
    }

    func testSizeParsing() {
        XCTAssertEqual(DockerDetector.parseSize("902.7MB"), 902_700_000)
        XCTAssertEqual(DockerDetector.parseSize("4.1kB"), 4_100)
        XCTAssertEqual(DockerDetector.parseSize("0B"), 0)
        XCTAssertNil(DockerDetector.parseSize("n/a"))
    }

    func testParseReclaimableSizeStripsPercentage() {
        XCTAssertEqual(DockerDetector.parseReclaimableSize("4.2GB (83%)"), 4_200_000_000)
    }

    func testParseDateStripsFractionalSecondsKeepingTimezoneSuffix() {
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(DockerDetector.parseDate("2025-01-01T00:00:00.123456789Z"),
                       formatter.date(from: "2025-01-01T00:00:00Z"))
        XCTAssertEqual(DockerDetector.parseDate("2025-01-01T00:00:00.5+08:00"),
                       formatter.date(from: "2025-01-01T00:00:00+08:00"))
    }
}
