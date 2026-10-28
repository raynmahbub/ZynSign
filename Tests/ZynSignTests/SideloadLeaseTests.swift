import XCTest
@testable import ZynSign

/// Tests for the lease: the one rule that matters is that a build stops
/// launching when *either* its profile or its certificate ends, and that the
/// studio says which one it was.
final class SideloadLeaseTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var signedAt: Date { now.addingTimeInterval(-3 * 86_400) }

    private func lease(
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil,
        account: SideloadAccount? = .personalTeam,
        refreshLeadDays: Int? = nil
    ) -> SideloadLease {
        SideloadLease(
            id: "record:example",
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            libraryRecordIdentifier: "example",
            signedAt: signedAt,
            profileExpiresAt: profileExpiresAt,
            certificateExpiresAt: certificateExpiresAt,
            account: account,
            refreshLeadDays: refreshLeadDays
        )
    }

    // MARK: - Which date ends the lease

    func testTheEarlierOfTheTwoDatesEndsTheLease() {
        let profile = now.addingTimeInterval(4 * 86_400)
        let certificate = now.addingTimeInterval(40 * 86_400)
        let certificateFirst = lease(profileExpiresAt: certificate, certificateExpiresAt: profile)
        XCTAssertEqual(certificateFirst.expiresAt, profile)
        XCTAssertEqual(certificateFirst.ending, .certificate)

        let profileFirst = lease(profileExpiresAt: profile, certificateExpiresAt: certificate)
        XCTAssertEqual(profileFirst.expiresAt, profile)
        XCTAssertEqual(profileFirst.ending, .profile)
    }

    func testATieIsReadAsTheProfileEnding() {
        // A profile and a certificate that expire together were issued
        // together; naming the profile is the truthful reading.
        let sameMoment = now.addingTimeInterval(86_400)
        let tied = lease(profileExpiresAt: sameMoment, certificateExpiresAt: sameMoment)
        XCTAssertEqual(tied.ending, .profile)
    }

    func testOneKnownDateIsEnoughToEndTheLease() {
        let onlyProfile = lease(profileExpiresAt: now.addingTimeInterval(86_400))
        XCTAssertEqual(onlyProfile.ending, .profile)
        let onlyCertificate = lease(certificateExpiresAt: now.addingTimeInterval(86_400))
        XCTAssertEqual(onlyCertificate.ending, .certificate)
    }

    func testNoRecordedDateEstablishesNoExpiry() {
        let bare = lease()
        XCTAssertNil(bare.expiresAt)
        XCTAssertNil(bare.ending)
        XCTAssertNil(bare.daysRemaining(at: now))
        XCTAssertNil(bare.remainingFraction(at: now))
        XCTAssertEqual(bare.status(at: now), .unrecorded)
    }

    // MARK: - Days remaining

    func testDaysRemainingRoundDownToWhatThePersonActuallyHas() {
        // Twelve hours is not a day: the row must never promise one.
        let almost = lease(profileExpiresAt: now.addingTimeInterval(12 * 3_600))
        XCTAssertEqual(almost.daysRemaining(at: now), 0)
    }

    func testDaysRemainingAreZeroOnceTheExpiryHasPassed() {
        let past = lease(profileExpiresAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(past.daysRemaining(at: now), 0)
    }

    func testDaysRemainingCountWholeDaysToTheSecond() {
        let threeDays = lease(profileExpiresAt: now.addingTimeInterval(3 * 86_400 + 60))
        XCTAssertEqual(threeDays.daysRemaining(at: now), 3)
    }

    // MARK: - The ring

    func testTheRingIsFullAtSigningTimeAndEmptyAtExpiry() {
        let fresh = SideloadLease(
            id: "record:fresh",
            displayName: "Fresh",
            bundleIdentifier: "com.example.fresh",
            signedAt: now,
            profileExpiresAt: now.addingTimeInterval(7 * 86_400),
            account: .personalTeam
        )
        XCTAssertEqual(fresh.remainingFraction(at: now) ?? -1, 1, accuracy: 0.0001)

        let expiring = SideloadLease(
            id: "record:expiring",
            displayName: "Expiring",
            bundleIdentifier: "com.example.expiring",
            signedAt: now.addingTimeInterval(-7 * 86_400),
            profileExpiresAt: now,
            account: .personalTeam
        )
        XCTAssertEqual(expiring.remainingFraction(at: now) ?? -1, 0, accuracy: 0.0001)
    }

    func testTheRingStopsAtEmptyRatherThanGoingNegative() {
        let overrun = lease(profileExpiresAt: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(overrun.remainingFraction(at: now), 0)
    }

    func testTheRingIsHalfFullHalfwayThrough() {
        let halfway = SideloadLease(
            id: "record:half",
            displayName: "Half",
            bundleIdentifier: "com.example.half",
            signedAt: now.addingTimeInterval(-3.5 * 86_400),
            profileExpiresAt: now.addingTimeInterval(3.5 * 86_400),
            account: .personalTeam
        )
        XCTAssertEqual(halfway.remainingFraction(at: now) ?? -1, 0.5, accuracy: 0.0001)
    }

    // MARK: - Status

    func testTheStatusChangesExactlyOnTheLeadBoundary() {
        let lead = SideloadAccount.personalTeam.refreshLeadDays
        let onBoundary = lease(profileExpiresAt: now.addingTimeInterval(TimeInterval(lead) * 86_400))
        XCTAssertEqual(onBoundary.status(at: now), .refreshDue)

        let outside = lease(profileExpiresAt: now.addingTimeInterval(TimeInterval(lead) * 86_400 + 60))
        XCTAssertEqual(outside.status(at: now), .current)
    }

    func testAnExpiryInThePastIsExpiredNotDue() {
        let expired = lease(profileExpiresAt: now.addingTimeInterval(-60))
        XCTAssertEqual(expired.status(at: now), .expired)
        XCTAssertTrue(expired.status(at: now).isActionable)
    }

    func testTheLeaseIsExpiredAtTheExactInstantOfExpiry() {
        let onTheDot = lease(profileExpiresAt: now)
        XCTAssertEqual(onTheDot.status(at: now), .expired)
    }

    func testOnlyADueOrExpiredLeaseIsActionable() {
        XCTAssertTrue(SideloadLeaseStatus.refreshDue.isActionable)
        XCTAssertTrue(SideloadLeaseStatus.expired.isActionable)
        XCTAssertFalse(SideloadLeaseStatus.current.isActionable)
        XCTAssertFalse(SideloadLeaseStatus.unrecorded.isActionable)
    }

    func testEveryStatusHasAWordAndATone() {
        let statuses: [SideloadLeaseStatus] = [.current, .refreshDue, .expired, .unrecorded]
        XCTAssertEqual(
            statuses.map(\.title),
            ["Current", "Re-sign", "Expired", "No expiry"]
        )
        XCTAssertEqual(
            statuses.map(\.tone),
            [.success, .warning, .error, .neutral]
        )
    }

    // MARK: - The lead

    func testTheLeadComesFromTheAccountWhenOneIsKnown() {
        XCTAssertEqual(lease(account: .personalTeam).refreshLeadDays, 2)
        XCTAssertEqual(lease(account: .developerProgram).refreshLeadDays, 21)
        XCTAssertEqual(lease(account: .enterpriseProgram).refreshLeadDays, 45)
        XCTAssertEqual(lease(account: .adHoc).refreshLeadDays, 0)
    }

    func testAnUnknownAccountGetsTheNeutralLead() {
        let unknown = lease(account: nil, refreshLeadDays: nil)
        XCTAssertEqual(unknown.refreshLeadDays, SideloadLease.defaultRefreshLeadDays)
        XCTAssertEqual(SideloadLease.defaultRefreshLeadDays, 3)
    }

    func testAStatedLeadWinsOverTheAccountDefault() {
        let stated = lease(account: .developerProgram, refreshLeadDays: 1)
        XCTAssertEqual(stated.refreshLeadDays, 1)
    }

    func testANegativeLeadIsClampedToNone() {
        let negative = lease(refreshLeadDays: -5)
        XCTAssertEqual(negative.refreshLeadDays, 0)
    }

    func testTheNeutralLeadWarnsBeforeAFreeProfileExpiresButNotAfterIt() {
        // Three days is later than a personal team's two: a lease signed under
        // an unidentified account is not called due for the whole week.
        let fourDaysLeft = lease(profileExpiresAt: now.addingTimeInterval(4 * 86_400), account: nil)
        XCTAssertEqual(fourDaysLeft.status(at: now), .current)
        let twoDaysLeft = lease(profileExpiresAt: now.addingTimeInterval(2 * 86_400), account: nil)
        XCTAssertEqual(twoDaysLeft.status(at: now), .refreshDue)
    }

    // MARK: - Usage

    func testAFreeAccountCountsItsLiveAppsAgainstThree() {
        let usage = SideloadAccountUsage(account: .personalTeam, installed: 2)
        XCTAssertEqual(usage.limit, 3)
        XCTAssertFalse(usage.isOverLimit)
        XCTAssertEqual(usage.remaining, 1)
        XCTAssertEqual(usage.summary, "2 of 3 installed")
    }

    func testAFreeAccountOverThreeSaysSo() {
        let usage = SideloadAccountUsage(account: .personalTeam, installed: 4)
        XCTAssertTrue(usage.isOverLimit)
        XCTAssertEqual(usage.remaining, 0)
        XCTAssertEqual(usage.summary, "4 of 3 installed · over the limit")
    }

    func testAnAccountWithNoLimitNeverReportsOne() {
        let usage = SideloadAccountUsage(account: .developerProgram, installed: 40)
        XCTAssertNil(usage.limit)
        XCTAssertFalse(usage.isOverLimit)
        XCTAssertNil(usage.remaining)
        XCTAssertEqual(usage.summary, "40 installed · no app limit")
    }

    // MARK: - The plan

    private func mixedLeases() -> (due: SideloadLease, expired: SideloadLease, healthy: SideloadLease, unrecorded: SideloadLease) {
        let expired = lease(profileExpiresAt: now.addingTimeInterval(-2 * 86_400))
        let due = lease(profileExpiresAt: now.addingTimeInterval(86_400))
        let healthy = SideloadLease(
            id: "record:healthy",
            displayName: "Healthy",
            bundleIdentifier: "com.example.healthy",
            signedAt: now.addingTimeInterval(-86_400),
            profileExpiresAt: now.addingTimeInterval(6 * 86_400),
            account: .personalTeam
        )
        let unrecorded = SideloadLease(
            id: "record:unrecorded",
            displayName: "Unrecorded",
            bundleIdentifier: "com.example.unrecorded",
            signedAt: now,
            account: nil
        )
        return (due, expired, healthy, unrecorded)
    }

    func testThePlanIsAPartitionAndEveryLeaseAppearsExactlyOnce() {
        let leases = mixedLeases()
        let all = [leases.due, leases.expired, leases.healthy, leases.unrecorded]
        let plan = SideloadRefreshPlan.plan(all, at: now)

        XCTAssertEqual(plan.due.count + plan.healthy.count + plan.unrecorded.count, all.count)
        XCTAssertEqual(Set(plan.due.map(\.id)).count, plan.due.count)
        XCTAssertTrue(plan.due.contains { $0.id == leases.expired.id })
        XCTAssertTrue(plan.due.contains { $0.id == leases.due.id })
        XCTAssertEqual(plan.healthy.map(\.id), [leases.healthy.id])
        XCTAssertEqual(plan.unrecorded.map(\.id), [leases.unrecorded.id])
    }

    func testTheQueuePutsTheBuildThatStoppedFirstAtTheTop() {
        let leases = mixedLeases()
        let plan = SideloadRefreshPlan.plan([leases.healthy, leases.due, leases.expired], at: now)
        XCTAssertEqual(plan.due.map(\.id), [leases.expired.id, leases.due.id])
    }

    func testThePlanCountsOnlyTheDueAndExpired() {
        let leases = mixedLeases()
        let plan = SideloadRefreshPlan.plan([leases.due, leases.expired, leases.healthy, leases.unrecorded], at: now)
        XCTAssertEqual(plan.dueCount, 2)
        XCTAssertFalse(plan.isClear)
        XCTAssertEqual(plan.expiredCount(at: now), 1)
        XCTAssertFalse(plan.isEmpty)
    }

    func testAHealthyJournalIsClear() {
        let plan = SideloadRefreshPlan.plan([mixedLeases().healthy], at: now)
        XCTAssertTrue(plan.isClear)
        XCTAssertEqual(plan.dueCount, 0)
        XCTAssertEqual(plan.expiredCount(at: now), 0)
        XCTAssertFalse(plan.isEmpty)
    }

    func testAnEmptyJournalIsEmptyRatherThanClearAndFull() {
        let plan = SideloadRefreshPlan.plan([], at: now)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.isClear)
        XCTAssertNil(plan.nearestExpiry)
        XCTAssertEqual(plan, SideloadRefreshPlan.empty)
    }

    func testTheNearestExpiryLooksPastTheQueue() {
        let leases = mixedLeases()
        let plan = SideloadRefreshPlan.plan([leases.healthy, leases.unrecorded], at: now)
        XCTAssertEqual(plan.nearestExpiry, leases.healthy.expiresAt)
    }

    func testExpiredCountIsAskedWithADateRatherThanReadFromTheClock() {
        let leases = mixedLeases()
        let plan = SideloadRefreshPlan.plan([leases.due, leases.expired], at: now)
        XCTAssertEqual(plan.expiredCount(at: now), 1)
        // A week later the due lease has expired too, without the plan changing.
        XCTAssertEqual(plan.expiredCount(at: now.addingTimeInterval(7 * 86_400)), 2)
    }

    func testLeasesWithNoExpirySortByNameSoTheListIsStable() {
        let alpha = SideloadLease(
            id: "record:alpha", displayName: "Alpha", bundleIdentifier: "com.example.alpha",
            signedAt: now
        )
        let beta = SideloadLease(
            id: "record:beta", displayName: "Beta", bundleIdentifier: "com.example.beta",
            signedAt: now
        )
        let plan = SideloadRefreshPlan.plan([beta, alpha], at: now)
        XCTAssertEqual(plan.unrecorded.map(\.id), [alpha.id, beta.id])
    }
}
