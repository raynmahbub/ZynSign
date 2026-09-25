import XCTest
@testable import ZynSign

/// Tests for the library use case over in-memory record and artifact
/// stores: admission, the duplicate policy in action, the artifact–record
/// ordering, rollback, listing with availability, removal, and orphans.
final class ApplicationLibraryTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        let clock = SyntheticClock()
        library = ApplicationLibrary(
            records: records,
            artifacts: artifacts,
            now: { clock.now() }
        )
    }

    override func tearDown() {
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    /// Stages `content` for a fresh accepted artifact and returns the artifact.
    private func stagedArtifact(
        content: String = "synthetic package content",
        identity: ApplicationIdentity = LibraryFixtures.identity(),
        sourceFileName: String? = "Example.ipa"
    ) -> IPAArtifact {
        let artifact = LibraryFixtures.acceptedArtifact(sourceFileName: sourceFileName, identity: identity)
        artifacts.stage(Data(content.utf8), as: artifact.id)
        return artifact
    }

    // MARK: - Admission

    func testAdmittingAnAcceptedArtifactAdoptsItAndCreatesARecord() async throws {
        let artifact = stagedArtifact()

        let admission = try await library.admit(artifact)

        guard case .recorded(let record, let relation) = admission else {
            return XCTFail("Expected a recorded admission, got \(admission)")
        }
        XCTAssertEqual(relation, .unrelated)
        XCTAssertEqual(record.identity, artifact.metadata?.identity)
        XCTAssertEqual(record.artifact.artifactID, artifact.id)
        XCTAssertEqual(record.artifact.byteCount, "synthetic package content".utf8.count)
        XCTAssertEqual(record.artifact.fingerprint, LibraryFixtures.fingerprint(of: Data("synthetic package content".utf8)))
        XCTAssertEqual(record.importedAt, LibraryFixtures.importDate)
        XCTAssertEqual(record.sourceFileName, "Example.ipa")

        XCTAssertEqual(artifacts.adopted, [artifact.id])
        XCTAssertEqual(artifacts.held, [artifact.id])
        XCTAssertTrue(artifacts.staged.isEmpty)
        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored, record)
        XCTAssertEqual(admission.record, record)
    }

    func testAdmittingIdenticalContentAgainCreatesNothingAndAdoptsNothing() async throws {
        let first = stagedArtifact()
        let firstAdmission = try await library.admit(first)
        let again = stagedArtifact()

        let admission = try await library.admit(again)

        XCTAssertEqual(admission, .alreadyRecorded(existing: firstAdmission.record))
        XCTAssertEqual(artifacts.adopted, [first.id])
        XCTAssertEqual(artifacts.held, [first.id])
        // The surplus staged copy is left for the import flow to discard.
        XCTAssertEqual(artifacts.staged, [again.id])
        let count = await records.count
        XCTAssertEqual(count, 1)
    }

    func testIdenticalContentIsRecognisedWhateverItDeclares() async throws {
        let first = stagedArtifact()
        let firstAdmission = try await library.admit(first)
        let renamed = stagedArtifact(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.renamed", displayName: "Renamed"),
            sourceFileName: "Renamed.ipa"
        )

        let admission = try await library.admit(renamed)

        XCTAssertEqual(admission, .alreadyRecorded(existing: firstAdmission.record))
    }

    func testIdenticalContentIsRecordedAnewWhenTheEarlierArtifactIsMissing() async throws {
        let first = stagedArtifact()
        let firstRecord = try await library.admit(first).record
        artifacts.drop(firstRecord.artifact.artifactID)
        let again = stagedArtifact()

        let admission = try await library.admit(again)

        guard case .recorded(let record, let relation) = admission else {
            return XCTFail("Expected a recorded admission, got \(admission)")
        }
        XCTAssertEqual(relation, .sameDeclaredVersion([firstRecord]))
        XCTAssertEqual(record.artifact.fingerprint, firstRecord.artifact.fingerprint)
        XCTAssertNotEqual(record.artifact.artifactID, firstRecord.artifact.artifactID)
        XCTAssertEqual(artifacts.held, [again.id])

        // The earlier record is neither repaired nor removed.
        let entries = try await library.entries()
        XCTAssertEqual(entries.map { $0.artifactAvailability }, [.missing, .available])
    }

    func testAnotherVersionOfTheSameBundleIsRecordedWithItsRelation() async throws {
        let first = stagedArtifact(content: "version one")
        let firstAdmission = try await library.admit(first)
        let second = stagedArtifact(
            content: "version two",
            identity: LibraryFixtures.identity(shortVersion: "2.0", build: "50")
        )

        let admission = try await library.admit(second)

        guard case .recorded(let record, let relation) = admission else {
            return XCTFail("Expected a recorded admission, got \(admission)")
        }
        XCTAssertEqual(relation, .otherVersions([firstAdmission.record]))
        XCTAssertNotEqual(record.id, firstAdmission.record.id)
        XCTAssertEqual(artifacts.held, [first.id, second.id])
        let count = await records.count
        XCTAssertEqual(count, 2)
    }

    func testRebuiltPackageWithUnchangedMetadataIsRecordedAlongsideTheOriginal() async throws {
        let original = stagedArtifact(content: "original build")
        let originalAdmission = try await library.admit(original)
        let rebuilt = stagedArtifact(content: "rebuilt with the same declared version")

        let admission = try await library.admit(rebuilt)

        guard case .recorded(let record, let relation) = admission else {
            return XCTFail("Expected a recorded admission, got \(admission)")
        }
        XCTAssertEqual(relation, .sameDeclaredVersion([originalAdmission.record]))
        XCTAssertEqual(record.identity, originalAdmission.record.identity)
        let entries = try await library.entries()
        XCTAssertEqual(entries.map { $0.record.id }, [originalAdmission.record.id, record.id])
        XCTAssertEqual(artifacts.held, [original.id, rebuilt.id])
    }

    func testAdmittingARejectedArtifactFailsBeforeTouchingStorage() async throws {
        let artifact = LibraryFixtures.rejectedArtifact()
        artifacts.stage(Data("rejected".utf8), as: artifact.id)

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .internalFailure)
            XCTAssertEqual(error.userMessage, ZynSignError.unrecordableArtifact().userMessage)
        }

        XCTAssertTrue(artifacts.adopted.isEmpty)
        XCTAssertTrue(artifacts.held.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    func testAdmittingAnArtifactThatIsNotStagedFails() async throws {
        let artifact = LibraryFixtures.acceptedArtifact()

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.userMessage, ZynSignError.artifactNotAvailable().userMessage)
        }

        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    func testCancelledTaskDoesNotBeginAnAdmission() async throws {
        let artifact = stagedArtifact()
        let library = self.library!

        // The task cancels itself before calling the library, so the
        // cancellation is observed deterministically at the first check.
        let task = Task<LibraryAdmission, any Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.admit(artifact)
        }

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled admission to throw.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertTrue(artifacts.adopted.isEmpty)
        XCTAssertEqual(artifacts.staged, [artifact.id])
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Failure handling

    func testRecordWriteFailureRemovesTheAdoptedArtifactAgain() async throws {
        let artifact = stagedArtifact()
        await records.failInserts(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
            XCTAssertEqual(error.userMessage, ZynSignError.libraryStorageFailure().userMessage)
        }

        // The artifact was adopted first and rolled back after the failed write.
        XCTAssertEqual(artifacts.adopted, [artifact.id])
        XCTAssertEqual(artifacts.removed, [artifact.id])
        XCTAssertTrue(artifacts.held.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
        let orphans = try await library.orphanedArtifacts()
        XCTAssertTrue(orphans.isEmpty)
    }

    func testFailedRollbackLeavesADetectableOrphanAndNoRecord() async throws {
        let artifact = stagedArtifact()
        await records.failInserts(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))
        artifacts.failRemoval(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic removal failure"))

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            // The original failure is reported, not the rollback's.
            XCTAssertEqual(error.userMessage, ZynSignError.libraryStorageFailure().userMessage)
        }

        XCTAssertEqual(artifacts.held, [artifact.id])
        let count = await records.count
        XCTAssertEqual(count, 0)
        let orphans = try await library.orphanedArtifacts()
        XCTAssertEqual(orphans, [artifact.id])
    }

    func testAdoptionFailureWritesNoRecord() async throws {
        let artifact = stagedArtifact()
        artifacts.failAdoption(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }

        XCTAssertTrue(artifacts.held.isEmpty)
        XCTAssertEqual(artifacts.staged, [artifact.id])
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    func testDescribeFailureWritesNothing() async throws {
        let artifact = stagedArtifact()
        artifacts.failDescribing(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }

        XCTAssertTrue(artifacts.adopted.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    func testRecordListingFailureIsReportedBeforeAnythingIsAdopted() async throws {
        let artifact = stagedArtifact()
        await records.failListing(with: ZynSignError.libraryCatalogUnreadable(diagnosticDetail: "synthetic"))

        do {
            _ = try await library.admit(artifact)
            XCTFail("Expected the admission to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.userMessage, ZynSignError.libraryCatalogUnreadable().userMessage)
        }

        XCTAssertTrue(artifacts.adopted.isEmpty)
        XCTAssertEqual(artifacts.staged, [artifact.id])
    }

    // MARK: - Listing and availability

    func testEntriesReportAvailabilityFromArtifactStorage() async throws {
        let available = try await library.admit(stagedArtifact(content: "available")).record
        let missing = try await library.admit(stagedArtifact(content: "missing")).record
        let inconsistent = try await library.admit(stagedArtifact(content: "inconsistent content")).record
        artifacts.drop(missing.artifact.artifactID)
        artifacts.truncate(inconsistent.artifact.artifactID, to: 4)

        let entries = try await library.entries()

        XCTAssertEqual(entries.map { $0.record.id }, [available.id, missing.id, inconsistent.id])
        XCTAssertEqual(entries[0].artifactAvailability, .available)
        XCTAssertEqual(entries[1].artifactAvailability, .missing)
        XCTAssertEqual(
            entries[2].artifactAvailability,
            .inconsistent(recordedByteCount: "inconsistent content".utf8.count, observedByteCount: 4)
        )
        XCTAssertEqual(entries.filter { $0.isArtifactAvailable }.map { $0.record.id }, [available.id])

        // Missing artifacts are reported, never recreated, and the record
        // stays intact for diagnosis.
        XCTAssertEqual(artifacts.held, [available.artifact.artifactID, inconsistent.artifact.artifactID])
        let stillStored = try await records.record(withID: missing.id)
        XCTAssertEqual(stillStored, missing)
    }

    func testEntryByIdentifierReflectsCurrentAvailability() async throws {
        let record = try await library.admit(stagedArtifact()).record

        let before = try await library.entry(withID: record.id)
        artifacts.drop(record.artifact.artifactID)
        let after = try await library.entry(withID: record.id)
        let unknown = try await library.entry(withID: ApplicationRecordIdentifier())

        XCTAssertEqual(before?.artifactAvailability, .available)
        XCTAssertEqual(after?.artifactAvailability, .missing)
        XCTAssertEqual(after?.record, record)
        XCTAssertNil(unknown)
    }

    // MARK: - Removal

    func testRemovingAnEntryDeletesTheRecordAndThenTheArtifact() async throws {
        let record = try await library.admit(stagedArtifact()).record

        try await library.remove(recordWithID: record.id)

        let stored = try await records.record(withID: record.id)
        XCTAssertNil(stored)
        XCTAssertTrue(artifacts.held.isEmpty)
        XCTAssertEqual(artifacts.removed, [record.artifact.artifactID])
        let entries = try await library.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemovingAnEntryWhoseArtifactIsAlreadyGoneSucceeds() async throws {
        let record = try await library.admit(stagedArtifact()).record
        artifacts.drop(record.artifact.artifactID)

        try await library.remove(recordWithID: record.id)

        let entries = try await library.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemovingAnUnknownRecordFails() async throws {
        do {
            try await library.remove(recordWithID: ApplicationRecordIdentifier())
            XCTFail("Expected the removal to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.userMessage, ZynSignError.libraryRecordNotFound().userMessage)
        }
    }

    func testArtifactRemovalFailureAfterRecordDeletionLeavesADetectableOrphan() async throws {
        let record = try await library.admit(stagedArtifact()).record
        artifacts.failRemoval(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))

        do {
            try await library.remove(recordWithID: record.id)
            XCTFail("Expected the removal to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }

        let stored = try await records.record(withID: record.id)
        XCTAssertNil(stored)
        let orphans = try await library.orphanedArtifacts()
        XCTAssertEqual(orphans, [record.artifact.artifactID])
    }

    // MARK: - Orphans

    func testOrphanDetectionReportsOnlyArtifactsNoRecordRefersTo() async throws {
        let record = try await library.admit(stagedArtifact()).record
        let orphan = ArtifactIdentifier()
        artifacts.hold(Data("left behind".utf8), as: orphan)

        let orphans = try await library.orphanedArtifacts()

        XCTAssertEqual(orphans, [orphan])
        XCTAssertEqual(artifacts.held, [record.artifact.artifactID, orphan])
    }

    func testOrphanRemovalIsExplicitAndLeavesRecordedArtifactsAlone() async throws {
        let record = try await library.admit(stagedArtifact()).record
        let orphan = ArtifactIdentifier()
        artifacts.hold(Data("left behind".utf8), as: orphan)

        let entriesBefore = try await library.entries()
        XCTAssertEqual(artifacts.held.count, 2, "Listing must not remove orphans on its own.")
        XCTAssertEqual(entriesBefore.count, 1)

        let removed = try await library.removeOrphanedArtifacts()

        XCTAssertEqual(removed, [orphan])
        XCTAssertEqual(artifacts.held, [record.artifact.artifactID])
        let entriesAfter = try await library.entries()
        XCTAssertEqual(entriesAfter.first?.artifactAvailability, .available)
    }

    // MARK: - Favourites

    func testSettingAFavouriteMarksTheRecordAndKeepsEverythingElse() async throws {
        let record = try await library.admit(stagedArtifact()).record

        try await library.setFavorite(true, recordWithID: record.id)

        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored?.isFavorite, true)
        // The change touches the mark and the change time only.
        XCTAssertEqual(stored?.importedAt, record.importedAt)
        XCTAssertEqual(stored?.identity, record.identity)
        XCTAssertEqual(stored?.artifact, record.artifact)
        XCTAssertNotEqual(stored?.updatedAt, record.updatedAt)
    }

    func testClearingAFavouriteMarksTheRecordNotFavourite() async throws {
        let record = try await library.admit(stagedArtifact()).record
        try await library.setFavorite(true, recordWithID: record.id)

        try await library.setFavorite(false, recordWithID: record.id)

        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored?.isFavorite, false)
    }

    func testSettingTheMarkARecordAlreadyCarriesChangesNothing() async throws {
        let record = try await library.admit(stagedArtifact()).record

        try await library.setFavorite(false, recordWithID: record.id)

        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored, record)
    }

    func testSettingAFavouriteForAnUnknownRecordFailsWithATypedError() async throws {
        do {
            try await library.setFavorite(true, recordWithID: ApplicationRecordIdentifier())
            XCTFail("Expected a typed failure for a record the library does not hold.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }
    }

    func testAFavouriteMarkSurvivesListingAndDoesNotAffectAvailability() async throws {
        let record = try await library.admit(stagedArtifact()).record
        try await library.setFavorite(true, recordWithID: record.id)

        let entries = try await library.entries()

        XCTAssertEqual(entries.first?.record.isFavorite, true)
        XCTAssertEqual(entries.first?.artifactAvailability, .available)
    }
}
