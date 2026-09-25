import XCTest
@testable import ZynSign

/// Tests for the words the import experience uses.
///
/// The mapping is tested directly because it is the only place import
/// outcomes become sentences, so a mistake here is a mistake the user reads:
/// a successful import described as a failure, a cancellation described as an
/// error, a refusal described as a defect in ZynSign, or a package described
/// as something it has not been established to be.
@MainActor
final class ImportQueueRenderingTests: XCTestCase {

    // MARK: - Settlements

    func testAnOrdinaryImportSaysThePackageWasAdded() {
        let settlement = ImportSettlement(kind: .imported, relation: .unrelated)
        XCTAssertEqual(ImportQueueRendering.message(for: settlement), "Added to the library.")
    }

    func testAnImportBesideAnotherVersionNamesTheRelation() {
        let other = LibraryFixtures.record()
        let settlement = ImportSettlement(kind: .imported, relation: .otherVersions([other]))
        XCTAssertEqual(
            ImportQueueRendering.message(for: settlement),
            "Added to the library alongside one other version of this application."
        )
    }

    func testARebuiltPackageWithTheSameDeclaredVersionSaysBothAreKept() {
        let record = LibraryFixtures.record()
        let settlement = ImportSettlement(
            kind: .imported,
            relation: .sameDeclaredVersion([record])
        )
        let message = ImportQueueRendering.message(for: settlement)
        XCTAssertTrue(message.contains("both are kept"))
    }

    func testAnAlreadyHeldPackageSaysNothingWasAdded() {
        let record = LibraryFixtures.record()
        let settlement = ImportSettlement(kind: .alreadyHeld, record: record)
        let message = ImportQueueRendering.message(for: settlement)
        XCTAssertTrue(message.contains("already in ZynSign's library"))
        XCTAssertTrue(message.contains("not added again"))
    }

    func testAReplacementSaysWhatWasRemoved() {
        let record = LibraryFixtures.record()
        let report = DuplicateReport(
            candidateBundleIdentifier: record.bundleIdentifier,
            candidateMarketingVersion: "1.2",
            candidateBuildVersion: "34",
            candidateByteCount: 1_024,
            candidateFingerprint: LibraryFixtures.fingerprint(seed: 0x02),
            matches: [DuplicateMatch(record: record, kind: .sameVersionAndBuild, evidence: [])]
        )
        let settlement = ImportSettlement(
            kind: .replaced,
            record: LibraryFixtures.record(),
            replacedRecords: [record],
            duplicate: DuplicateOutcome(report: report, resolution: .replaceExisting)
        )
        XCTAssertEqual(
            ImportQueueRendering.message(for: settlement),
            "Added to the library and replaced the entry it matched."
        )
    }

    func testAReplacementThatCouldNotRemoveEverythingSaysSo() {
        let record = LibraryFixtures.record()
        let settlement = ImportSettlement(
            kind: .replaced,
            record: LibraryFixtures.record(),
            replacedRecords: [],
            retainedRecords: [record, LibraryFixtures.record()]
        )
        let message = ImportQueueRendering.message(for: settlement)
        XCTAssertTrue(message.contains("Two earlier entries could not be removed"))
    }

    func testARefusalAndAFailureUseTheirOwnExplanation() {
        let refusal = ImportFailure.from(validation: .invalid(findings: [
            ValidationFinding(severity: .error, code: .missingApplicationBundle, detail: "synthetic"),
        ]))
        XCTAssertEqual(
            ImportQueueRendering.message(for: ImportSettlement(kind: .rejected, failure: refusal)),
            "No application was found inside the package."
        )

        let failure = ImportFailure.from(error: ZynSignError.importCopyFailure(diagnosticDetail: "synthetic"))
        XCTAssertEqual(
            ImportQueueRendering.message(for: ImportSettlement(kind: .failed, failure: failure)),
            "ZynSign could not copy the selected package into its working storage."
        )
    }

    func testACancellationSaysNothingWasKeptAndTheFileWasNotChanged() {
        let message = ImportQueueRendering.message(for: ImportSettlement(kind: .cancelled))
        XCTAssertTrue(message.contains("Nothing was kept"))
        XCTAssertTrue(message.contains("was not changed"))
    }

    // MARK: - Summaries

    func testAnEmptySummarySaysThereIsNothingToReport() {
        XCTAssertEqual(ImportQueueRendering.headline(for: .empty), "No imports yet")
        XCTAssertEqual(ImportQueueRendering.detail(for: .empty), "Nothing was imported.")
    }

    func testASummaryCountsWhatHappenedInTheOrderAPersonReadsIt() {
        let summary = ImportSummary(
            settlements: [
                ImportSettlement(kind: .imported),
                ImportSettlement(kind: .imported),
                ImportSettlement(kind: .alreadyHeld),
                ImportSettlement(kind: .rejected),
            ],
            scheduledCount: 4,
            byteCount: 2_048
        )

        XCTAssertEqual(ImportQueueRendering.headline(for: summary), "Import finished — 4 packages")
        let detail = ImportQueueRendering.detail(for: summary)
        XCTAssertTrue(detail.hasPrefix("2 added to the library"))
        XCTAssertTrue(detail.contains("1 already held"))
        XCTAssertTrue(detail.contains("1 refused"))
    }

    func testAnUnfinishedSummaryReportsHowManyHaveFinished() {
        let summary = ImportSummary(
            settlements: [ImportSettlement(kind: .imported)],
            scheduledCount: 3,
            byteCount: 0
        )
        XCTAssertEqual(ImportQueueRendering.headline(for: summary), "Importing 1 of 3 packages")
        XCTAssertFalse(summary.isComplete)
    }

    func testOneScheduledPackageReadsAsASingleImport() {
        XCTAssertEqual(
            ImportQueueRendering.headline(for: ImportSummary(
                settlements: [],
                scheduledCount: 1,
                byteCount: 0
            )),
            "Importing one package"
        )
    }

    // MARK: - The picker

    func testClosingAPickerIsRecognisedAsACancellation() {
        struct PickerFailure: Error {}
        let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertTrue(ImportQueueRendering.isCancellation(CancellationError()))
        XCTAssertTrue(ImportQueueRendering.isCancellation(ZynSignError.importCancelled(diagnosticDetail: nil)))
        XCTAssertTrue(ImportQueueRendering.isCancellation(cancelled))
        XCTAssertFalse(ImportQueueRendering.isCancellation(PickerFailure()))
        XCTAssertFalse(ImportQueueRendering.isCancellation(ZynSignError.selectedFileAccessDenied(diagnosticDetail: nil)))
    }

    func testAPickerThatCouldNotVendAFileIsExplainedWithoutForeignText() {
        struct ForeignFailure: LocalizedError {
            var errorDescription: String? { "/Users/someone/private/path.ipa" }
        }
        let message = ImportQueueRendering.pickerFailureMessage(for: ForeignFailure())
        XCTAssertEqual(message, "The picker could not provide the selected file.")
        XCTAssertFalse(message.contains("private/path"))
    }
}
