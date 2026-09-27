import XCTest
@testable import ZynSign

/// Tests for the workspace's fixed-language rendering: timestamps, badge
/// mappings, update labels, and the honesty lines. Every assertion here
/// pins wording the interface depends on.
final class InstallationPresentationTests: XCTestCase {

    private let calendar = Calendar.current

    // MARK: - Timestamps

    func testTodayRendersWithTheClockOnly() throws {
        let now = Date()
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 22, second: 0, of: now))

        let text = InstallationPresentation.timestamp(morning, relativeTo: now)

        XCTAssertTrue(text.hasPrefix("Today · "), "The dashboard's promise is “Today · 14:22”.")
        XCTAssertTrue(text.contains("14:22"))
    }

    func testYesterdayRendersAsYesterday() throws {
        let now = Date()
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let stamped = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 5, second: 0, of: yesterday))

        let text = InstallationPresentation.timestamp(stamped, relativeTo: now)

        XCTAssertTrue(text.hasPrefix("Yesterday · "), "Yesterday keeps the clock, matching the spec's example.")
    }

    func testOlderDatesRenderAsDates() throws {
        let now = Date()
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: now))

        let text = InstallationPresentation.timestamp(lastMonth, relativeTo: now)

        XCTAssertFalse(text.hasPrefix("Today"))
        XCTAssertFalse(text.hasPrefix("Yesterday"))
        XCTAssertTrue(text.contains(",") || text.contains(" ") , "A date-only localisation, never a clock.")
    }

    // MARK: - Readiness badges

    func testBadgeKindsFollowTheCheckStates() {
        XCTAssertEqual(InstallationPresentation.badgeKind(for: InstallationCheckState.passed), .success)
        XCTAssertEqual(
            InstallationPresentation.badgeKind(for: InstallationCheckState.attention(reason: "note")),
            .warning
        )
        XCTAssertEqual(
            InstallationPresentation.badgeKind(for: InstallationCheckState.blocked(reason: "why")),
            .error
        )
        XCTAssertEqual(
            InstallationPresentation.badgeKind(for: InstallationCheckState.notPerformed(reason: "no evidence")),
            .neutral
        )
    }

    func testReadinessTitlesDistinguishCleanNotesAndBlocked() {
        var evidence = InstallationFixtures.passingEvidence()
        let clean = InstallationReadinessReport.evaluate(evidence)
        XCTAssertEqual(InstallationPresentation.readinessTitle(for: clean), "Ready")

        evidence.shortVersion = nil
        let notes = InstallationReadinessReport.evaluate(evidence)
        XCTAssertEqual(InstallationPresentation.readinessTitle(for: notes), "Ready with notes")

        evidence.verificationStatus = nil
        let blocked = InstallationReadinessReport.evaluate(evidence)
        XCTAssertEqual(InstallationPresentation.readinessTitle(for: blocked), "Not ready")
    }

    // MARK: - Update labels

    func testUpdateLabelsMatchTheStates() {
        XCTAssertEqual(InstallationPresentation.updateLabel(for: .upToDate), "Up to date")
        XCTAssertEqual(
            InstallationPresentation.updateLabel(for: .unknown),
            "No newer signed output"
        )
        let candidate = InstallationUpdateCandidate(
            exportIdentifier: "e",
            exportFileName: "Example.ipa",
            shortVersion: "2.0",
            buildVersion: "10",
            verificationStatus: .valid
        )
        XCTAssertEqual(
            InstallationPresentation.updateLabel(for: .updateAvailable(candidate)),
            "Update available · 2.0 (10)"
        )
    }

    func testUpdateExplanationNeverClaimsTheDevice() {
        let candidate = InstallationUpdateCandidate(
            exportIdentifier: "e",
            exportFileName: "Example.ipa",
            shortVersion: "2.0",
            buildVersion: "10",
            verificationStatus: nil
        )
        let text = InstallationPresentation.updateExplanation(for: .updateAvailable(candidate))
        XCTAssertTrue(text.contains("Delivering it is your step"))
    }

    // MARK: - Honesty lines

    func testTheHistoryHonestyLineSaysWhatZynSignDidNotSee() {
        let line = InstallationPresentation.historyHonestyLine
        XCTAssertTrue(line.contains("your confirmation"))
        XCTAssertTrue(line.contains("did not observe"))
        XCTAssertTrue(line.contains("cannot see what the platform decided"))
    }

    func testChannelExplanationsNeverClaimObservation() {
        for channel in InstallationChannel.allCases {
            XCTAssertTrue(
                channel.explanation.contains("ZynSign"),
                "\(channel) names ZynSign's role so the record's source is never ambiguous."
            )
        }
    }

    // MARK: - Spoken forms

    func testDashboardAnnouncementReadsAllThreeCounts() {
        let spoken = InstallationPresentation.dashboardAnnouncement(
            readyToInstall: 2,
            installed: 5,
            updatesAvailable: 1
        )
        XCTAssertTrue(spoken.contains("2 ready to install"))
        XCTAssertTrue(spoken.contains("5 recorded as installed"))
        XCTAssertTrue(spoken.contains("1 with updates available"))
    }

    func testConfirmationAnnouncementUsesThePastForm() {
        let spoken = InstallationPresentation.confirmationAnnouncement(appName: "Example", kind: .reinstalled)
        XCTAssertEqual(spoken, "Example recorded as reinstalled.")
    }

    // MARK: - Spoken card summary

    func testInstalledRowSpokenSummaryIsOneSentence() {
        let record = InstallationFixtures.installedRecord(exportIdentifier: "export-1")
        let row = InstallationWorkspaceModel.InstalledRow(
            record: record,
            updateState: .upToDate,
            latestExportEntry: nil
        )
        let spoken = row.spokenSummary
        XCTAssertTrue(spoken.hasPrefix("Example, 1.2 (34)"))
        XCTAssertTrue(spoken.contains("installed"))
        XCTAssertTrue(spoken.contains("up to date"))
        XCTAssertTrue(spoken.hasSuffix("."))
    }
}
