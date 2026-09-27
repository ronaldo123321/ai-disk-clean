import XCTest
@testable import CleanerCore

final class EngineRecoveryStoreTests: XCTestCase {
    var home: String!
    var files: RealFileOperations!
    var store: RecoveryStore!

    override func setUpWithError() throws {
        home = TestEnv.makeTempDir("recovery")
        files = RealFileOperations(home: home)
        store = RecoveryStore(directory: EnginePaths.recoveryDirectory(home: home), files: files)
    }

    override func tearDown() { TestEnv.remove(home) }

    func testAdmitMovesAndRestoreBringsBackExactBytes() throws {
        try TestEnv.makeTree(root: home + "/proj/node_modules", files: ["a/index.js": "console.log(1)", "b.txt": "b"])
        let writer = try store.begin(batchID: "run-1", now: Date())
        try writer.admit(path: home + "/proj/node_modules", bytes: 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/proj/node_modules"))
        XCTAssertEqual(store.occupiedBytes(), 42)
        XCTAssertEqual(store.list().map(\.id), ["run-1"])

        let result = store.restore(batchID: "run-1")
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.restored, [home + "/proj/node_modules"])
        XCTAssertEqual(try String(contentsOfFile: home + "/proj/node_modules/a/index.js"), "console.log(1)")
        XCTAssertEqual(store.occupiedBytes(), 0)
        XCTAssertEqual(store.list(), [])
    }

    func testRestoreNeverOverwrites() throws {
        try TestEnv.write("old", to: home + "/Library/Caches/X/f")
        let writer = try store.begin(batchID: "run-2", now: Date())
        try writer.admit(path: home + "/Library/Caches/X", bytes: 3)
        try TestEnv.write("new", to: home + "/Library/Caches/X/f")
        let result = store.restore(batchID: "run-2")
        XCTAssertEqual(result.restored, [])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(try String(contentsOfFile: home + "/Library/Caches/X/f"), "new")
        XCTAssertEqual(store.occupiedBytes(), 3)
    }

    func testPurgeRemovesOnlyExpiredBatches() throws {
        try TestEnv.write("a", to: home + "/c/old")
        try TestEnv.write("b", to: home + "/c/new")
        let now = Date()
        try store.begin(batchID: "old", now: now.addingTimeInterval(-8 * 86_400)).admit(path: home + "/c/old", bytes: 1)
        try store.begin(batchID: "new", now: now.addingTimeInterval(-6 * 86_400)).admit(path: home + "/c/new", bytes: 1)
        let result = store.purge(olderThanDays: RecoveryStore.retentionDays, now: now)
        XCTAssertEqual(result.purged, ["old"])
        XCTAssertEqual(store.list().map(\.id), ["new"])
    }

