import XCTest
@testable import ZynSign

/// Tests for the refresh reminders: which leases earn one, when it fires, and
/// what it is allowed to say.
///
/// A reminder is the only part of the studio that speaks when nobody is looking
/// at the screen, so the rules are pinned here rather than trusted: work that is
/// already due is not reminded (the queue shows it), the cap holds, the text
/// names dates and never a device, and the identifier is stable so a second read
/// replaces a reminder instead of doubling it.
@MainActor
final class SideloadRefreshReminderTests: XCTestCase {

    /// 2026-10-28T09:00:00Z, the same fixed instant the calendar tests use.
    private let now = Date(timeIntervalSince1970: 1_793_178_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(daysFromNow days: Int) -> Date {
        now.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private func lease(name: String = "Example", expiresInDays: Int?, lead: Int = 2) -> SideloadLease {
        SideloadLease(
            id: "lease-" + name,
            displayName: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            signedAt: date(daysFromNow: -1),
            profileExpiresAt: expiresInDays.map { date(daysFromNow: $0) },
            account: .personalTeam,
            refreshLeadDays: lead
        )
    }

    private func plan(_ leases: [SideloadLease], limit: Int = 12) -> SideloadRefreshReminderPlan {
        SideloadRefreshReminderPlan.make(
            for: leases,
            at: now,
            calendar: utc,
            limit: limit,
            dayLabel: { date in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = self.utc
                formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                formatter.dateFormat = "d MMM"
                return formatter.string(from: date)
            }
        )
    }

    // MARK: - Which leases earn one

    /// A seven-day lease with a two-day lead fires at nine on the day it should
    /// be signed again — day five — not on the expiry.
    func testAReminderFiresOnTheDayToSignAgain() throws {
        let result = plan([lease(expiresInDays: 7)])
        XCTAssertEqual(result.count, 1)
        let reminder = try XCTUnwrap(result.reminders.first)
        XCTAssertEqual(reminder.fireAt, date(daysFromNow: 5).addingTimeInterval(0))
        let components = utc.dateComponents([.day, .hour], from: reminder.fireAt)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 9)
    }

    /// Work that is already due — or already late — is not reminded. The queue
    /// says it out loud, and a notification about a date that has passed is
    /// noise, not a nudge.
    func testWorkThatIsAlreadyDueIsNotReminded() {
        let result = plan([
            lease(name: "Due", expiresInDays: 2),
            lease(name: "Late", expiresInDays: -4),
        ])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.skippedInPast, 2)
    }

    /// A lease with no expiry has no action date and no reminder.
    func testALeaseWithNoExpiryEarnsNoReminder() {
        let result = plan([lease(expiresInDays: nil)])
        XCTAssertEqual(result, .empty)
    }

    /// The cap holds, and what it dropped is counted rather than hidden.
    func testTheCapHoldsAndCountsWhatItDropped() {
        let many = (1...4).map { lease(name: "App\($0)", expiresInDays: 10 + $0) }
        let result = plan(many, limit: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.skippedBeyondLimit, 2)
        XCTAssertEqual(result.skippedInPast, 0)
    }

    /// A cap of zero schedules nothing at all.
    func testACapOfZeroSchedulesNothing() {
        XCTAssertEqual(plan([lease(expiresInDays: 7)], limit: 0), .empty)
    }

    /// Reminders come out soonest first, whatever order the journal returned.
    func testRemindersAreOrderedSoonestFirst() {
        let result = plan([
            lease(name: "Later", expiresInDays: 30),
            lease(name: "Sooner", expiresInDays: 9),
        ])
        XCTAssertEqual(result.reminders.map(\.leaseID), ["lease-Sooner", "lease-Later"])
    }

    // MARK: - What a reminder says

    /// The title names the app and the day; the body names the expiry behind
    /// that day. Neither claims the build is installed.
    func testTheTextNamesTheDayAndTheExpiry() throws {
        let result = plan([lease(name: "Alpha", expiresInDays: 7)])
        let reminder = try XCTUnwrap(result.reminders.first)
        XCTAssertEqual(reminder.title, "Re-sign Alpha by 2 Nov")
        XCTAssertEqual(reminder.body, "The profile behind it expires 4 Nov. Sign it again to get a fresh profile.")
        XCTAssertFalse(reminder.body.lowercased().contains("installed"))
    }

    /// The identifier is stable and namespaced, so a re-read replaces the
    /// reminder instead of adding a second one — and clearing this app's
    /// reminders cannot touch anyone else's.
    func testTheIdentifierIsStableAndNamespaced() throws {
        let first = try XCTUnwrap(plan([lease(expiresInDays: 7)]).reminders.first)
        let second = try XCTUnwrap(plan([lease(expiresInDays: 7)]).reminders.first)
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.id.hasPrefix(SideloadRefreshReminder.identifierPrefix))
        XCTAssertEqual(first.id, "zynsign.refresh.lease-Example")
    }
}

/// A scheduler double: it records what the model asked it to do, and nothing
/// leaves the test process. Non-isolated so it witnesses the port exactly as
/// the platform adapter does; the model only ever calls it from the main actor.
final class RecordingRefreshReminders: RefreshReminderScheduling, @unchecked Sendable {

    var isSupported = true
    private(set) var scheduled: [[SideloadRefreshReminder]] = []
    private(set) var authorizationRequests = 0
    private(set) var clearCount = 0

    func schedule(_ reminders: [SideloadRefreshReminder]) async {
        scheduled.append(reminders)
    }

    func requestAuthorizationIfNeeded() async {
        authorizationRequests += 1
    }

    func clearScheduled() async {
        clearCount += 1
    }
}
