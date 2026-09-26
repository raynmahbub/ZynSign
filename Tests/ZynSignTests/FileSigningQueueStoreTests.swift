import XCTest
@testable import ZynSign

/// Tests for the file-backed signing queue store: snapshots round-trip,
/// stale saves are refused, profile copies are confined and removable, and
/// recovery sweeps only what belongs to an earlier process.
final class FileSigningQueueStoreTests: XCTestCase {

    private var root: URL!
    private var queueDirectory: URL!
    private var workingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSigningQueueStoreTests-\(UUID().uuidString)", isDirectory: true)
        queueDirectory = root.appendingPathComponent("SigningQueue", isDirectory: true)
        workingRoot = root.appendingPathComponent("Working", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func snapshot(revision: Int, names: [String]) -> SigningQueueSnapshot {
        SigningQueueSnapshot(
            revision: revision,
            savedAt: SigningQueueFixtures.fixedDate,
            jobs: names.map { name in
                StoredSigningJob(
                    id: SigningJobIdentifier().rawValue,
                    applicationName: name,
                    bundleIdentifier: "com.example.\(name.lowercased())",
                    versionText: "Version 1.0",
                    recordID: ApplicationRecordIdentifier().rawValue,
                    artifactID: ArtifactIdentifier().rawValue,
                    priority: .high,
                    origin: .bulkSelection,
                    enqueuedAt: SigningQueueFixtures.fixedDate,
                    startedAt: nil,
                    finishedAt: SigningQueueFixtures.fixedDate,
                    attemptCount: 1,
                    state: .failed(SigningQueueFixtures.failure()),
                    lastStageRawValue: SigningJobStage.signingApp.rawValue,
                    log: [SigningJobLogEntry(timestamp: SigningQueueFixtures.fixedDate, message: "Queued.")],
                    setup: nil
                )
            }
        )
    }

    func testAMissingSnapshotLoadsAsNil() async throws {
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
    }

    func testSnapshotsRoundTripThroughANewStore() async throws {
        let original = snapshot(revision: 3, names: ["MyApp", "TestApp"])
        try await FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot).save(original)

        let loaded = try await FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot).load()
        XCTAssertEqual(loaded, original)
    }

    func testAStaleSaveNeverOverwritesANewerSnapshot() async throws {
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        let newer = snapshot(revision: 5, names: ["Newer"])
        try await store.save(newer)
        try await store.save(snapshot(revision: 4, names: ["Older"]))

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.jobs.map(\.applicationName), ["Newer"])
    }

    func testAnUnreadableSnapshotThrowsRatherThanBeingDiscardedSilently() async throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: queueDirectory.appendingPathComponent("queue.json"))
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        do {
            _ = try await store.load()
            XCTFail("An unreadable snapshot must throw")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }
    }

    func testProfileCopiesAreStoredReadAndRemovedByName() async throws {
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        let jobID = SigningJobIdentifier()
        let name = try await store.storeProfile(SigningQueueFixtures.profileBytes, jobID: jobID)
        XCTAssertTrue(name.hasPrefix(jobID.rawValue))

        let loaded = try await store.loadProfile(fileName: name)
        XCTAssertEqual(loaded, SigningQueueFixtures.profileBytes)

        try await store.removeProfile(fileName: name)
        let afterRemoval = try await store.loadProfile(fileName: name)
        XCTAssertNil(afterRemoval)
        // Removal is idempotent.
        try await store.removeProfile(fileName: name)
    }

    func testProfileNamesThatEscapeTheDirectoryAreRefused() async throws {
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        let escaped = try await store.loadProfile(fileName: "../queue.json")
        XCTAssertNil(escaped)
        let nested = try await store.loadProfile(fileName: "a/b.mobileprovision")
        XCTAssertNil(nested)
    }

    func testRecoverySweepsOrphanedCopiesAndEarlierSessionsWorkingDirectories() async throws {
        // A working directory from an earlier session, then a store for
        // this session, then a working directory created by a live run.
        let stale = workingRoot.appendingPathComponent("zynsign-signing-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: stale.path
        )
        let store = FileSigningQueueStore(queueDirectory: queueDirectory, workingDirectoryRoot: workingRoot)
        let live = workingRoot.appendingPathComponent("zynsign-signing-live", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

        let kept = try await store.storeProfile(Data("kept".utf8), jobID: SigningJobIdentifier())
        let orphan = try await store.storeProfile(Data("orphan".utf8), jobID: SigningJobIdentifier())

        try await store.recoverWorkspace(referencedProfileFileNames: [kept])

        let keptData = try await store.loadProfile(fileName: kept)
        let orphanData = try await store.loadProfile(fileName: orphan)
        XCTAssertNotNil(keptData)
        XCTAssertNil(orphanData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "An earlier session's working copy is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "A live run's working copy is never touched")
    }
}
