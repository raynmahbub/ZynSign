import XCTest
@testable import ZynSign

/// The Sign screen's journal: the record one Signing Engine run leaves
/// behind, and the journal announcing its own changes so the library re-reads
/// it. Every value is synthetic; nothing here signs anything.
final class SigningJournalTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures

    private let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The run's record

    func testASignedRunIsRecordedAsASuccessNamingItsEntryAndItsOutput() {
        let entry = Fixtures.entry(name: "Synthetic", bundleIdentifier: "com.example.journal", version: "2.1", build: "40")
        let draft = SigningEngineJournalDraft(entry: entry, identity: nil, profile: Data(), startedAt: startedAt)
        let output = URL(fileURLWithPath: "/synthetic/Documents/Signed/Synthetic-run.ipa")

        let record = draft.record(
            result: Self.engineResult(status: .signed, outputURL: output, containerByteCount: 4_096),
            wasCancelled: false,
            finishedAt: startedAt.addingTimeInterval(12)
        )

        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(record.result, .succeeded)
        XCTAssertEqual(record.sourceRecordID, entry.record.id)
        XCTAssertEqual(record.sourceBundleIdentifier, "com.example.journal")
        XCTAssertEqual(record.sourceDisplayName, "Synthetic")
        XCTAssertEqual(record.shortVersion, "2.1")
        XCTAssertEqual(record.buildVersion, "40")
        XCTAssertEqual(record.outputFileName, "Synthetic-run.ipa")
        XCTAssertEqual(record.outputByteCount, 4_096)
        XCTAssertEqual(record.startedAt, startedAt)
        XCTAssertEqual(record.duration, 12, accuracy: 0.001)
        XCTAssertNil(record.stoppingStage)
        XCTAssertNil(record.errorCode)
    }

    func testARefusedRunRecordsTheStageAndCategoryAndNoOutput() {
        let draft = SigningEngineJournalDraft(entry: Fixtures.entry(name: "Synthetic"), identity: nil, profile: Data(), startedAt: startedAt)
        let failure = Self.engineFailure(stage: .signingApplication, category: .invalidInput)

        let record = draft.record(
            result: Self.engineResult(status: .failed, failure: failure),
            wasCancelled: false,
            finishedAt: startedAt
        )

        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.stoppingStage, SigningEngineStage.signingApplication.rawValue)
        XCTAssertEqual(record.errorCode, DiagnosticCategory.invalidInput.rawValue)
        XCTAssertNil(record.outputFileName)
        XCTAssertNil(record.outputByteCount)
    }

    func testAFailureTheEngineCategorisedAsACancellationIsRecordedAsCancelled() {
        let draft = SigningEngineJournalDraft(entry: Fixtures.entry(name: "Synthetic"), identity: nil, profile: Data(), startedAt: startedAt)
        let failure = Self.engineFailure(stage: .packaging, category: .cancelled)

        let record = draft.record(
            result: Self.engineResult(status: .failed, failure: failure),
            wasCancelled: false,
            finishedAt: startedAt
        )

        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(record.stoppingStage, SigningEngineStage.packaging.rawValue)
    }

    func testARunThatThrewIsCancelledOrFailedWithoutAnInventedStage() {
        let draft = SigningEngineJournalDraft(entry: Fixtures.entry(name: "Synthetic"), identity: nil, profile: Data(), startedAt: startedAt)

        let cancelled = draft.record(result: nil, wasCancelled: true, finishedAt: startedAt)
        let failed = draft.record(result: nil, wasCancelled: false, finishedAt: startedAt)

        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(failed.outcome, .failed)
        for record in [cancelled, failed] {
            XCTAssertNil(record.stoppingStage)
            XCTAssertNil(record.errorCode)
            XCTAssertNil(record.outputFileName)
        }
    }

    func testTheRecordNamesTheCertificateAndTheProfileTheRunSignedWith() {
        let metadata = ProvisioningPolicyFixtures.identityMetadata()
        let identity = SigningIdentity(
            id: metadata.id,
            certificate: metadata.certificate,
            keyAvailability: metadata.keyAvailability,
            association: metadata.association,
            capabilityState: metadata.capabilityState
        )
        let profileExpiry = startedAt.addingTimeInterval(20 * 86_400)
        let draft = SigningEngineJournalDraft(
            entry: Fixtures.entry(name: "Synthetic"),
            identity: identity,
            profile: Self.signedProfile(name: "Journal Profile", expiresAt: profileExpiry),
            startedAt: startedAt
        )

        let record = draft.record(result: nil, wasCancelled: true, finishedAt: startedAt)

        XCTAssertEqual(record.certificateFingerprint, metadata.certificate.sha256Fingerprint)
        XCTAssertEqual(record.certificateDisplayName, identity.displayName)
        XCTAssertEqual(record.certificateExpiresAt, metadata.certificate.notValidAfter)
        XCTAssertEqual(record.provisioningProfileName, "Journal Profile")
        XCTAssertEqual(record.profileExpiresAt, profileExpiry)
    }

    func testUnreadableProfileBytesAndNoIdentityLeaveThoseFieldsEmpty() {
        let draft = SigningEngineJournalDraft(
            entry: Fixtures.entry(name: "Synthetic"),
            identity: nil,
            profile: Data([0x30, 0x82, 0x00, 0x01, 0xFF]),
            startedAt: startedAt
        )

        XCTAssertNil(draft.provisioningProfileName)
        XCTAssertNil(draft.profileExpiresAt)
        XCTAssertNil(draft.certificateFingerprint)
        XCTAssertNil(draft.certificateDisplayName)
        XCTAssertNil(draft.certificateExpiresAt)
    }

    func testASignedRunMakesItsEntrySignedWithTheRecordedExpiry() {
        let entry = Fixtures.entry(name: "Synthetic", importedAt: startedAt.addingTimeInterval(-3_600))
        let profileExpiry = startedAt.addingTimeInterval(10 * 86_400)
        let draft = SigningEngineJournalDraft(
            entry: entry,
            identity: nil,
            profile: Self.signedProfile(name: "Journal Profile", expiresAt: profileExpiry),
            startedAt: startedAt
        )
        let record = draft.record(
            result: Self.engineResult(status: .signed, outputURL: URL(fileURLWithPath: "/synthetic/out.ipa")),
            wasCancelled: false,
            finishedAt: startedAt
        )

        let fact = LibrarySigningFacts(journal: [record]).fact(for: entry.record)

        XCTAssertEqual(fact?.lastSignedAt, startedAt)
        XCTAssertEqual(fact?.profileExpiresAt, profileExpiry)
        XCTAssertTrue(LibraryExpiryStatus.evaluate(fact, now: startedAt).needsAttention)
    }

    // MARK: - The notifying journal

    func testTheJournalAnnouncesEveryChangeItCompletes() async throws {
        let journal = NotifyingSigningHistoryStore(wrapping: InMemorySigningHistoryStore())
        let posts = observeJournalChanges()
        let record = Fixtures.signing(of: Fixtures.entry(name: "Synthetic").record, at: startedAt)

        try await journal.append(record)
        XCTAssertEqual(posts.value, 1)

        try await journal.remove(recordWithID: record.id)
        XCTAssertEqual(posts.value, 2)

        try await journal.clear()
        XCTAssertEqual(posts.value, 3)
    }

    func testReadsAndFailedChangesAnnounceNothingAndPassThrough() async throws {
        let existing = Fixtures.signing(of: Fixtures.entry(name: "Synthetic").record, at: startedAt)
        let base = InMemorySigningHistoryStore(records: [existing])
        let journal = NotifyingSigningHistoryStore(wrapping: base)
        let posts = observeJournalChanges()

        let records = try await journal.allRecords()
        let count = try await journal.count()
        XCTAssertEqual(records, [existing])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(journal.capacity, base.capacity)

        await base.failWrites(with: SyntheticJournalFailure())
        do {
            try await journal.append(Fixtures.signing(of: Fixtures.entry(name: "Other").record, at: startedAt))
            XCTFail("A failed append must throw.")
        } catch {
            XCTAssertTrue(error is SyntheticJournalFailure)
        }
        do {
            try await journal.clear()
            XCTFail("A failed clear must throw.")
        } catch {
            XCTAssertTrue(error is SyntheticJournalFailure)
        }

        XCTAssertEqual(posts.value, 0)
        let unchanged = try await journal.count()
        XCTAssertEqual(unchanged, 1)
    }

    // MARK: - Helpers

    /// Counts `signingHistoryDidChange` posts for the rest of the test. The
    /// observer runs synchronously on the posting thread, so a count read
    /// after an awaited change already includes it.
    private func observeJournalChanges() -> PostCounter {
        let counter = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .signingHistoryDidChange,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        addTeardownBlock {
            NotificationCenter.default.removeObserver(token)
        }
        return counter
    }

    /// Profile bytes shaped like a signed container — opaque bytes around a
    /// property list declaring a name and an expiry.
    private static func signedProfile(name: String, expiresAt: Date) -> Data {
        let declarations: [String: Any] = ["Name": name, "ExpirationDate": expiresAt]
        guard let body = try? PropertyListSerialization.data(fromPropertyList: declarations, format: .xml, options: 0) else {
            preconditionFailure("A literal dictionary must serialise as a property list.")
        }
        var bytes = Data([0x30, 0x82, 0x0F, 0xA0, 0x06, 0x09])
        bytes.append(body)
        bytes.append(Data([0xA0, 0x82, 0x01, 0x00, 0x31, 0x00]))
        return bytes
    }

    private static func engineResult(
        status: SigningEngineStatus,
        outputURL: URL? = nil,
        containerByteCount: Int = 2_048,
        failure: SigningEngineFailure? = nil
    ) -> SigningEngineResult {
        let summary: SigningEngineSummary? = status == .signed
            ? SigningEngineSummary(
                bundleName: "Synthetic",
                bundleIdentifier: "com.example.synthetic",
                executableName: "Synthetic",
                entryCount: 3,
                nestedTargetCount: 0,
                signedBinaryCount: 1,
                sealedResourceCount: 2,
                containerByteCount: containerByteCount,
                verificationCheckCount: 4,
                verificationPassedCount: 4,
                duration: 1
            )
            : nil
        return SigningEngineResult(
            status: status,
            outputURL: outputURL,
            stages: [],
            summary: summary,
            failure: failure,
            expectations: nil,
            verification: nil,
            containerVerification: nil,
            workingCopy: nil,
            progress: SigningEngineProgress(
                records: [],
                currentStage: nil,
                detail: "",
                fractionCompleted: 1,
                elapsed: 1,
                estimatedRemaining: nil
            )
        )
    }

    private static func engineFailure(stage: SigningEngineStage, category: DiagnosticCategory) -> SigningEngineFailure {
        SigningEngineFailure(
            stage: stage,
            detail: "Synthetic refusal.",
            category: category,
            userMessage: "Synthetic refusal.",
            originalUnchanged: true,
            workingCopyDiscarded: true,
            outputRemoved: true,
            diagnostics: []
        )
    }
}

private struct SyntheticJournalFailure: Error {}

/// A thread-safe count of observed posts.
private final class PostCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
