import XCTest
@testable import ZynSign

/// Tests for the account catalogue: the limits a sideloading tool plans with,
/// and — more importantly — the rules for reading an account off a signing run
/// without guessing.
final class SideloadAccountTests: XCTestCase {

    // MARK: - The catalogue

    func testTheCatalogueHoldsEveryKindOfAccountZynSignCanSignWith() {
        XCTAssertEqual(
            Set(SideloadAccount.allCases),
            [.personalTeam, .developerProgram, .enterpriseProgram, .adHoc]
        )
        XCTAssertEqual(SideloadAccount.allCases.count, 4)
    }

    func testEveryAccountIsDescribed() {
        for account in SideloadAccount.allCases {
            XCTAssertFalse(account.displayName.isEmpty, "\(account) has no display name")
            XCTAssertFalse(account.shortLabel.isEmpty, "\(account) has no chip label")
            XCTAssertFalse(account.summary.isEmpty, "\(account) has no summary")
            XCTAssertFalse(account.limitRows.isEmpty, "\(account) publishes no rows")
        }
    }

    func testAFreePersonalTeamIssuesASevenDayProfile() {
        XCTAssertEqual(SideloadAccount.personalTeam.profileLifetimeDays, 7)
        XCTAssertEqual(SideloadAccount.personalTeam.refreshLeadDays, 2)
        XCTAssertEqual(SideloadAccount.personalTeam.concurrentAppLimit, 3)
        XCTAssertEqual(SideloadAccount.personalTeam.weeklyAppIdentifierLimit, 10)
        XCTAssertEqual(SideloadAccount.personalTeam.weeklyDeviceLimit, 3)
        XCTAssertTrue(SideloadAccount.personalTeam.requiresWeeklyRefresh)
        XCTAssertTrue(SideloadAccount.personalTeam.requiresDeviceRegistration)
    }

    func testAPaidMembershipIssuesAYearLongProfile() {
        XCTAssertEqual(SideloadAccount.developerProgram.profileLifetimeDays, 365)
        XCTAssertEqual(SideloadAccount.enterpriseProgram.profileLifetimeDays, 365)
        XCTAssertNil(SideloadAccount.developerProgram.concurrentAppLimit)
        XCTAssertEqual(SideloadAccount.developerProgram.registeredDeviceLimit, 100)
        XCTAssertFalse(SideloadAccount.developerProgram.requiresWeeklyRefresh)
    }

    func testAnInHouseProfileListsNoDevicesAndNeedsNoRegistration() {
        XCTAssertFalse(SideloadAccount.enterpriseProgram.requiresDeviceRegistration)
        XCTAssertNil(SideloadAccount.enterpriseProgram.registeredDeviceLimit)
        XCTAssertEqual(SideloadAccount.enterpriseProgram.refreshLeadDays, 45)
    }

    func testAnAdHocSignatureHasNoProfileAndNothingExpires() {
        XCTAssertNil(SideloadAccount.adHoc.profileLifetimeDays)
        XCTAssertEqual(SideloadAccount.adHoc.refreshLeadDays, 0)
        XCTAssertFalse(SideloadAccount.adHoc.requiresWeeklyRefresh)
    }

    func testTheRefreshLeadIsAlwaysShorterThanTheLifetimeItWarnsAbout() {
        for account in SideloadAccount.allCases {
            guard let lifetime = account.profileLifetimeDays else { continue }
            XCTAssertLessThan(
                account.refreshLeadDays, lifetime,
                "\(account) would be due the moment it was signed"
            )
        }
    }

    func testOnlyAFreePersonalTeamRefusesPlatformServices() {
        let refused = Set(SideloadAccount.personalTeam.uncarriedCapabilities)
        XCTAssertTrue(refused.contains("Push Notifications"))
        XCTAssertTrue(refused.contains("iCloud"))
        XCTAssertTrue(refused.contains("App Groups"))
        for account in [SideloadAccount.developerProgram, .enterpriseProgram, .adHoc] {
            XCTAssertTrue(account.uncarriedCapabilities.isEmpty, "\(account) refuses a service")
        }
    }

