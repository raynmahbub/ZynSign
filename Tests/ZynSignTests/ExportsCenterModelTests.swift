import XCTest
@testable import ZynSign

/// Tests for the Export Center's model — the list that makes every signed
/// artifact reachable again.
///
/// The screen itself is SwiftUI and needs a window; everything the user can
/// conclude from it is decided here, so this is where the rules are frozen:
///
/// - what is listed is a projection of the catalog, never an edited catalog;
/// - an artifact whose bytes are gone is still listed, and says so;
/// - a verification result replaces the row only after verification ran;
/// - a deletion removes the record it deleted and nothing else.
@MainActor
final class ExportsCenterModelTests: XCTestCase {

    private var root: URL!
    private var exports: ExportCenter!
    private var history: InMemorySigningHistoryStore!
    private var artifactsDirectory: URL!

    override func setUpWithError() throws {
        root = try LibraryFixtures.makeTemporaryDirectory()
        artifactsDirectory = root.appendingPathComponent("Signed", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        exports = ExportCenter(
            records: FileExportRecordStore(
                catalogLocation: root.appendingPathComponent("Exports.json", isDirectory: false)
            ),
            artifacts: FileExportArtifactStore(exportsDirectory: artifactsDirectory)
        )
        history = InMemorySigningHistoryStore()
    }

    override func tearDown() {
        exports = nil
        history = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Records an export and writes the artifact its record describes, so the
    /// entry is available the way a real signing run leaves it.
    @discardableResult
    private func holdExport(
        name: String,
        bundle: String = "com.zynsign.test",
        byteCount: Int = 2_048,
        createdAt: Date = Date(),
        verification: ArtifactVerificationStatus = .unsupported,
        delivered: Date? = nil
    ) async throws -> ExportRecord {
        let record = ExportRecord(
            sourceRecordIdentifier: nil,
            sourceArtifactIdentifier: nil,
            applicationName: name,
            bundleIdentifier: bundle,
            shortVersion: "1.0",
            buildVersion: "1",
            fileName: "\(name)_signed.ipa",
            byteCount: byteCount,
            fingerprint: nil,
            createdAt: createdAt,
            verificationStatus: verification,
            deliveredAt: delivered
        )
        try await exports.write(record)
        try Data(count: byteCount).write(to: artifactsDirectory.appendingPathComponent(record.fileName))
        return record
    }

    private func makeModel(
        verify: @escaping (ExportIdentifier) async throws -> ExportedArtifactVerification = { _ in
            throw ZynSignError.exportRecordNotFound(diagnosticDetail: "not scripted")
        }
    ) -> ExportsCenterModel {
        ExportsCenterModel(exports: exports, history: history, verifyExport: verify)
    }

    private func report(status: ArtifactVerificationStatus, verifiedAt: Date = Date()) -> ArtifactVerificationReport {
        let findings: [ArtifactVerificationFinding]
        switch status {
        case .valid:
            findings = []
        case .invalid:
            findings = [
                ArtifactVerificationFinding(
                    code: .containerUnreadable,
                    severity: .error,
                    detail: "The archive could not be read."
                ),
            ]
        case .warning, .unsupported:
            findings = [
                ArtifactVerificationFinding(
                    code: .bundleInformation,
                    severity: status == .warning ? .warning : .unsupported,
                    detail: "The bundle's metadata could not be fully read."
                ),
            ]
        }
        return ArtifactVerificationReport.derive(
            findings: findings,
            verifiedAt: verifiedAt,
            artifactByteCount: 2_048,
            checksRun: 4
        )
    }

    // MARK: - Listing

    func testALoadListsEveryExportNewestFirstWithItsAvailability() async throws {
        let older = try await holdExport(name: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = try await holdExport(name: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
        let model = makeModel()

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.entries.map(\.record.id), [newer.id, older.id])
        XCTAssertEqual(model.visibleEntries.map(\.record.id), [newer.id, older.id])
        XCTAssertTrue(model.entries.allSatisfy(\.isAvailable))
        XCTAssertEqual(model.unavailableCount, 0)
        XCTAssertFalse(model.isEmpty)
    }

    /// A record whose bytes are gone stays listed: it is part of the history of
    /// what the user signed, and hiding it would hide that the artifact is
    /// missing.
    func testARecordWhoseArtifactIsGoneIsStillListedAndSaysSo() async throws {
        let record = try await holdExport(name: "Vanished")
        try FileManager.default.removeItem(at: artifactsDirectory.appendingPathComponent(record.fileName))
        let model = makeModel()

        await model.load()

        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(entry.availability, .missing)
        XCTAssertFalse(entry.permitsArtifactActions)
        XCTAssertEqual(model.unavailableCount, 1)
        XCTAssertEqual(model.visibleEntries.count, 1, "A missing artifact is still listed.")
    }

    func testAnEmptyCatalogIsEmptyRatherThanFiltered() async {
        let model = makeModel()

        await model.load()

        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.isFilteredToNothing)
    }

    func testAQueryThatHidesEverythingIsReportedAsFilteredRatherThanEmpty() async throws {
        try await holdExport(name: "Hidden")
        let model = makeModel()
        await model.load()

        model.query.searchText = "nothing matches this"

        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.isFilteredToNothing)
        XCTAssertTrue(model.visibleEntries.isEmpty)
    }

    func testTheQueryNarrowsByVerificationAndSortsByIdentity() async throws {
        let valid = try await holdExport(name: "Valid", createdAt: Date(timeIntervalSince1970: 1_000), verification: .valid)
        let unsupported = try await holdExport(name: "Unknown", createdAt: Date(timeIntervalSince1970: 2_000))
        let model = makeModel()
        await model.load()

        model.query.verification = .valid
        XCTAssertEqual(model.visibleEntries.map(\.record.id), [valid.id])

        model.query.verification = .notVerified
        XCTAssertEqual(model.visibleEntries.map(\.record.id), [unsupported.id])

        model.query.verification = .any
        model.query.sort = .oldest
        XCTAssertEqual(model.visibleEntries.map(\.record.id), [valid.id, unsupported.id])
    }

    // MARK: - Verification

    func testVerificationReplacesTheRowWithWhatTheReportConcluded() async throws {
        let record = try await holdExport(name: "Sign Me")
        let concluded = report(status: .valid)
        let center: ExportCenter = exports
        let model = ExportsCenterModel(exports: center, history: history, verifyExport: { identifier in
            let updated = try await center.recordVerification(concluded, for: identifier)
            return ExportedArtifactVerification(record: updated, report: concluded)
        })
        await model.load()

        let entry = try XCTUnwrap(model.entries.first)
        await model.verify(entry)

        XCTAssertEqual(model.entries.first?.record.verificationStatus, .valid)
        XCTAssertEqual(model.verificationPresentation?.report.status, .valid)
        XCTAssertEqual(model.verificationPresentation?.id, record.id)
        XCTAssertTrue(model.verifyingIDs.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testAFailedVerificationIsReportedAndChangesNothing() async throws {
        let record = try await holdExport(name: "Refused")
        let model = makeModel()
        await model.load()

        let entry = try XCTUnwrap(model.entries.first)
        await model.verify(entry)

        XCTAssertEqual(model.entries.first?.record.verificationStatus, .unsupported, "The row keeps what the catalog says.")
        XCTAssertNil(model.verificationPresentation)
        XCTAssertEqual(model.notice?.title, "Verification Could Not Run")
        XCTAssertTrue(model.verifyingIDs.isEmpty)
        XCTAssertEqual(model.entries.map(\.record.id), [record.id])
    }

    // MARK: - Delivery and removal

    func testRecordingADeliveryMarksTheRowWithoutChangingTheArtifact() async throws {
        try await holdExport(name: "Delivered")
        let model = makeModel()
        await model.load()
        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertFalse(entry.record.hasBeenDelivered)

        await model.markDelivered(entry)

        XCTAssertTrue(model.entries.first?.record.hasBeenDelivered ?? false)
        XCTAssertTrue(model.entries.first?.isAvailable ?? false)
    }

    func testDeletingAnExportRemovesThatRecordAndNothingElse() async throws {
        let keep = try await holdExport(name: "Keep")
        let drop = try await holdExport(name: "Drop")
        let model = makeModel()
        await model.load()

        let doomed = try XCTUnwrap(model.entries.first { $0.record.id == drop.id })
        await model.remove(doomed)

        XCTAssertEqual(model.entries.map(\.record.id), [keep.id])
        XCTAssertEqual(model.notice?.title, "Exported Artifact Deleted")
        XCTAssertTrue(model.removingIDs.isEmpty)
        let remaining = try await exports.entries()
        XCTAssertEqual(remaining.map(\.record.id), [keep.id])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifactsDirectory.appendingPathComponent(keep.fileName).path
            ),
            "The artifact that was not deleted is untouched."
        )
    }

    // MARK: - Operation links

    func testAnExportIsLinkedToTheOperationThatProducedIt() async throws {
        let record = try await holdExport(name: "Linked")
        let operation = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: record.bundleIdentifier,
            sourceDisplayName: record.applicationName,
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: record.fileName,
            outputByteCount: record.byteCount,
            startedAt: Date(timeIntervalSince1970: 500),
            duration: 12,
            exportIdentifier: record.id.rawValue
        )
        try await history.append(operation)
        let model = makeModel()

        await model.load()

        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(model.operationRecord(for: entry.record)?.id, operation.id)
        XCTAssertEqual(model.exportEntry(for: operation)?.record.id, record.id)
    }

    func testAJournalWithoutTheOperationLeavesTheLinkEmpty() async throws {
        try await holdExport(name: "Unlinked")
        let model = makeModel()

        await model.load()

        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertNil(model.operationRecord(for: entry.record), "No operation is invented for an export the journal lost.")
    }
}
