import XCTest
@testable import ZynSign

/// Tests for duplicate detection in the import pipeline.
///
/// These run the real import use case over the real library, with synthetic
/// ports underneath, and assert the four things a person cares about when
/// they import a package the library may already hold: the comparison is
/// about the bytes, the question is asked only when there is something to
/// decide, every answer does exactly what it says, and the file they chose is
/// never what gets changed.
@MainActor
final class DuplicateImportTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var intake: SyntheticIntake!
    private var library: ApplicationLibrary!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        let clock = SyntheticClock()
        library = ApplicationLibrary(
            records: records,
            artifacts: artifacts,
            now: { [clock] in clock.now() }
        )
        intake = SyntheticIntake()
        intake.artifactStore = artifacts
    }

    override func tearDown() {
        library = nil
        intake = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePipeline(
        reader: SyntheticArchiveReader = ImportFixtures.validReader()
    ) -> IPAPackageImport {
        IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            library: library
        )
    }

    /// Imports the selected package once, letting the library's own duplicate
    /// policy decide.
    private func importPackage(
        content: Data,
        sourceName: String = "Example.ipa"
    ) async throws -> PackageImportResult {
        intake.nextStagedContent = content
        return try await makePipeline().importArtifact(from: ImportFixtures.sourceURL(name: sourceName))
    }

    /// Imports the selected package once, asking `decisions` how to answer a
    /// collision.
    private func importPackage(
        content: Data,
        sourceName: String = "Example.ipa",
        answering decisions: SyntheticDecisionProvider
    ) async throws -> PackageImportResult {
        intake.nextStagedContent = content
        return try await makePipeline().importArtifact(
            from: ImportFixtures.sourceURL(name: sourceName),
            reporting: nil,
            resolvingDuplicatesWith: decisions.provider()
        )
    }

    // MARK: - Recognising content the library holds

    func testImportingTheSameBytesAgainIsRecognisedAndStoresNothing() async throws {
        let content = Data("first package bytes".utf8)
        let first = try await importPackage(content: content)
        guard case .recorded(let record, _) = first.admission else {
            return XCTFail("Expected the first import to be recorded, got \(String(describing: first.admission))")
        }

        let second = try await importPackage(content: content)

        guard case .alreadyRecorded(let existing) = second.admission else {
            return XCTFail("Expected the second import to be recognised, got \(String(describing: second.admission))")
        }
        XCTAssertEqual(existing.id, record.id)
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 1)

        // The surplus staged copy is discarded rather than left behind, and
        // the artifact the library already holds is untouched.
        XCTAssertTrue(intake.discarded.contains(second.artifact.id))
        XCTAssertEqual(artifacts.held, [record.artifact.artifactID])
    }

    func testADifferentVersionIsNotACollisionAndIsNotAskedAbout() async throws {
        // A record for an earlier version of the same application, held by
        // the library so it is a real neighbour rather than a stale record.
        let existing = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.1"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x21)
        )
        try await records.insert(existing)
        artifacts.hold(Data(count: existing.artifact.byteCount), as: existing.artifact.artifactID)

        let decisions = SyntheticDecisionProvider(answer: .cancel)
        let second = try await importPackage(
            content: Data("a newer version of the same application".utf8),
            answering: decisions
        )

        // Version and build were used to find the application again, so a
        // differing version is information rather than a conflict: the
        // question is not asked at all.
        XCTAssertTrue(decisions.reports.isEmpty, "The question was asked when there was nothing to decide.")
        guard case .recorded(_, let relation) = second.admission else {
            return XCTFail("Expected the import to be recorded, got \(String(describing: second.admission))")
        }
        XCTAssertEqual(relation, .otherVersions([existing]))
        XCTAssertEqual(second.duplicate?.report.matches.first?.kind, .otherVersion)
        XCTAssertNil(second.duplicate?.resolution)
        XCTAssertEqual(ImportSettlement.from(second).kind, .imported)

        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.id == existing.id })
    }

    func testTheIdenticalContentQuestionOffersAllThreeAnswers() async throws {
        let content = Data("package bytes to compare".utf8)
        _ = try await importPackage(content: content)

        let decisions = SyntheticDecisionProvider(answer: .cancel)
        do {
            _ = try await importPackage(content: content, answering: decisions)
            XCTFail("Expected cancelling the question to cancel the import.")
        } catch {
            // Cancelling the question is an ordinary outcome: the import
            // stops, and the library is exactly as it was.
            XCTAssertEqual(ImportSettlement.from(error: error).kind, .cancelled)
        }

        let report = try XCTUnwrap(decisions.reports.first)
        XCTAssertTrue(report.requiresDecision)
        XCTAssertEqual(report.decisiveMatches.count, 1)
        XCTAssertEqual(report.decisiveMatches.first?.kind, .identicalContent)
        XCTAssertEqual(report.offeredResolutions, [.keepBoth, .replaceExisting, .cancel])

        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(intake.discarded.count == 1)
    }

    // MARK: - Keeping both

    func testKeepingBothStoresAFurtherEntryAndLeavesTheExistingOneAlone() async throws {
        let content = Data("package bytes to keep".utf8)
        let first = try await importPackage(content: content)
        guard case .recorded(let original, _) = first.admission else {
            return XCTFail("Expected the first import to be recorded.")
        }

        let decisions = SyntheticDecisionProvider(answer: .keepBoth)
        let second = try await importPackage(content: content, answering: decisions)

        XCTAssertEqual(decisions.resolutions, [.keepBoth])
        guard case .recorded(let added, let relation) = second.admission else {
            return XCTFail("Expected keeping both to record a further entry, got \(String(describing: second.admission))")
        }
        XCTAssertNotEqual(added.id, original.id)
        XCTAssertEqual(relation, .sameDeclaredVersion([original]))

        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.id == original.id })
        XCTAssertEqual(second.duplicate?.resolution, .keepBoth)
        XCTAssertEqual(second.duplicate?.replacedRecords, [])
    }

    // MARK: - Replacing

    func testReplacingStoresTheNewEntryAndRemovesWhatItMatched() async throws {
        let content = Data("package bytes to replace".utf8)
        let first = try await importPackage(content: content)
        guard case .recorded(let original, _) = first.admission else {
            return XCTFail("Expected the first import to be recorded.")
        }

        let decisions = SyntheticDecisionProvider(answer: .replaceExisting)
        let second = try await importPackage(content: content, answering: decisions)

        guard case .recorded(let added, _) = second.admission else {
            return XCTFail("Expected the replacement to be recorded first.")
        }
        XCTAssertEqual(second.duplicate?.resolution, .replaceExisting)
        XCTAssertEqual(second.duplicate?.replacedRecords, [original])
        XCTAssertEqual(second.duplicate?.retainedRecords, [])

        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map(\.id), [added.id])
        // The artifact behind the replaced record is gone with it, so the
        // library never lists an entry it cannot show.
        XCTAssertEqual(artifacts.held, [added.artifact.artifactID])
        XCTAssertTrue(intake.discarded.isEmpty, "The adopted copy must not be discarded.")
    }

    func testReplacingKeepsEntriesItDidNotMatch() async throws {
        let content = Data("package bytes with a neighbour".utf8)
        // A record for another version of the same application: related, but
        // not a collision, so a replacement must not take it.
        let neighbour = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.1"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x11)
        )
        try await records.insert(neighbour)
        artifacts.hold(Data(count: neighbour.artifact.byteCount), as: neighbour.artifact.artifactID)

        let first = try await importPackage(content: content)
        guard case .recorded(let original, _) = first.admission else {
            return XCTFail("Expected the first import to be recorded.")
        }

        let decisions = SyntheticDecisionProvider(answer: .replaceExisting)
        let second = try await importPackage(content: content, answering: decisions)
        guard case .recorded(let added, _) = second.admission else {
            return XCTFail("Expected the replacement to be recorded.")
        }

        let stored = try await records.allRecords()
        XCTAssertEqual(Set(stored.map(\.id)), Set([added.id, neighbour.id]))
        XCTAssertEqual(second.duplicate?.replacedRecords, [original])
        XCTAssertFalse(stored.contains { $0.id == original.id })
    }

    func testAFailedRemovalIsReportedRatherThanHidden() async throws {
        let content = Data("package bytes that cannot evict".utf8)
        let first = try await importPackage(content: content)
        guard case .recorded(let original, _) = first.admission else {
            return XCTFail("Expected the first import to be recorded.")
        }

        await records.failDeletion(
            with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic delete failure")
        )

        let decisions = SyntheticDecisionProvider(answer: .replaceExisting)
        let second = try await importPackage(content: content, answering: decisions)

        guard case .recorded(let added, _) = second.admission else {
            return XCTFail("Expected the new entry to be stored regardless.")
        }
        // The new entry is stored first, so a removal that fails leaves the
        // library holding more than asked rather than less — and says so.
        XCTAssertEqual(second.duplicate?.replacedRecords, [])
        XCTAssertEqual(second.duplicate?.retainedRecords, [original])
        let stored = try await records.allRecords()
        XCTAssertEqual(Set(stored.map(\.id)), Set([added.id, original.id]))

        let settlement = ImportSettlement.from(second)
        XCTAssertEqual(settlement.kind, .replaced)
        XCTAssertTrue(
            ImportQueueRendering.message(for: settlement).contains("could not be removed")
        )
    }

    // MARK: - The user's file

    func testComparisonReadsTheStagedCopyAndNeverTheSelectedFile() async throws {
        let container = Data(ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage()))
        let source = ImportFixtures.writeFile(
            named: "Example.ipa",
            content: container,
            in: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: source) }

        intake.nextStagedContent = container
        let pipeline = makePipeline()
        let first = try await pipeline.importArtifact(from: source)
        XCTAssertNotNil(first.admission)

        let decisions = SyntheticDecisionProvider(answer: .cancel)
        intake.nextStagedContent = container
        _ = try? await makePipeline().importArtifact(
            from: source,
            reporting: nil,
            resolvingDuplicatesWith: decisions.provider()
        )

        // The comparison found the duplicate in the staged copy; the file the
        // user chose is byte-for-byte what it was, and still exists.
        XCTAssertEqual(decisions.reports.count, 1)
        XCTAssertEqual(FileManager.default.contents(atPath: source.path), container)
    }
}

// MARK: - Decision provider double

/// Answers duplicate questions on the test's behalf and records what it was
/// asked, so a test can assert both the answer's effect and the questions
/// that were never asked.
private final class SyntheticDecisionProvider: @unchecked Sendable {

    private let lock = NSLock()
    private var storedReports: [DuplicateReport] = []
    private var storedResolutions: [DuplicateResolution] = []
    private var storedAnswer: DuplicateResolution

    init(answer: DuplicateResolution) {
        storedAnswer = answer
    }

    var reports: [DuplicateReport] {
        lock.withLock { storedReports }
    }

    var resolutions: [DuplicateResolution] {
        lock.withLock { storedResolutions }
    }

    /// The provider the pipeline calls, which records the question and
    /// answers with the configured resolution.
    func provider() -> DuplicateDecisionProvider {
        { [self] report in
            let answer: DuplicateResolution = lock.withLock {
                storedReports.append(report)
                storedResolutions.append(storedAnswer)
                return storedAnswer
            }
            return answer
        }
    }
}
