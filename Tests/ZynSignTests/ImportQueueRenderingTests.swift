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

    // MARK: - Import Hub vocabulary

    func testASkipSaysNothingWasAdded() {
        XCTAssertEqual(
            ImportQueueRendering.message(for: .skipped()),
            "Skipped. Nothing was added, and the file you chose was not changed."
        )
    }

    func testTheSummaryCountsTheFourBuckets() {
        let summary = ImportSummary(
            settlements: [
                ImportSettlement(kind: .imported),
                ImportSettlement(kind: .keptBoth),
                ImportSettlement(kind: .replaced),
                ImportSettlement(kind: .alreadyHeld),
                ImportSettlement(kind: .cancelled),
                .skipped(),
                ImportSettlement(kind: .rejected),
                ImportSettlement(kind: .failed),
            ],
            scheduledCount: 8,
            byteCount: 0
        )
        XCTAssertEqual(summary.count(of: .imported), 2)
        XCTAssertEqual(summary.count(of: .replaced), 1)
        XCTAssertEqual(summary.count(of: .skipped), 3)
        XCTAssertEqual(summary.count(of: .failed), 2)
        XCTAssertTrue(ImportQueueRendering.detail(for: summary).contains("1 skipped"))
    }

    func testRemainingWorkIsPhrasedAsAnEstimate() {
        XCTAssertEqual(
            ImportQueueRendering.remainingText(for: ImportRemainingEstimate(remainingSteps: 3, remainingBytes: 1_000, remainingSeconds: 12.2)),
            "About 13 s left · 3 steps left"
        )
        XCTAssertEqual(
            ImportQueueRendering.remainingText(for: ImportRemainingEstimate(remainingSteps: 1, remainingBytes: nil, remainingSeconds: nil)),
            "1 step left"
        )
        XCTAssertNil(ImportQueueRendering.remainingText(for: ImportRemainingEstimate(remainingSteps: 0, remainingBytes: nil, remainingSeconds: nil)))
        XCTAssertEqual(ImportQueueRendering.duration(59), "About 59 s left")
        XCTAssertEqual(ImportQueueRendering.duration(61), "About 2 min left")
        XCTAssertEqual(ImportQueueRendering.duration(0.2), "About 1 s left")
    }

    func testVersionsReadAsVersionAndBuild() {
        XCTAssertEqual(ImportQueueRendering.versionText(LibraryFixtures.identity(shortVersion: "1.3", build: "45")), "1.3 (45)")
        XCTAssertEqual(ImportQueueRendering.versionText(LibraryFixtures.identity(shortVersion: nil, build: nil)), "\u{2014}")
    }

    func testConflictHeadlinesCompareExistingWithIncoming() throws {
        let existing = LibraryFixtures.record(identity: LibraryFixtures.identity(shortVersion: "1.2", build: "34"))
        let incoming = LibraryFixtures.identity(shortVersion: "1.3", build: "40")
        let report = DuplicateDetection.report(
            identity: incoming,
            reference: LibraryFixtures.reference(fingerprintSeed: 0x01),
            against: [existing]
        )
        let conflict = try XCTUnwrap(ImportRules.conflict(for: report, incoming: incoming))

        XCTAssertEqual(ImportQueueRendering.headline(for: conflict), "Newer than library (1.2 (34) → 1.3 (40))")
        XCTAssertTrue(ImportQueueRendering.suggestionExplanation(for: conflict).contains("newer"))
        XCTAssertEqual(ImportQueueRendering.replacementScope(for: conflict), "Replacing removes 1 existing entry after the new one is stored.")
    }

    func testArchiveOffersSayTheArchiveIsNotChanged() {
        let one = [ImportHubFixtures.candidate("App.ipa")]
        let many = [ImportHubFixtures.candidate("A.ipa"), ImportHubFixtures.candidate("B.ipa")]
        XCTAssertTrue(ImportQueueRendering.archiveOffer(for: one).contains("one app package"))
        XCTAssertTrue(ImportQueueRendering.archiveOffer(for: many).contains("2 app packages"))
        XCTAssertTrue(ImportQueueRendering.archiveOffer(for: many).contains("not changed"))
    }

    func testAFinishedBatchIsAnnouncedInBucketOrder() {
        let entry = ImportHistoryEntry(
            id: ImportBatchIdentifier(),
            startedAt: LibraryFixtures.importDate,
            finishedAt: LibraryFixtures.laterDate,
            origin: .documentPicker,
            items: [
                ImportHistoryEntry.Item(id: UUID(), fileName: "A.ipa", outcome: .imported),
                ImportHistoryEntry.Item(id: UUID(), fileName: "B.ipa", outcome: .failed),
                ImportHistoryEntry.Item(id: UUID(), fileName: "C.ipa", outcome: .keptBoth),
            ]
        )
        XCTAssertEqual(ImportQueueRendering.announcement(for: entry), "Import finished: 2 imported, 1 failed.")
        XCTAssertEqual(ImportQueueRendering.counts(for: entry), "2 imported · 1 failed")
        XCTAssertEqual(ImportQueueRendering.title(for: entry), "3 files · Files")
    }

    func testTheBackgroundPromiseStaysWithinWhatTheSystemAllows() {
        let text = ImportQueueRendering.backgroundExplanation
        XCTAssertTrue(text.contains("while ZynSign is open"))
        XCTAssertTrue(text.contains("short time"))
        XCTAssertFalse(text.lowercased().contains("in the background until"))
    }
}
