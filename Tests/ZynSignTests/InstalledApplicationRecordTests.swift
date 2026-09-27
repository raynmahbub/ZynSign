import XCTest
@testable import ZynSign

/// Tests for the installed-application record: event appending with the
/// per-record cap, the update state's comparisons, and the pending
/// attempt's shape.
final class InstalledApplicationRecordTests: XCTestCase {

    // MARK: - Appending

    func testAppendingAnEventRefreshesUpdatedAtAndKeepsIdentity() {
        let record = InstallationFixtures.installedRecord(exportedAt: InstallationFixtures.lastWeek)
        let event = InstalledApplicationEvent(
            kind: .updated,
            at: InstallationFixtures.now,
            shortVersion: "1.3",
            buildVersion: "40",
            exportIdentifier: "new-export",
            exportFileName: "Example_2_signed.ipa",
            signingRecordIdentifier: nil,
            verificationStatus: .valid,
            channel: .otaLink
        )

        let updated = record.appending(event, libraryRecordIdentifier: "lib-1", now: InstallationFixtures.now)

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.bundleIdentifier, record.bundleIdentifier)
        XCTAssertEqual(updated.events.count, 2)
        XCTAssertEqual(updated.updatedAt, InstallationFixtures.now)
        XCTAssertEqual(updated.recordedAt, record.recordedAt)
        XCTAssertEqual(updated.libraryRecordIdentifier, "lib-1")
        XCTAssertEqual(updated.latestEvent?.kind, .updated)
        XCTAssertEqual(updated.installedVersionDisplay, "1.3 (40)")
    }

    func testAppendingBeyondTheCapTrimsTheOldestEvents() {
        var record = InstallationFixtures.installedRecord(exportedAt: InstallationFixtures.lastMonth)
        for index in 0..<InstalledApplicationRecord.maximumEventsPerRecord {
            let event = InstalledApplicationEvent(
                kind: .updated,
                at: record.recordedAt.addingTimeInterval(TimeInterval(index + 1) * 60),
                shortVersion: "1.\(index)",
                buildVersion: "\(index)",
                exportIdentifier: nil,
                exportFileName: nil,
                signingRecordIdentifier: nil,
                verificationStatus: nil,
                channel: .hostTool
            )
            record = record.appending(event, libraryRecordIdentifier: nil, now: event.at)
        }
        let fullCount = record.events.count

        let extra = InstalledApplicationEvent(
            kind: .reinstalled,
            at: InstallationFixtures.now,
            shortVersion: "2.0",
            buildVersion: "99",
            exportIdentifier: nil,
            exportFileName: nil,
            signingRecordIdentifier: nil,
            verificationStatus: nil,
            channel: .hostTool
        )
        let trimmed = record.appending(extra, libraryRecordIdentifier: nil, now: InstallationFixtures.now)

        XCTAssertEqual(fullCount, InstalledApplicationRecord.maximumEventsPerRecord)
        XCTAssertEqual(trimmed.events.count, InstalledApplicationRecord.maximumEventsPerRecord)
        XCTAssertEqual(trimmed.events.last?.kind, .reinstalled)
        XCTAssertNotEqual(trimmed.events.first, record.events.first, "The oldest event was trimmed.")
    }

    // MARK: - Derived facts

    func testLatestEventFactsComeFromTheNewestEvent() {
        let record = InstallationFixtures.installedRecord(
            displayName: "Example",
            exportIdentifier: "export-1",
            exportedAt: InstallationFixtures.lastWeek,
            channel: .managedDistribution
        )

        XCTAssertEqual(record.latestEvent?.kind, .installed)
        XCTAssertEqual(record.installedVersionDisplay, "1.2 (34)")
        XCTAssertEqual(record.installedChannel, .managedDistribution)
        XCTAssertEqual(record.installedVerificationStatus, .valid)
        XCTAssertEqual(record.displayOrIdentifier, "Example")
    }

    // MARK: - Update state

    func testNewestHeldExportWithSameIdentifierIsUpToDate() {
        let identifier = ExportIdentifier()
        let record = InstallationFixtures.installedRecord(exportIdentifier: identifier.rawValue)
        let newest = InstallationFixtures.exportRecord(id: identifier)

        XCTAssertEqual(
            InstallationUpdateState.evaluate(installed: record, newestExport: newest),
            .upToDate
        )
    }

    func testNewerDeclaredVersionOffersAnUpdate() {
        let record = InstallationFixtures.installedRecord(
            shortVersion: "1.2",
            buildVersion: "34",
            exportIdentifier: "old-export"
        )
        let newest = InstallationFixtures.exportRecord(
            id: ExportIdentifier(),
            shortVersion: "1.10",
            buildVersion: "40"
        )

        guard case .updateAvailable(let candidate) = InstallationUpdateState.evaluate(installed: record, newestExport: newest) else {
            return XCTFail("Expected an update offer, got \(InstallationUpdateState.evaluate(installed: record, newestExport: newest))")
        }
        XCTAssertEqual(candidate.versionDisplay, "1.10 (40)")
        XCTAssertTrue(candidate.exportIdentifier != "old-export")
    }

    func testOlderOrEqualExportIsUnknownNotAnUpdate() {
        let record = InstallationFixtures.installedRecord(
            shortVersion: "2.0",
            buildVersion: "40",
            exportIdentifier: "old-export"
        )
        let older = InstallationFixtures.exportRecord(shortVersion: "1.2", buildVersion: "34")
        XCTAssertEqual(
            InstallationUpdateState.evaluate(installed: record, newestExport: older),
            .unknown
        )

        let equal = InstallationFixtures.exportRecord(shortVersion: "2.0", buildVersion: "40")
        XCTAssertEqual(
            InstallationUpdateState.evaluate(installed: record, newestExport: equal),
            .unknown,
            "An equal version under a different export is a re-sign, not an update."
        )
    }

    func testIncomparableVersionsAndMissingExportsMakeNoClaim() {
        let record = InstallationFixtures.installedRecord(shortVersion: nil, buildVersion: nil)
        let newest = InstallationFixtures.exportRecord(shortVersion: "1.2", buildVersion: "34")
        XCTAssertEqual(
            InstallationUpdateState.evaluate(installed: record, newestExport: newest),
            .unknown
        )
        XCTAssertEqual(
            InstallationUpdateState.evaluate(installed: record, newestExport: nil),
            .unknown
        )
    }

    // MARK: - Attempts

    func testAttemptSummaryNamesTheAppAndState() {
        let attempt = InstallationFixtures.attempt(intent: .updated)
        XCTAssertTrue(attempt.summary.contains("Updated"))
        XCTAssertTrue(attempt.summary.contains("Example"))
        XCTAssertTrue(attempt.summary.contains("1.2 (34)"))
        XCTAssertTrue(attempt.summary.contains("awaiting your confirmation"))
    }

    // MARK: - History projection

    func testHistoryEntryCarriesEventAndRecordFacts() {
        let record = InstallationFixtures.installedRecord(
            displayName: "Example",
            exportIdentifier: "export-1"
        )
        let event = record.events[0]
        let entry = InstallationHistoryEntry(
            event: event,
            recordID: record.id,
            bundleIdentifier: record.bundleIdentifier,
            appName: record.displayOrIdentifier
        )

        XCTAssertEqual(entry.id, event.id)
        XCTAssertEqual(entry.title, "Example — Installed")
        XCTAssertTrue(entry.detail.contains("1.2 (34)"))
        XCTAssertTrue(entry.detail.contains("Over-the-Air Link"))
    }
}