    func testTheRowTextSaysWhichLimitItIsTalkingAbout() {
        let titles = SideloadAccount.personalTeam.limitRows.map(\.title)
        XCTAssertEqual(
            titles,
            ["Profile lifetime", "Re-sign before", "Installed at once", "New App IDs", "New devices"]
        )
        XCTAssertEqual(SideloadAccount.personalTeam.limitRows.first?.value, "7 days")
        XCTAssertEqual(SideloadAccount.adHoc.limitRows.first?.value, "Every install")
    }

    // MARK: - Reading an account off a profile

    func testADistributionProfileNamesItsOwnAccount() {
        XCTAssertEqual(SideloadAccount.account(for: .adHoc), .developerProgram)
        XCTAssertEqual(SideloadAccount.account(for: .appStore), .developerProgram)
        XCTAssertEqual(SideloadAccount.account(for: .enterprise), .enterpriseProgram)
    }

    func testADevelopmentProfileDoesNotSayWhichMembershipIssuedIt() {
        XCTAssertNil(SideloadAccount.account(for: .development))
        XCTAssertNil(SideloadAccount.account(for: .unknown))
        XCTAssertNil(SideloadAccount.account(for: nil))
    }

    func testASevenDayLifetimeIsReadAsAPersonalTeam() {
        XCTAssertEqual(SideloadAccount.account(forProfileLifetimeDays: 7), .personalTeam)
        XCTAssertEqual(SideloadAccount.account(forProfileLifetimeDays: 6), .personalTeam)
    }

    func testAWeekOfSlackIsTheCeilingForAPersonalTeamLifetime() {
        // The ceiling exists for a device clock or a time-zone boundary, not for
        // a longer membership: nine days is not a free personal team.
        XCTAssertEqual(SideloadAccount.shortLifetimeCeilingDays, 8)
        XCTAssertEqual(SideloadAccount.account(forProfileLifetimeDays: 8), .personalTeam)
        XCTAssertNil(SideloadAccount.account(forProfileLifetimeDays: 9))
    }

    func testAOneYearLifetimeDoesNotSayWhichPaidMembershipItWas() {
        XCTAssertNil(SideloadAccount.account(forProfileLifetimeDays: 365))
    }

    func testAnUnknownLifetimeEstablishesNothing() {
        XCTAssertNil(SideloadAccount.account(forProfileLifetimeDays: nil))
    }

    // MARK: - Reading an account off a run

    func testTheProfileClassificationWinsOverTheLifetime() throws {
        let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let account = SideloadAccount.infer(
            profileType: .enterprise,
            profileExpiresAt: signedAt.addingTimeInterval(7 * 86_400),
            signedAt: signedAt
        )
        XCTAssertEqual(account, .enterpriseProgram)
    }

    func testADevelopmentProfileIsSettledByItsSevenDayLifetime() throws {
        let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let account = SideloadAccount.infer(
            profileType: .development,
            profileExpiresAt: signedAt.addingTimeInterval(7 * 86_400),
            signedAt: signedAt
        )
        XCTAssertEqual(account, .personalTeam)
    }

    func testADevelopmentProfileWithAYearToRunIsLeftUnestablished() throws {
        let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let account = SideloadAccount.infer(
            profileType: .development,
            profileExpiresAt: signedAt.addingTimeInterval(365 * 86_400),
            signedAt: signedAt
        )
        XCTAssertNil(account)
    }

    func testARunWithNothingKnownEstablishesNoAccount() {
        XCTAssertNil(SideloadAccount.infer(profileType: nil, profileExpiresAt: nil, signedAt: Date()))
    }

    func testTheInferenceRoundsATimeZoneBoundaryBackToAWeek() throws {
        let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
        // Seven days and eight hours: what a signed date in a time zone behind
        // the profile's own can look like.
        let account = SideloadAccount.infer(
            profileType: nil,
            profileExpiresAt: signedAt.addingTimeInterval(7.33 * 86_400),
            signedAt: signedAt
        )
        XCTAssertEqual(account, .personalTeam)
    }
}
