import XCTest
@testable import ZynSign

/// Tests for the ledger: the journal is the only record, so the ledger's job is
/// to decide which runs still describe something real, and to say nothing it
/// cannot read.
final class SideloadLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        id: String = UUID().uuidString,
        sourceRecord: String? = "record-A",
        bundleIdentifier: String? = "com.example.synthetic",
        displayName: String? = "Example",
        outcome: SigningRecord.Outcome = .succeeded,
        startedAt: Date? = nil,
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil,
        profileName: String? = nil,
        outputFileName: String? = "Example_signed.ipa"
    ) -> SigningRecord {
        SigningRecord(
            id: SigningRecordIdentifier(rawValue: id),
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: bundleIdentifier,
            sourceDisplayName: displayName,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: outputFileName,
            outputByteCount: nil,
            startedAt: startedAt ?? now.addingTimeInterval(-86_400),
            duration: 1,
            result: outcome,
            sourceRecordIdentifier: sourceRecord,
            provisioningProfileName: profileName,
            profileExpiresAt: profileExpiresAt,
            certificateExpiresAt: certificateExpiresAt
        )
    }

    // MARK: - What becomes a lease

    func testOnlyADeliveredRunMakesALease() {
        let records = [
            record(id: "1", sourceRecord: "A", outcome: .failed),
            record(id: "2", sourceRecord: "B", outcome: .cancelled),
            record(id: "3", sourceRecord: "C", outcome: .succeeded),
        ]
        let leases = SideloadLedger.leases(from: records)
        XCTAssertEqual(leases.count, 1)
        XCTAssertEqual(leases.first?.libraryRecordIdentifier, "C")
    }

    func testTheSameApplicationSignedFiveTimesMakesOneLease() {
        let records = (0..<5).map { index in
            record(
                id: "run-\(index)",
                sourceRecord: "A",
                startedAt: now.addingTimeInterval(TimeInterval(-index) * 3_600)
            )
        }
        XCTAssertEqual(SideloadLedger.leases(from: records).count, 1)
    }

    func testTheNewestRunDecidesTheExpiry() throws {
        let older = record(
            id: "older", sourceRecord: "A",
            startedAt: now.addingTimeInterval(-10 * 86_400),
            profileExpiresAt: now.addingTimeInterval(-3 * 86_400)
        )
        let newer = record(
            id: "newer", sourceRecord: "A",
            startedAt: now.addingTimeInterval(-86_400),
            profileExpiresAt: now.addingTimeInterval(6 * 86_400)
        )
        // Deliberately out of order: the journal's own ordering is not trusted.
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [newer, older]).first)
        XCTAssertEqual(lease.profileExpiresAt, now.addingTimeInterval(6 * 86_400))
        XCTAssertEqual(lease.status(at: now), .current)
    }

    func testAnOlderRunNeverWinsEvenWhenItIsListedLast() throws {
        let newer = record(id: "newer", sourceRecord: "A", startedAt: now.addingTimeInterval(-86_400))
        let older = record(id: "older", sourceRecord: "A", startedAt: now.addingTimeInterval(-9 * 86_400))
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [older, newer]).first)
        XCTAssertEqual(lease.id, SideloadLedger.applicationKey(for: newer))
    }

    func testTwoApplicationsMakeTwoLeasesOrderedByWhatEndsFirst() {
        let soon = record(id: "soon", sourceRecord: "A", profileExpiresAt: now.addingTimeInterval(86_400))
        let later = record(id: "later", sourceRecord: "B", profileExpiresAt: now.addingTimeInterval(30 * 86_400))
        let leases = SideloadLedger.leases(from: [later, soon])
        XCTAssertEqual(leases.map(\.libraryRecordIdentifier), ["A", "B"])
    }

    func testALeaseWithNoExpirySortsAfterOneThatHasADate() {
        let dated = record(id: "dated", sourceRecord: "A", profileExpiresAt: now.addingTimeInterval(86_400))
        let undated = record(id: "undated", sourceRecord: "B")
        let leases = SideloadLedger.leases(from: [undated, dated])
        XCTAssertEqual(leases.map(\.libraryRecordIdentifier), ["A", "B"])
        XCTAssertEqual(leases.last?.status(at: now), .unrecorded)
    }

    // MARK: - Same application, same key

    func testTheKeyPrefersTheLibraryRecordThenTheBundleThenTheArtifact() {
        XCTAssertEqual(SideloadLedger.applicationKey(for: record(sourceRecord: "A")), "record:A")

        let noRecord = record(sourceRecord: nil, bundleIdentifier: "com.example.x", outputFileName: "x.ipa")
        XCTAssertEqual(SideloadLedger.applicationKey(for: noRecord), "bundle:com.example.x")

        let noBundle = record(sourceRecord: nil, bundleIdentifier: nil, outputFileName: "x.ipa")
        XCTAssertEqual(SideloadLedger.applicationKey(for: noBundle), "artifact:x.ipa")
    }

    func testARunThatNamesNothingIsStillKeyedByItself() {
        let bare = record(sourceRecord: nil, bundleIdentifier: nil, outputFileName: nil)
        XCTAssertEqual(SideloadLedger.applicationKey(for: bare), "run:\(bare.id.rawValue)")
        XCTAssertEqual(SideloadLedger.leases(from: [bare]).count, 1)
    }

    func testAResignedCopyOfTheSameBundleKeepsOneLeaseEvenWithNoLibraryRecord() {
        let first = record(id: "1", sourceRecord: nil, bundleIdentifier: "com.example.x", startedAt: now.addingTimeInterval(-5 * 86_400))
        let second = record(id: "2", sourceRecord: nil, bundleIdentifier: "com.example.x", startedAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(SideloadLedger.leases(from: [first, second]).count, 1)
    }

    // MARK: - The lease's own facts

    func testTheLeaseKeepsWhatTheRunRecorded() throws {
        let run = record(
            sourceRecord: "A",
            displayName: "Example App",
            profileExpiresAt: now.addingTimeInterval(7 * 86_400),
            certificateExpiresAt: now.addingTimeInterval(90 * 86_400),
            profileName: "Example Profile",
            outputFileName: "Example_signed.ipa"
        )
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run]).first)
        XCTAssertEqual(lease.displayName, "Example App")
        XCTAssertEqual(lease.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(lease.profileName, "Example Profile")
        XCTAssertEqual(lease.outputFileName, "Example_signed.ipa")
        XCTAssertEqual(lease.signedAt, run.startedAt)
        XCTAssertEqual(lease.ending, .profile)
    }

    func testAnOlderRunWithNoBundleIdentifierIsNamedFromItsArtifact() throws {
        let run = record(sourceRecord: nil, bundleIdentifier: nil, displayName: nil, outputFileName: "Mystery_signed.ipa")
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run]).first)
        XCTAssertEqual(lease.displayName, "Unknown Application")
        XCTAssertEqual(lease.bundleIdentifier, "Mystery_signed.ipa")
    }

    func testNoBundleIdentifierAndNoArtifactSaysSoRatherThanShowingAFilename() throws {
        let run = record(sourceRecord: nil, bundleIdentifier: nil, outputFileName: nil)
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run]).first)
        XCTAssertEqual(lease.bundleIdentifier, "Unknown bundle")
    }

    // MARK: - The account, read from the profile library

    func testTheAccountIsReadFromTheStoredProfile() throws {
        let run = record(profileExpiresAt: now.addingTimeInterval(365 * 86_400), profileName: "Example Profile")
        let profile = IdentityCenterFixtures.summary(for: IdentityCenterFixtures.profileFacts(
            name: "Example Profile",
            profileType: .enterprise
        ))
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run], profiles: [profile]).first)
        XCTAssertEqual(lease.account, .enterpriseProgram)
        XCTAssertEqual(lease.refreshLeadDays, SideloadAccount.enterpriseProgram.refreshLeadDays)
    }

    func testAProfileThatIsNoLongerStoredIsSettledByItsLifetime() throws {
        let run = record(profileExpiresAt: now.addingTimeInterval(7 * 86_400), profileName: "Gone Profile")
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run], profiles: []).first)
        XCTAssertEqual(lease.account, .personalTeam)
        XCTAssertEqual(lease.profileName, "Gone Profile")
        XCTAssertEqual(lease.refreshLeadDays, SideloadAccount.personalTeam.refreshLeadDays)
    }

    func testARunWithNoProfileEstablishesNoAccount() throws {
        let run = record(profileExpiresAt: nil, profileName: nil)
        let lease = try XCTUnwrap(SideloadLedger.leases(from: [run]).first)
        XCTAssertNil(lease.account)
        XCTAssertEqual(lease.refreshLeadDays, SideloadLease.defaultRefreshLeadDays)
    }

    // MARK: - Usage

    func testExpiredLeasesDoNotOccupyAnAccountsSlots() {
        let live = record(id: "live", sourceRecord: "A", profileExpiresAt: now.addingTimeInterval(3 * 86_400))
        let dead = record(id: "dead", sourceRecord: "B", profileExpiresAt: now.addingTimeInterval(-3 * 86_400))
        let leases = SideloadLedger.leases(from: [live, dead])
        let usage = SideloadLedger.usage(leases, at: now)
        let personal = usage.first { $0.account == .personalTeam }
        XCTAssertEqual(personal?.installed, 1)
    }

    func testEveryAccountAppearsInTheUsageSoAnUnusedLimitIsVisible() {
        let usage = SideloadLedger.usage([], at: now)
        XCTAssertEqual(usage.map(\.account), SideloadAccount.allCases)
        XCTAssertTrue(usage.allSatisfy { $0.installed == 0 })
    }

    func testAFreeAccountHoldingFourLiveAppsIsReportedOverItsLimit() {
        let records = (0..<4).map { index in
            record(id: "run-\(index)", sourceRecord: "record-\(index)", profileExpiresAt: now.addingTimeInterval(4 * 86_400))
        }
        let usage = SideloadLedger.usage(SideloadLedger.leases(from: records), at: now)
        let personal = usage.first { $0.account == .personalTeam }
        XCTAssertEqual(personal?.installed, 4)
        XCTAssertEqual(personal?.isOverLimit, true)
    }

    func testTheAccountsInUseAreListedInCatalogueOrder() throws {
        // One free build settled by its week-long lifetime, and one read from
        // the stored ad hoc profile that signed it.
        let free = record(
            id: "a", sourceRecord: "A",
            profileExpiresAt: now.addingTimeInterval(7 * 86_400)
        )
        let paid = record(
            id: "b", sourceRecord: "B",
            profileExpiresAt: now.addingTimeInterval(365 * 86_400),
            profileName: "Ad Hoc Profile"
        )
        let profile = IdentityCenterFixtures.summary(for: IdentityCenterFixtures.profileFacts(
            name: "Ad Hoc Profile",
            profileType: .adHoc
        ))
        let leases = SideloadLedger.leases(from: [paid, free], profiles: [profile])
        XCTAssertEqual(try XCTUnwrap(leases.first { $0.libraryRecordIdentifier == "B" }).account, .developerProgram)
        XCTAssertEqual(SideloadLedger.accountsInUse(leases), [.personalTeam, .developerProgram])
    }

    func testNoLeasesMeansNoAccountsInUse() {
        XCTAssertTrue(SideloadLedger.accountsInUse([]).isEmpty)
    }
}
