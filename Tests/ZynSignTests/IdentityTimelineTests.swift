import XCTest
@testable import ZynSign

/// Tests for the Identity Timeline: the events built from each source,
/// the generated expiration observations, the cap, and the day grouping.
final class IdentityTimelineTests: XCTestCase {

    private let builder = IdentityTimelineBuilder()
    private let referenceDate = IdentityCenterFixtures.referenceDate

    /// A UTC calendar, so day grouping cannot depend on the test host's
    /// local timezone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testBuildsEventsFromEverySource() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 1),
            displayName: "Imported Certificate",
            importedAt: TestClocks.utc(2026, 9, 24, hour: 10)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Added Profile",
            importedAt: TestClocks.utc(2026, 9, 25, hour: 11)
        )
        let history = [
            IdentityHistoryFact(
                certificateFingerprintHex: certificate.fingerprintHex,
                bundleIdentifier: "com.example.app",
                applicationName: "MyApp",
                teamIdentifier: "TEAMABC123",
                succeeded: true,
                startedAt: TestClocks.utc(2026, 9, 20, hour: 9)
            ),
            IdentityHistoryFact(
                certificateFingerprintHex: certificate.fingerprintHex,
                bundleIdentifier: "com.example.other",
                applicationName: nil,
                teamIdentifier: "TEAMABC123",
                succeeded: false,
                startedAt: TestClocks.utc(2026, 9, 19, hour: 9)
            ),
        ]

        let events = builder.events(
            certificates: [certificate],
            profiles: [profile],
            history: history,
            forecast: [],
            referenceDate: referenceDate
        )

        XCTAssertTrue(events.contains { $0.kind == .certificateImported && $0.detail == "Imported Certificate" })
        XCTAssertTrue(events.contains { $0.kind == .profileAdded && $0.detail == "Added Profile" })
        XCTAssertTrue(events.contains { $0.kind == .applicationSigned && $0.title == "Signed MyApp" })
        XCTAssertTrue(events.contains { $0.kind == .signingFailed && $0.significance == .warning })
        // Most recent first.
        XCTAssertEqual(events.first?.date, TestClocks.utc(2026, 9, 25, hour: 11))
    }

    func testGeneratesExpirationObservationsForUrgentEntriesOnly() {
        let expiringCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 2),
            displayName: "Expiring Certificate",
            notValidAfter: referenceDate.addingTimeInterval(5 * 86_400)
        )
        let calmCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 3),
            displayName: "Calm Certificate"
        )
        let forecast = ExpirationForecastBuilder().build(
            certificates: [expiringCertificate, calmCertificate],
            profiles: [],
            referenceDate: referenceDate
        )

        let events = builder.events(
            certificates: [expiringCertificate, calmCertificate],
            profiles: [],
            history: [],
            forecast: forecast,
            referenceDate: referenceDate
        )

        let observations = events.filter { $0.kind == .expiringSoon }
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.significance, .warning)
        XCTAssertTrue(observations.first?.title.contains("Certificate") == true)
    }

    func testTimelineIsCapped() {
        let history = (0..<200).map { index in
            IdentityHistoryFact(
                certificateFingerprintHex: nil,
                bundleIdentifier: "com.example.\(index)",
                applicationName: nil,
                teamIdentifier: nil,
                succeeded: true,
                startedAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index))
            )
        }

        let events = builder.events(
            certificates: [],
            profiles: [],
            history: history,
            forecast: [],
            referenceDate: referenceDate
        )

        XCTAssertEqual(events.count, IdentityTimelineBuilder.maximumEvents)
    }

    func testGroupsByDayWithRelativeTitles() {
        // The reference instant is 2026-10-01T00:00Z, so in UTC an hour
        // after it is still "today" and one hour into 09-30 is
        // "yesterday".
        let today = referenceDate.addingTimeInterval(3_600)
        let yesterday = referenceDate.addingTimeInterval(-86_400 + 3_600)
        let earlier = TestClocks.utc(2026, 9, 18, hour: 8)
        let events = [
            IdentityTimelineEvent(date: today, kind: .certificateImported, title: "Today Event", significance: .positive),
            IdentityTimelineEvent(date: yesterday, kind: .profileAdded, title: "Yesterday Event", significance: .positive),
            IdentityTimelineEvent(date: earlier, kind: .applicationSigned, title: "Earlier Event", significance: .positive),
        ]

        let days = builder.groupedByDay(events, referenceDate: referenceDate, calendar: utcCalendar)

        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].title, "Today")
        XCTAssertEqual(days[0].events.first?.title, "Today Event")
        XCTAssertEqual(days[1].title, "Yesterday")
        XCTAssertEqual(days[2].title, "Sep 18")
    }

    func testEventsWithinOneDaySortNewestFirst() {
        let morning = TestClocks.utc(2026, 10, 1, hour: 8)
        let evening = TestClocks.utc(2026, 10, 1, hour: 20)
        let days = builder.groupedByDay(
            [
                IdentityTimelineEvent(date: morning, kind: .certificateImported, title: "Morning", significance: .positive),
                IdentityTimelineEvent(date: evening, kind: .profileAdded, title: "Evening", significance: .positive),
            ],
            referenceDate: referenceDate,
            calendar: utcCalendar
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].events.map(\.title), ["Evening", "Morning"])
    }

    func testEventsWithoutImportDatesProduceNoImportEvents() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 5),
            importedAt: nil
        )
        let profile = IdentityCenterFixtures.profileFacts(name: "No Import", importedAt: nil)

        let events = builder.events(
            certificates: [certificate],
            profiles: [profile],
            history: [],
            forecast: [],
            referenceDate: referenceDate
        )

        XCTAssertFalse(events.contains { $0.kind == .certificateImported })
        XCTAssertFalse(events.contains { $0.kind == .profileAdded })
    }
}
