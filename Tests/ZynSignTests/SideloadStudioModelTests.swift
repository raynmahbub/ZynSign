import XCTest
@testable import ZynSign

/// Tests for the studio model: what it reads, what it refuses to invent, and
/// what it says when one of the stores fails.
///
/// The model owns no records. Every expectation below is about the reading it
/// takes of the stores — so the tests build small stores, not a screen.
@MainActor
final class SideloadStudioModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var libraryRecords: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var journal: InMemorySigningHistoryStore!
    private var identities: InMemorySigningIdentityStore!
    private var profiles: StudioProfileLibrary!

    override func setUp() {
        super.setUp()
        libraryRecords = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: libraryRecords, artifacts: artifacts)
        journal = InMemorySigningHistoryStore()
        identities = InMemorySigningIdentityStore()
        profiles = StudioProfileLibrary()
    }

    override func tearDown() {
        profiles = nil
        identities = nil
        journal = nil
        library = nil
        artifacts = nil
        libraryRecords = nil
        super.tearDown()
    }

    // MARK: - Building the model

    private func makeModel(
        history: (any SigningHistoryStore)? = nil,
        profileLibrary: ProvisioningProfileLibrary? = nil
    ) -> SideloadStudioModel {
        SideloadStudioModel(
            identityStore: identities,
            signingHistory: history,
            provisioningProfiles: profileLibrary,
            library: library,
            now: { self.now }
        )
    }

    private func record(
        id: String = UUID().uuidString,
        sourceRecord: String? = "record-A",
        bundleIdentifier: String? = "com.example.synthetic",
        displayName: String? = "Example",
        outcome: SigningRecord.Outcome = .succeeded,
        startedAt: Date? = nil,
        profileExpiresAt: Date? = nil,
        profileName: String? = nil
    ) -> SigningRecord {
        SigningRecord(
            id: SigningRecordIdentifier(rawValue: id),
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: bundleIdentifier,
            sourceDisplayName: displayName,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: "Example_signed.ipa",
            outputByteCount: 1_024,
            startedAt: startedAt ?? now.addingTimeInterval(-86_400),
            duration: 1,
            result: outcome,
            sourceRecordIdentifier: sourceRecord,
            provisioningProfileName: profileName,
            profileExpiresAt: profileExpiresAt
        )
    }

    // MARK: - Reading

    func testABuildWithNoJournalSaysSoRatherThanShowingAnEmptyLedger() async {
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.leases.isEmpty)
        XCTAssertTrue(model.plan.isEmpty)
        XCTAssertEqual(model.headlineCountdown, "Nothing signed yet")
        XCTAssertEqual(
            model.readNotice,
            "This build has no signing journal, so nothing is tracked for refresh."
        )
    }

    func testAJournalThatCannotBeReadIsNamedRatherThanThrown() async {
        await journal.failReads(with: StudioReadFailure.unavailable)
        let model = makeModel(history: journal)
        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(
            model.readNotice,
            "The signing history could not be read, so no lease is shown."
        )
    }

    func testAFailedRunLeavesNothingToRefresh() async {
        journal = InMemorySigningHistoryStore(records: [record(outcome: .failed)])
        let model = makeModel(history: journal)
        await model.load()

        XCTAssertTrue(model.leases.isEmpty)
        XCTAssertNil(model.readNotice)
    }

    func testADeliveredRunBecomesALeaseWithACountdown() async throws {
        let expires = now.addingTimeInterval(6 * 86_400)
        journal = InMemorySigningHistoryStore(records: [record(profileExpiresAt: expires)])
        let model = makeModel(history: journal)
        await model.load()

        let lease = try XCTUnwrap(model.leases.first)
        XCTAssertEqual(lease.displayName, "Example")
        XCTAssertEqual(model.headlineCountdown, "6 days left")
        XCTAssertEqual(model.plan.healthy.count, 1)
        XCTAssertTrue(model.plan.isClear)
        XCTAssertEqual(model.activeAccount, .personalTeam)
        XCTAssertEqual(model.activeUsage?.installed, 1)
    }

    func testAnExpiredBuildLeadsWithTheExpiredWord() async {
        journal = InMemorySigningHistoryStore(records: [
            record(profileExpiresAt: now.addingTimeInterval(-2 * 86_400)),
        ])
        let model = makeModel(history: journal)
        await model.load()

        XCTAssertEqual(model.headlineCountdown, "Expired")
        XCTAssertEqual(model.plan.due.count, 1)
        XCTAssertEqual(model.plan.expiredCount(at: now), 1)
    }

    func testReadingTwiceDoesNotDuplicateTheLedger() async {
        journal = InMemorySigningHistoryStore(records: [
            record(profileExpiresAt: now.addingTimeInterval(6 * 86_400)),
        ])
        let model = makeModel(history: journal)
        await model.load()
        await model.load()

        XCTAssertEqual(model.leases.count, 1)
    }

    func testTheReadInstantIsRememberedSoTheScreenCanSayHowOldItIs() async {
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.lastReadAt, now)
    }

    // MARK: - Accounts

    func testEveryAccountIsListedSoAnUnusedLimitIsVisible() async {
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.usage.map(\.account), SideloadAccount.allCases)
        XCTAssertNil(model.overLimitAccounts.first)
        XCTAssertNil(model.activeAccount)
    }

    // MARK: - Materials

    func testWithoutACertificateTheStudioCannotSignAgain() async throws {
        let model = makeModel()
        await model.load()

        XCTAssertFalse(model.canSignAgain)
        let lease = SideloadLease(
            id: "record:record-A",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            libraryRecordIdentifier: "record-A",
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            model.refreshBlockedReason(for: lease),
            "The application is no longer in the library. Import it again, then sign it."
        )
    }

    func testALeaseWithNoLibraryRecordSaysThereIsNothingToSignAgain() async {
        let model = makeModel()
        await model.load()

        let lease = SideloadLease(
            id: "artifact:Example_signed.ipa",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            model.refreshBlockedReason(for: lease),
            "This run recorded no library application, so there is nothing to sign again. Import the package to re-create it."
        )
    }

    func testALeaseTheLibraryStillHoldsOffersACertificateWhenItHasNone() async throws {
        let recordID = ApplicationRecordIdentifier()
        library = ApplicationLibrary(
            records: InMemoryApplicationRecordStore(records: [LibraryFixtures.record(id: recordID)]),
            artifacts: artifacts
        )
        let model = makeModel()
        await model.load()

        let lease = SideloadLease(
            id: "record:\(recordID.rawValue)",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            libraryRecordIdentifier: recordID.rawValue,
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            model.refreshBlockedReason(for: lease),
            "No certificate is imported. Add one in Certificates & Profiles first."
        )
    }

    func testAUsableCertificateAndAProfileMakeTheStudioAbleToSignAgain() async throws {
        let recordID = ApplicationRecordIdentifier()
        library = ApplicationLibrary(
            records: InMemoryApplicationRecordStore(records: [LibraryFixtures.record(id: recordID)]),
            artifacts: artifacts
        )
        let metadata = IdentityCenterFixtures.metadata(for: CertificateFixtures.validDER)
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            association: .matched,
            capabilityState: .ready
        )
        identities.entries[identity.id] = InMemorySigningIdentityStore.IdentityEntry(
            identity: identity,
            capability: RecordingSigningCapability()
        )
        try await profiles.upsert(IdentityCenterFixtures.summary(for: IdentityCenterFixtures.profileFacts()))

        let model = makeModel(profileLibrary: profiles)
        await model.load()

        // No journal in this environment: nothing is tracked for refresh, and
        // the materials are still read and reported.
        XCTAssertEqual(
            model.readNotice,
            "This build has no signing journal, so nothing is tracked for refresh."
        )
        XCTAssertTrue(model.canSignAgain)
        XCTAssertEqual(model.usableIdentities.count, 1)
        XCTAssertEqual(model.profiles.count, 1)

        let lease = SideloadLease(
            id: "record:\(recordID.rawValue)",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            libraryRecordIdentifier: recordID.rawValue,
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(86_400)
        )
        XCTAssertNil(model.refreshBlockedReason(for: lease))
        XCTAssertNotNil(model.libraryEntry(for: lease))
    }

    func testACertificateThatCannotSignIsNamedAsTheBlocker() async throws {
        let recordID = ApplicationRecordIdentifier()
        library = ApplicationLibrary(
            records: InMemoryApplicationRecordStore(records: [LibraryFixtures.record(id: recordID)]),
            artifacts: artifacts
        )
        let identity = SigningIdentity(
            certificate: IdentityCenterFixtures.metadata(for: CertificateFixtures.validDER),
            keyAvailability: .unavailable
        )
        identities.entries[identity.id] = InMemorySigningIdentityStore.IdentityEntry(
            identity: identity,
            capability: RecordingSigningCapability()
        )

        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.identities.count, 1)
        XCTAssertTrue(model.usableIdentities.isEmpty)
        let lease = SideloadLease(
            id: "record:\(recordID.rawValue)",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            libraryRecordIdentifier: recordID.rawValue,
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            model.refreshBlockedReason(for: lease),
            "The imported certificate cannot sign: its private key is unavailable or not associated with it."
        )
    }

    // MARK: - Formatting

    func testADateIsWrittenWithTheYearOnlyWhenItIsNotThisYear() throws {
        // The instant is fixed; the day it falls on is the reader's time zone,
        // so the assertion is the format the studio chose, not the day.
        let moment = Date(timeIntervalSince1970: 1_772_000_000)
        let thisYear = SideloadStudioModel.formatted(moment, now: moment.addingTimeInterval(86_400))
        let laterYear = SideloadStudioModel.formatted(moment, now: moment.addingTimeInterval(400 * 86_400))

        XCTAssertNotNil(
            try NSRegularExpression(pattern: "^[0-9]{1,2} [A-Z][a-z]{2}$")
                .firstMatch(in: thisYear, range: NSRange(thisYear.startIndex..., in: thisYear)),
            "Expected a day and month, got \(thisYear)"
        )
        XCTAssertNotNil(
            try NSRegularExpression(pattern: "^[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}$")
                .firstMatch(in: laterYear, range: NSRange(laterYear.startIndex..., in: laterYear)),
            "Expected a day, month and year, got \(laterYear)"
        )
    }

    func testAnUnrecordedDateSaysSoRatherThanShowingToday() {
        XCTAssertEqual(SideloadStudioModel.formatted(nil, now: now), "an unrecorded date")
    }
}

/// The failure a store double reports, so a read failure is the test's own
/// value rather than a production error chosen for its name.
private enum StudioReadFailure: Error {
    case unavailable
}

/// A profile library the studio tests can fill: summaries only, which is all
/// the studio reads.
private actor StudioProfileLibrary: ProvisioningProfileLibrary {

    private var stored: [ProvisioningProfileIdentifier: ProvisioningProfileSummary] = [:]

    func allProfiles() async throws -> [ProvisioningProfileSummary] {
        stored.values.sorted { $0.expirationDate < $1.expirationDate }
    }

    func profile(withID id: ProvisioningProfileIdentifier) async throws -> ProvisioningProfileSummary? {
        stored[id]
    }

    func upsert(_ summary: ProvisioningProfileSummary) async throws {
        stored[summary.id] = summary
    }

    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws {
        stored[id] = nil
    }

    func count() async throws -> Int {
        stored.count
    }
}