    func testSymlinkIsNeverAdmitted() throws {
        try FileManager.default.createDirectory(atPath: home + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/real")
        let writer = try store.begin(batchID: "run-3", now: Date())
        XCTAssertThrowsError(try writer.admit(path: home + "/link", bytes: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/real"))
    }

    func testInvalidBatchIDRejected() {
        XCTAssertThrowsError(try store.begin(batchID: "../x", now: Date()))
    }

    func testAdmitRejectsSymlinkedAncestor() throws {
        try FileManager.default.createDirectory(atPath: home + "/tmp/real", withIntermediateDirectories: true)
        try TestEnv.write("keep", to: home + "/tmp/real/x")
        try FileManager.default.createSymbolicLink(atPath: home + "/tmp/link", withDestinationPath: home + "/tmp/real")
        let writer = try store.begin(batchID: "run-4", now: Date())
        XCTAssertThrowsError(try writer.admit(path: home + "/tmp/link/x", bytes: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/tmp/real/x"))
    }

    // MARK: - Hardening (code review follow-up)

    /// 手工落盘一份清单，绕过 RecoveryStore 的公开 API，模拟被篡改 / 崩溃留下的半成品文件。
    private func writeManifest(_ batch: RecoveryBatch, id: String? = nil) throws {
        let dirID = id ?? batch.id
        let dir = store.directory + "/" + dirID
        try FileManager.default.createDirectory(atPath: dir + "/items", withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(batch)
        try data.write(to: URL(fileURLWithPath: dir + "/manifest.json"))
    }

    func testCorruptManifestIDIsNeverListedOrPurged() throws {
        let batch = RecoveryBatch(id: "", createdAt: Date().addingTimeInterval(-30 * 86_400), entries: [])
        try writeManifest(batch, id: "a")
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(store.orphanBatches(), ["a"])

        let result = store.purge(olderThanDays: RecoveryStore.retentionDays, now: Date())
        XCTAssertEqual(result.purged, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/a"))
    }

    func testManifestPointingStoredPathIntoDocumentsIsRejected() throws {
        try TestEnv.write("keep", to: home + "/src/keep")
        let identity = files.attributesIfExist(atPath: home + "/src/keep")
        let entry = RecoveryEntry(originalPath: home + "/src/keep", storedPath: home + "/Documents/x",
                                   bytes: 1, state: .stored, identity: identity)
        let batch = RecoveryBatch(id: "doc-attack", createdAt: Date(), entries: [entry])
        try writeManifest(batch)

        XCTAssertFalse(store.list().contains { $0.id == "doc-attack" })
        let result = store.restore(batchID: "doc-attack")
        XCTAssertEqual(result.restored, [])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Documents/x"))
    }

    func testMissingIdentityRefusesRestore() throws {
        let entry = RecoveryEntry(originalPath: home + "/x/y/z",
                                   storedPath: store.directory + "/no-identity/items/0/z",
                                   bytes: 1, state: .stored, identity: nil)
        let batch = RecoveryBatch(id: "no-identity", createdAt: Date(), entries: [entry])
        try writeManifest(batch)

        let result = store.restore(batchID: "no-identity")
        XCTAssertEqual(result.restored, [])
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testRestoreRefusesWhenAncestorBecomesSymlink() throws {
        try TestEnv.write("x", to: home + "/proj/sub/target/f")
        let writer = try store.begin(batchID: "sym-anc", now: Date())
        try writer.admit(path: home + "/proj/sub/target", bytes: 1)

        // 恢复前，原来的祖先目录被换成指向别处的符号链接。
        try FileManager.default.removeItem(atPath: home + "/proj/sub")
        try FileManager.default.createDirectory(atPath: home + "/evil", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/proj/sub", withDestinationPath: home + "/evil")

        let result = store.restore(batchID: "sym-anc")
        XCTAssertEqual(result.restored, [])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/evil/target"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/proj/sub"), home + "/evil")
    }

    func testRestoreRefusesWhenNestedFileDeletedInsideRecovery() throws {
        try TestEnv.makeTree(root: home + "/proj/build", files: ["a/b/c.txt": "keep", "d.txt": "d"])
        let writer = try store.begin(batchID: "nested-del", now: Date())
        try writer.admit(path: home + "/proj/build", bytes: 10)

        let stored = store.list().first { $0.id == "nested-del" }!
        let nestedStoredFile = stored.entries[0].storedPath + "/a/b/c.txt"
        try FileManager.default.removeItem(atPath: nestedStoredFile)

        let result = store.restore(batchID: "nested-del")
        XCTAssertEqual(result.restored, [])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/nested-del"))
    }

    func testBeginTwiceSameIDThrows() throws {
        _ = try store.begin(batchID: "dup", now: Date())
        XCTAssertThrowsError(try store.begin(batchID: "dup", now: Date()))
    }

    func testAdmitInsideRecoveryDirThrows() throws {
        let writer = try store.begin(batchID: "self-guard", now: Date())
        XCTAssertThrowsError(try writer.admit(path: store.directory, bytes: 0))
    }

    func testPendingWithCopyAfterCrashIsRestorable() throws {
        try TestEnv.write("keep", to: home + "/data/f")
        let identity = files.attributesIfExist(atPath: home + "/data/f")!
        let writer = try store.begin(batchID: "crash-1", now: Date())

        // 模拟崩溃：move 已完成（副本已在 storedPath），但记录 stored 状态的第二次落盘从未发生。
        let storedPath = store.directory + "/crash-1/items/0/f"
        try FileManager.default.createDirectory(atPath: (storedPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: home + "/data/f", toPath: storedPath)
        let entry = RecoveryEntry(originalPath: home + "/data/f", storedPath: storedPath,
                                   bytes: 4, state: .pending, identity: identity)
        var batch = writer.batch
        batch.entries.append(entry)
        try writeManifest(batch)

        XCTAssertEqual(store.occupiedBytes(), 4)
        let result = store.restore(batchID: "crash-1")
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.restored, [home + "/data/f"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/data/f"))
        XCTAssertEqual(store.occupiedBytes(), 0)
    }

    func testAdmitThrowsContentUnverifiableWhenSubdirUnreadableAndLeavesItemInPlace() throws {
        try TestEnv.makeTree(root: home + "/proj/locked", files: ["a.txt": "keep", "sub/b.txt": "hidden"])
        let lockedSub = home + "/proj/locked/sub"
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSub) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSub)

        let writer = try store.begin(batchID: "locked-1", now: Date())
        XCTAssertThrowsError(try writer.admit(path: home + "/proj/locked", bytes: 5)) { error in
            guard case RecoveryError.contentUnverifiable(let path) = error else {
                return XCTFail("expected contentUnverifiable, got \(error)")
            }
            XCTAssertEqual(path, home + "/proj/locked")
        }

        // 工具绝不能收下一个日后还不回去的目录：算不出摘要就必须原地不动，批次里不留任何条目
        // （begin() 已经落盘了一份空清单，这是正常的批次生命周期，与本次 admit 失败无关）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/proj/locked"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedSub))
        XCTAssertEqual(store.list().first { $0.id == "locked-1" }?.entries, [])
        XCTAssertEqual(store.occupiedBytes(), 0)
    }

    func testManifestWithStoredDirectoryMissingDigestIsRejectedByRead() throws {
        try TestEnv.makeTree(root: home + "/proj/dir1", files: ["f.txt": "x"])
        let identity = files.attributesIfExist(atPath: home + "/proj/dir1")
        let entry = RecoveryEntry(originalPath: home + "/proj/dir1",
                                   storedPath: store.directory + "/bad-digest/items/0/dir1",
                                   bytes: 1, state: .stored, identity: identity,
                                   contentDigest: nil)
        let batch = RecoveryBatch(id: "bad-digest", createdAt: Date(), entries: [entry])
        try writeManifest(batch)

        XCTAssertFalse(store.list().contains { $0.id == "bad-digest" })
        XCTAssertEqual(store.orphanBatches(), ["bad-digest"])
    }

    func testManifestPointingOriginalPathAtDataDirectoryIsRejected() throws {
        let target = EnginePaths.userRules(home: home)
        let identity = FileAttributes(isSymbolicLink: false, isDirectory: false, isRegularFile: true,
                                       size: 1, modificationDate: Date())
        let entry = RecoveryEntry(originalPath: target,
                                   storedPath: store.directory + "/data-attack/items/0/user-rules.json",
                                   bytes: 1, state: .stored, identity: identity)
        let batch = RecoveryBatch(id: "data-attack", createdAt: Date(), entries: [entry])
        try writeManifest(batch)

        XCTAssertFalse(store.list().contains { $0.id == "data-attack" })
        let result = store.restore(batchID: "data-attack")
        XCTAssertEqual(result.restored, [])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testOrphanBatchesIgnoresStrayFile() throws {
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        try TestEnv.write("noise", to: store.directory + "/stray.txt")
        XCTAssertEqual(store.orphanBatches(), [])
    }

    func testOccupiedBytesOfCountsPendingWithCopy() throws {
        try TestEnv.write("keep", to: home + "/data2/f")
        let identity = files.attributesIfExist(atPath: home + "/data2/f")!
        let writer = try store.begin(batchID: "crash-2", now: Date())

        let storedPath = store.directory + "/crash-2/items/0/f"
        try FileManager.default.createDirectory(atPath: (storedPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: home + "/data2/f", toPath: storedPath)
        var batch = writer.batch
        batch.entries.append(RecoveryEntry(originalPath: home + "/data2/f", storedPath: storedPath,
                                            bytes: 7, state: .pending, identity: identity))
        try writeManifest(batch)

        let read = store.list().first { $0.id == "crash-2" }!
        XCTAssertEqual(store.occupiedBytes(of: read), 7)
    }

    func testPartialRestoreKeepsBatchDirectory() throws {
        try TestEnv.write("a", to: home + "/p/a")
        try TestEnv.write("b", to: home + "/p2/b")
        let writer = try store.begin(batchID: "partial-1", now: Date())
        try writer.admit(path: home + "/p/a", bytes: 1)
        try writer.admit(path: home + "/p2/b", bytes: 1)

        // 恢复前有人在原位置放回了新内容，令其中一条恢复失败。
        try TestEnv.write("blocker", to: home + "/p/a")

        let result = store.restore(batchID: "partial-1")
        XCTAssertEqual(result.restored, [home + "/p2/b"])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/partial-1"))
    }

    // MARK: admit 与清单校验同一套原位置规则

    func testAdmitRejectsPathOutsideHomeBeforeWritingAnything() throws {
        let outside = TestEnv.makeTempDir("recovery-outside")
        defer { TestEnv.remove(outside) }
        try TestEnv.write("x", to: outside + "/cache/f")
        let writer = try store.begin(batchID: "run-out", now: Date())
        XCTAssertThrowsError(try writer.admit(path: outside + "/cache", bytes: 1)) { error in
            XCTAssertEqual(error as? RecoveryError, .outsideHome(outside + "/cache"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/cache/f"))
        XCTAssertEqual(writer.batch.entries, [])
        XCTAssertEqual(store.list().map(\.id), ["run-out"])
        XCTAssertEqual(store.orphanBatches(), [])
    }

    func testAdmitRejectsPathMatchingHomeOnlyCaseInsensitively() throws {
        try TestEnv.write("x", to: home + "/cache/f")
        // APFS 默认不区分大小写：改了大小写的家目录前缀在磁盘上指向同一处，但清单校验按原样比较会拒绝它。
        let upper = (home as NSString).deletingLastPathComponent + "/" + (home as NSString).lastPathComponent.uppercased()
        let writer = try store.begin(batchID: "run-case", now: Date())
        XCTAssertThrowsError(try writer.admit(path: upper + "/cache", bytes: 1)) { error in
            XCTAssertEqual(error as? RecoveryError, .outsideHome(upper + "/cache"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/cache/f"))
        XCTAssertEqual(writer.batch.entries, [])
    }

    func testAdmitRejectsToolDataDirectoriesIncludingV2() throws {
        let v2 = V2Paths.dataDirectory(home: home) + "/stuff"
        try TestEnv.write("x", to: v2 + "/f")
        let writer = try store.begin(batchID: "run-v2", now: Date())
        XCTAssertThrowsError(try writer.admit(path: v2, bytes: 1)) { error in
            XCTAssertEqual(error as? RecoveryError, .protectedArea(v2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2 + "/f"))
        XCTAssertEqual(writer.batch.entries, [])
    }

    func testRestoreOnlySelectedItem() throws {
        try TestEnv.write("a", to: home + "/Library/Caches/A/f")
        try TestEnv.write("b", to: home + "/Library/Caches/B/f")
        try TestEnv.write("c", to: home + "/Library/Caches/C/f")
        let writer = try store.begin(batchID: "run-items", now: Date())
        try writer.admit(path: home + "/Library/Caches/A", bytes: 1, itemID: "rule:a", itemTitle: "A 缓存")
        try writer.admit(path: home + "/Library/Caches/B", bytes: 1, itemID: "rule:b", itemTitle: "B 缓存")
        try writer.admit(path: home + "/Library/Caches/C", bytes: 1) // 未记录所属项：只能随整批还原。
        XCTAssertEqual(store.list().first?.entries.map(\.itemID), ["rule:a", "rule:b", nil])

        // 空集合、未知 ID：一个都匹配不上，直接报错，什么都不动。
        for selection: Set<String> in [[], ["rule:zzz"]] {
            let result = store.restore(batchID: "run-items", itemIDs: selection)
            XCTAssertEqual(result.restored, [])
            XCTAssertEqual(result.errors, ["没有匹配的可还原项：run-items"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Caches/A/f"))

        let result = store.restore(batchID: "run-items", itemIDs: ["rule:a"])
        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Caches/A/f"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Caches/B/f"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Caches/C/f"))
        var afterPartial = store.list().first { $0.id == "run-items" }!
        XCTAssertEqual(afterPartial.entries.map(\.state), [.restored, .stored, .stored])
        XCTAssertEqual(store.list().map(\.id), ["run-items"])

        // 选中 B 时，没有 itemID 的 C 不会被这次选择性还原捎带上。
        _ = store.restore(batchID: "run-items", itemIDs: ["rule:b"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Caches/B/f"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Caches/C/f"))
        afterPartial = store.list().first { $0.id == "run-items" }!
        XCTAssertEqual(afterPartial.entries.map(\.state), [.restored, .restored, .stored])

        // 整批还原才能带上没有 itemID 的 C。
        _ = store.restore(batchID: "run-items", itemIDs: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Caches/C/f"))
        XCTAssertEqual(store.list(), [])
    }

    func testPurgeSingleBatchNow() throws {
        try TestEnv.write("a", to: home + "/c/a")
        try TestEnv.write("b", to: home + "/c/b")
        try store.begin(batchID: "keep", now: Date()).admit(path: home + "/c/a", bytes: 1, itemID: "x", itemTitle: "X")
        try store.begin(batchID: "drop", now: Date()).admit(path: home + "/c/b", bytes: 1, itemID: "y", itemTitle: "Y")
        let keptCopy = try XCTUnwrap(store.list().first { $0.id == "keep" }?.entries.first?.storedPath)
        XCTAssertEqual(store.purge(batchID: "drop"), [])
        XCTAssertEqual(store.list().map(\.id), ["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptCopy))
        XCTAssertFalse(store.purge(batchID: "missing").isEmpty)

        // 清单损坏（记录的 id 与目录名对不上）：isTrustworthy 拒绝，purge 不删目录、只报错。
        let corrupt = RecoveryBatch(id: "mismatch", createdAt: Date(), entries: [])
        try writeManifest(corrupt, id: "corrupt-purge")
        XCTAssertFalse(store.purge(batchID: "corrupt-purge").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/corrupt-purge"))

        // 非法 ID 一律报错，不触碰文件系统。
        XCTAssertFalse(store.purge(batchID: "..").isEmpty)
        XCTAssertFalse(store.purge(batchID: "a/b").isEmpty)
    }

    func testRecoveryBatchPublicInitializer() {
        let batch = RecoveryBatch(id: "b", createdAt: Date(), entries: [])
        XCTAssertEqual(batch.entries, [])
    }

    func testPurgeWritesAuditBeforeDeleting() throws {
        let audit = AuditLog(files: files, path: EnginePaths.auditLog(home: home))
        let audited = RecoveryStore(directory: store.directory, files: files, audit: audit)
        try TestEnv.write("ab", to: home + "/c/a")
        try TestEnv.write("b", to: home + "/c/b")
        try audited.begin(batchID: "now", now: Date()).admit(path: home + "/c/a", bytes: 2)
        try audited.begin(batchID: "old", now: Date(timeIntervalSinceNow: -8 * 86_400)).admit(path: home + "/c/b", bytes: 1)

        XCTAssertEqual(audited.purge(batchID: "now"), [])
        XCTAssertEqual(audited.purge(olderThanDays: 7, now: Date()).purged, ["old"])
        let events = audit.readAll().map { "\($0.op) \($0.detail) \($0.bytes ?? -1)" }
        XCTAssertEqual(events, ["purge.intent now 2", "purge.done now 2", "purge.intent old 1", "purge.done old 1"])
    }

    func testPurgeRefusesWhenAuditCannotBeWritten() throws {
        let auditPath = EnginePaths.auditLog(home: home)
        try TestEnv.write("not json\n", to: auditPath)
        let audited = RecoveryStore(directory: store.directory, files: files, audit: AuditLog(files: files, path: auditPath))
        try TestEnv.write("a", to: home + "/c/a")
        try audited.begin(batchID: "keep", now: Date(timeIntervalSinceNow: -8 * 86_400)).admit(path: home + "/c/a", bytes: 1)

        XCTAssertFalse(audited.purge(batchID: "keep").isEmpty)
        let expired = audited.purge(olderThanDays: 7, now: Date())
        XCTAssertEqual(expired.purged, [])
        XCTAssertFalse(expired.errors.isEmpty)
        XCTAssertEqual(audited.list().map(\.id), ["keep"])
    }
}
