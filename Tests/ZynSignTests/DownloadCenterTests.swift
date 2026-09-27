import XCTest
@testable import ZynSign

/// The Download Center's promises: jobs stay isolated, waiting order is
/// controllable, validation gates import, duplicates are never overwritten
/// silently, an interruption is not reported as success, and cleanup cannot
/// reach files outside the center's own directory.
@MainActor
final class DownloadCenterTests: XCTestCase {

    private var root: URL!
    private var transfer: ScriptedDownloadTransfer!
    private var validator: ScriptedDownloadValidator!
    private var importer: SpyDownloadImporter!
    private var center: DownloadCenter!
    private var installed: [InstalledApplication] = []
    private var catalogs: [RepositoryCatalog] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transfer = ScriptedDownloadTransfer()
        validator = ScriptedDownloadValidator()
        importer = SpyDownloadImporter()
        center = makeCenter()
        center.startObservingTransfers()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        center = nil
        try await super.tearDown()
    }

    func testDirectLinkIsQueuedAndDoesNotImportBeforeValidation() async throws {
        let result = await center.enqueueUserLink("https://example.com/apps/Demo.ipa")
        guard case let .queued(id) = result else {
            return XCTFail("Expected a queued download, got \(result)")
        }
        let started = await waitUntil { self.transfer.requests.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(center.job(withID: id)?.state, .connecting)
        XCTAssertTrue(importer.imported.isEmpty)

        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(id, .completed(fileURL: file, byteCount: 128))
        let ready = await waitUntil { self.center.job(withID: id)?.isImportReady == true }
        XCTAssertTrue(ready)
        XCTAssertTrue(importer.imported.isEmpty, "Validation must not import by itself")
        XCTAssertEqual(center.history.first?.validationPassed, true)
    }

    func testValidationFailureIsolatesAndDoesNotImport() async throws {
        let result = await center.enqueueUserLink("https://example.com/broken.ipa")
        guard case let .queued(id) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = DownloadArtifactValidation(
            archiveReadable: false,
            ipaStructureAccepted: false,
            extractionReady: false,
            metadataAvailable: false,
            checksumMatched: nil,
            summary: "The download could not be read as an archive. It was kept isolated and was not imported.",
            detail: "Not a zip.",
            checkedAt: Date(timeIntervalSince1970: 10)
        )
        transfer.finish(id, .completed(fileURL: file, byteCount: 32))
        let failed = await waitUntil { self.center.job(withID: id)?.isFailed == true }
        XCTAssertTrue(failed)
        XCTAssertTrue(importer.imported.isEmpty)
        XCTAssertEqual(center.history.first?.validationPassed, false)
        let isolated = root.appendingPathComponent("Isolated/\(id.rawValue)/payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated.path))
        let message = await center.importNow(id)
        XCTAssertNotNil(message)
        XCTAssertTrue(importer.imported.isEmpty)
    }

    func testRepositoryDownloadRequiresAValidatedCatalogAddress() async {
        let request = sampleRequest(kind: DownloadRequest.kindRepository, url: "https://example.com/missing.ipa")
        let result = await center.enqueue(request)
        guard case let .rejected(message) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("validated"))
        XCTAssertTrue(transfer.requests.isEmpty)
    }

    func testRepositoryDownloadQueuesWhenTheAddressIsInTheCatalog() async {
        catalogs = [sampleCatalog(downloadURL: "https://cdn.example.com/Demo.ipa")]
        let request = sampleRequest(kind: DownloadRequest.kindUpdate, url: "https://cdn.example.com/Demo.ipa", bundle: "com.example.demo", version: "1.3")
        let result = await center.enqueue(request)
        guard case .queued = result else { return XCTFail("\(result)") }
    }

    func testDuplicateSameVersionAsksAndNeverOverwritesSilently() async throws {
        catalogs = [sampleCatalog(downloadURL: "https://cdn.example.com/Demo.ipa")]
        let first = sampleRequest(kind: DownloadRequest.kindUpdate, url: "https://cdn.example.com/Demo.ipa", bundle: "com.example.demo", version: "1.3")
        guard case let .queued(id) = await center.enqueue(first) else { return XCTFail("first") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(id, .completed(fileURL: file, byteCount: 64))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.isImportReady == true })

        let secondURL = "https://cdn.example.com/Demo-again.ipa"
        catalogs = [sampleCatalog(downloadURL: secondURL)]
        let second = sampleRequest(kind: DownloadRequest.kindUpdate, url: secondURL, bundle: "com.example.demo", version: "1.3", source: "Other")
        let collision = await center.enqueue(second)
        guard case let .needsDecision(promptID) = collision else { return XCTFail("\(collision)") }
        XCTAssertEqual(center.jobs.count, 1)

        let skipped = await center.resolveDuplicate(promptID, choice: .skip)
        XCTAssertEqual(skipped, .skipped)
        XCTAssertEqual(center.jobs.count, 1)

        let again = await center.enqueue(second)
        guard case let .needsDecision(againID) = again else { return XCTFail("\(again)") }
        let kept = await center.resolveDuplicate(againID, choice: .keepBoth)
        guard case .queued = kept else { return XCTFail("\(kept)") }
        XCTAssertEqual(center.jobs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts/\(id.rawValue).ipa").path))
    }

    func testReplaceDoesNotDeleteThePreviousFileUntilTheNewOneValidates() async throws {
        catalogs = [sampleCatalog(downloadURL: "https://cdn.example.com/Demo.ipa")]
        let first = sampleRequest(kind: DownloadRequest.kindUpdate, url: "https://cdn.example.com/Demo.ipa", bundle: "com.example.demo", version: "1.3")
        guard case let .queued(oldID) = await center.enqueue(first) else { return XCTFail("first") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let oldFile = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(oldID, .completed(fileURL: oldFile, byteCount: 64))
        XCTAssertTrue(await waitUntil { self.center.job(withID: oldID)?.isImportReady == true })

        let secondURL = "https://cdn.example.com/Demo-2.ipa"
        catalogs = [sampleCatalog(downloadURL: secondURL)]
        let second = sampleRequest(kind: DownloadRequest.kindUpdate, url: secondURL, bundle: "com.example.demo", version: "1.3")
        guard case let .needsDecision(promptID) = await center.enqueue(second) else { return XCTFail("prompt") }
        guard case let .queued(newID) = await center.resolveDuplicate(promptID, choice: .replace) else { return XCTFail("replace") }
        XCTAssertNotNil(center.job(withID: oldID), "Replace must not delete the old download before the new one validates")
        XCTAssertEqual(center.job(withID: newID)?.replacesJobIDs, [oldID])
    }

    func testImportedAppConflictDoesNotNameALibraryFileAsTheReplaceTarget() async {
        installed = [InstalledApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: "1.3", build: "1", recordID: "record")]
        catalogs = [sampleCatalog(downloadURL: "https://cdn.example.com/Demo.ipa")]
        let request = sampleRequest(kind: DownloadRequest.kindUpdate, url: "https://cdn.example.com/Demo.ipa", bundle: "com.example.demo", version: "1.3")
        guard case let .needsDecision(promptID) = await center.enqueue(request) else { return XCTFail("expected a decision") }
        let prompt = center.pendingDecisions.first { $0.id == promptID }
        XCTAssertEqual(prompt?.conflicts.first?.kind, .sameVersionImported)
        XCTAssertNil(prompt?.conflicts.first?.downloadJobID)
        XCTAssertTrue(prompt?.explanation.contains("Imported applications are not deleted") == true)
    }

    func testPrioritiesAndReorderingApplyOnlyToWaitingJobs() async {
        let low = await center.enqueueUserLink("https://example.com/low.ipa", priority: .low)
        guard case .queued = low else { return XCTFail("\(low)") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let runningID = transfer.requests[0].jobID
        let high = await center.enqueueUserLink("https://example.com/high.ipa", priority: .high)
        guard case let .queued(highID) = high else { return XCTFail("\(high)") }
        XCTAssertEqual(center.job(withID: runningID)?.isTransferring, true)
        XCTAssertEqual(center.queuedJobs.map(\.id), [highID])
        center.setPriority(.high, on: runningID)
        XCTAssertEqual(center.job(withID: runningID)?.priority, .low, "A running transfer is not reprioritized")

        _ = await center.enqueueUserLink("https://example.com/normal.ipa", priority: .normal)
        XCTAssertEqual(center.queuedJobs.map(\.priority), [.high, .normal])
        center.move(highID, up: false)
        XCTAssertEqual(center.queuedJobs.map(\.priority), [.normal, .high])
        center.sendToTop(highID)
        XCTAssertEqual(center.queuedJobs.first?.id, highID)
    }

    func testPauseWithoutResumeDataDoesNotClaimResume() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        center.pause(id)
        transfer.finish(id, .paused(resumeData: nil))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.isPaused == true })
        XCTAssertEqual(center.job(withID: id)?.resumeFact, .notCaptured)
        XCTAssertEqual(center.job(withID: id)?.resumeFact.explanation.contains("starts it again"), true)
    }

    func testPauseWithResumeDataSaysTheServerMayRefuseIt() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        center.pause(id)
        transfer.finish(id, .paused(resumeData: Data("resume".utf8)))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.resumeFact == .held })
        XCTAssertTrue(center.job(withID: id)?.resumeFact.explanation.contains("depends on the server") == true)
    }

    func testInterruptedJobRestoresAsFailedNeverCompleted() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.state == .connecting })
        await center.flushPersistence()

        let restored = makeCenter()
        await restored.restore()
        let job = restored.job(withID: id)
        XCTAssertEqual(job?.isFailed, true)
        XCTAssertNotEqual(job?.isImportReady, true)
        XCTAssertEqual(job?.failure?.summary.contains("interrupted"), true)
        XCTAssertEqual(job?.failure?.isRetryable, true)
    }

    func testCompletedDownloadSurvivesRestore() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(id, .completed(fileURL: file, byteCount: 40))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.isImportReady == true })
        await center.flushPersistence()

        let restored = makeCenter()
        await restored.restore()
        XCTAssertEqual(restored.job(withID: id)?.isImportReady, true)
        XCTAssertEqual(restored.history.first?.validationPassed, true)
    }

    func testSigningHandoffImportsAndDoesNotStartSigning() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(id, .completed(fileURL: file, byteCount: 40))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.isImportReady == true })
        let message = await center.requestSigningHandoff(id)
        XCTAssertNil(message)
        XCTAssertEqual(importer.imported.count, 1)
        XCTAssertEqual(center.job(withID: id)?.handoff, .signingRequested)
        XCTAssertEqual(center.job(withID: id)?.log.contains { $0.message.contains("has not started") }, true)
    }

    func testClearCompletedDoesNotDeleteASiblingLibraryFile() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.transfer.requests.count == 1 })
        let file = try writePayload(in: transfer.requests[0].destinationDirectory)
        validator.result = passingValidation()
        transfer.finish(id, .completed(fileURL: file, byteCount: 40))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.isImportReady == true })

        let library = root.deletingLastPathComponent().appendingPathComponent("LibrarySurvivor-\(UUID().uuidString).ipa")
        try Data("library".utf8).write(to: library)
        defer { try? FileManager.default.removeItem(at: library) }
        center.clearCompleted()
        let artifact = root.appendingPathComponent("Artifacts/\(id.rawValue).ipa")
        let removed = await waitUntil { !FileManager.default.fileExists(atPath: artifact.path) }
        XCTAssertTrue(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    }

    func testStorageReportDoesNotCountFilesOutsideTheCenter() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("Outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: outside.appendingPathComponent("secret.ipa"))
        defer { try? FileManager.default.removeItem(at: outside) }
        let report = await center.storageReport()
        XCTAssertEqual(report.downloadedIPABytes, 0)
        XCTAssertEqual(report.totalBytes, 0)
        _ = await center.clearTemporaryData()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.ipa").path))
    }

    func testProgressDoesNotInventAPercentageOrMoveBackwards() async throws {
        guard case let .queued(id) = await center.enqueueUserLink("https://example.com/app.ipa") else { return XCTFail("queue") }
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.state == .connecting })
        XCTAssertNil(center.job(withID: id)?.progress.fraction)
        transfer.emit(id, DownloadTransferProgress(receivedBytes: 80, expectedBytes: 100))
        XCTAssertTrue(await waitUntil { self.center.job(withID: id)?.progress.receivedBytes == 80 })
        XCTAssertEqual(center.job(withID: id)?.progress.fraction, 0.8)
        transfer.emit(id, DownloadTransferProgress(receivedBytes: 10, expectedBytes: 100))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(center.job(withID: id)?.progress.receivedBytes, 80)
    }

    func testHTTPAndCredentialURLsAreRefusedBeforeAnyRequest() async {
        let http = await center.enqueueUserLink("http://example.com/app.ipa")
        guard case let .rejected(httpMessage) = http else { return XCTFail("\(http)") }
        XCTAssertTrue(httpMessage.contains("https"))
        let credentials = await center.enqueueUserLink("https://user:secret@example.com/app.ipa")
        guard case let .rejected(credentialMessage) = credentials else { return XCTFail("\(credentials)") }
        XCTAssertTrue(credentialMessage.contains("password"))
        XCTAssertTrue(transfer.requests.isEmpty)
    }

    func testStoreRefusesToAdoptAFileOutsideItsRoot() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).ipa")
        try Data("library".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let store = FileDownloadCenterStore(rootDirectory: root)
        do {
            try await store.promoteToArtifact(from: outside, jobID: DownloadJobIdentifier())
            XCTFail("A file outside download storage must not be moved")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    func testTransferHonestyFlagsStayFalse() {
        XCTAssertFalse(DownloadTransferHonesty.claimsBackgroundRelaunch)
        XCTAssertFalse(DownloadTransferHonesty.claimsUniversalResume)
    }

    // MARK: - Helpers

    private func makeCenter() -> DownloadCenter {
        let store = FileDownloadCenterStore(rootDirectory: root)
        let built = DownloadCenter(
            transfer: transfer,
            validator: validator,
            store: store,
            importer: importer,
            installedApplications: { self.installed },
            catalogs: { self.catalogs },
            maximumConcurrentTransfers: 1,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        built.startObservingTransfers()
        return built
    }

    private func writePayload(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: url)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func passingValidation() -> DownloadArtifactValidation {
        DownloadArtifactValidation(
            archiveReadable: true,
            ipaStructureAccepted: true,
            extractionReady: true,
            metadataAvailable: true,
            checksumMatched: nil,
            summary: "The file can be read as an app package and declares metadata. It has not been imported.",
            detail: nil,
            checkedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func sampleRequest(kind: String, url: String, bundle: String? = nil, version: String? = nil, source: String = "Example") -> DownloadRequest {
        DownloadRequest(
            displayName: "Demo",
            bundleIdentifier: bundle,
            version: version,
            build: "1",
            sourceName: source,
            sourceKind: kind,
            sourceIdentifier: "https://example.com/apps.json",
            remoteURL: URL(string: url)!,
            iconURL: nil,
            expectedSHA256: nil,
            expectedByteCount: nil,
            releaseNotes: "Notes",
            releaseDate: "2026-01-01",
            versionHistory: []
        )
    }

    private func sampleCatalog(downloadURL: String) -> RepositoryCatalog {
        let version = RepositoryAppVersion(
            version: "1.3",
            build: "1",
            date: "2026-01-01",
            notes: "Notes",
            downloadURL: downloadURL,
            size: 128,
            sha256: nil
        )
        let app = RepositoryApp(
            name: "Demo",
            bundleIdentifier: "com.example.demo",
            subtitle: nil,
            developerName: nil,
            summary: nil,
            iconURL: nil,
            versions: [version],
            latest: version,
            versionComparisonIsDefinite: true
        )
        return RepositoryCatalog(
            name: "Example",
            identifier: "example",
            sourceURL: "https://example.com/apps.json",
            apps: [app],
            fetchedAt: Date(timeIntervalSince1970: 10),
            skippedAppCount: 0
        )
    }
}

private final class ScriptedDownloadTransfer: DownloadTransferring {
    private(set) var requests: [DownloadTransferRequest] = []
    private weak var observer: DownloadTransferObserver?

    func setObserver(_ observer: DownloadTransferObserver?) { self.observer = observer }
    func start(_ request: DownloadTransferRequest) { requests.append(request) }
    func pause(jobID: DownloadJobIdentifier) {}
    func cancel(jobID: DownloadJobIdentifier) {}

    func emit(_ id: DownloadJobIdentifier, _ progress: DownloadTransferProgress) {
        observer?.downloadTransfer(id, progress: progress)
    }

    func finish(_ id: DownloadJobIdentifier, _ result: DownloadTransferFinish) {
        observer?.downloadTransfer(id, finished: result)
    }
}

private final class ScriptedDownloadValidator: DownloadValidating {
    var result = DownloadArtifactValidation(
        archiveReadable: true,
        ipaStructureAccepted: true,
        extractionReady: true,
        metadataAvailable: true,
        checksumMatched: nil,
        summary: "Ready",
        detail: nil,
        checkedAt: Date(timeIntervalSince1970: 1)
    )

    func validate(fileAt url: URL, expectedSHA256: String?) async -> DownloadArtifactValidation {
        result
    }
}

private final class SpyDownloadImporter: DownloadImporting {
    private(set) var imported: [URL] = []

    func importDownloadedPackage(at fileURL: URL) async -> [ImportJobIdentifier] {
        imported.append(fileURL)
        return [ImportJobIdentifier()]
    }
}
