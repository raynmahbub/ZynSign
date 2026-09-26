import XCTest
@testable import ZynSign

/// Tests for how the signing journal becomes per-entry signing facts: which
/// entry a signing belongs to, which signing counts, and how close the
/// assets a signing used are to expiring.
final class LibrarySigningFactsTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures
    private let now = LibraryOrganizationFixtures.now

    func testASigningNamingARecordBelongsToThatRecordAlone() {
        let signed = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", version: "1.0").record
        let newerCopy = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", version: "1.1").record
        let facts = LibrarySigningFacts(journal: [Fixtures.signing(of: signed, at: now)])

        XCTAssertEqual(facts.fact(for: signed)?.lastSignedAt, now)
        XCTAssertNil(facts.fact(for: newerCopy), "A newer import is not signed because an older copy was.")
    }

    func testALegacySigningBelongsOnlyToRecordsThatExistedWhenItRan() {
        let before = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", importedAt: now.addingTimeInterval(-3_600)).record
        let after = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app", importedAt: now.addingTimeInterval(3_600)).record
        let facts = LibrarySigningFacts(journal: [Fixtures.legacySigning(bundleIdentifier: "com.example.app", at: now)])

        XCTAssertNotNil(facts.fact(for: before))
        XCTAssertNil(facts.fact(for: after))
    }

    func testOnlySuccessfulSigningsCountAndTheLatestWins() {
        let record = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app").record
        let earlier = now.addingTimeInterval(-7_200)
        let facts = LibrarySigningFacts(journal: [
            Fixtures.signing(of: record, at: earlier, profileExpiresAt: now.addingTimeInterval(86_400)),
            Fixtures.signing(of: record, at: now, profileExpiresAt: now.addingTimeInterval(9 * 86_400)),
            Fixtures.failedSigning(of: record, at: now.addingTimeInterval(60)),
        ])

        let fact = facts.fact(for: record)
        XCTAssertEqual(fact?.lastSignedAt, now)
        XCTAssertEqual(fact?.profileExpiresAt, now.addingTimeInterval(9 * 86_400))
    }

    func testAJournalOfFailuresSignsNothing() {
        let record = Fixtures.entry(name: "App", bundleIdentifier: "com.example.app").record
        let facts = LibrarySigningFacts(journal: [Fixtures.failedSigning(of: record, at: now)])

        XCTAssertTrue(facts.isEmpty)
        XCTAssertNil(facts.fact(for: record))
    }

    func testTheEarlierOfProfileAndCertificateExpiryDecides() {
        let fact = LibrarySigningFact(
            lastSignedAt: now,
            profileExpiresAt: now.addingTimeInterval(20 * 86_400),
            certificateExpiresAt: now.addingTimeInterval(3 * 86_400)
        )

        XCTAssertEqual(fact.earliestExpiry, now.addingTimeInterval(3 * 86_400))
    }

    func testExpiryStatusAtTheWindowBoundaries() {
        func status(expiringIn interval: TimeInterval?) -> LibraryExpiryStatus {
            let fact = LibrarySigningFact(
                lastSignedAt: now,
                profileExpiresAt: interval.map { now.addingTimeInterval($0) },
                certificateExpiresAt: nil
            )
            return LibraryExpiryStatus.evaluate(fact, now: now)
        }

        XCTAssertEqual(status(expiringIn: nil), .unknown)
        XCTAssertEqual(status(expiringIn: 0), .expired(on: now))
        XCTAssertEqual(status(expiringIn: 30 * 86_400), .expiringSoon(on: now.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(status(expiringIn: 30 * 86_400 + 1), .valid(until: now.addingTimeInterval(30 * 86_400 + 1)))
        XCTAssertEqual(LibraryExpiryStatus.evaluate(nil, now: now), .unknown)
        XCTAssertTrue(status(expiringIn: -1).needsAttention)
        XCTAssertFalse(status(expiringIn: 31 * 86_400).needsAttention)
    }

    func testJournalRecordsWithoutTheNewFieldsStillDecode() throws {
        // A journal written before the library named its entries carries no
        // record identifier and no expiry dates; it must still decode.
        let legacy = #"""
        {"id":{"rawValue":"A"},"sourceBundleIdentifier":"com.example.app","stoppingStage":"verification","outputFileName":"App.ipa","outputByteCount":10,"startedAt":0,"duration":1}
        """#

        let record = try JSONDecoder().decode(SigningRecord.self, from: Data(legacy.utf8))

        XCTAssertNil(record.sourceRecordID)
        XCTAssertNil(record.profileExpiresAt)
        XCTAssertNil(record.certificateExpiresAt)
        XCTAssertEqual(record.outcome, .succeeded)
    }
}
