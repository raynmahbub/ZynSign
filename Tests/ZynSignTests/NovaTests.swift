import XCTest
@testable import ZynSign

/// v3.0 Nova — the Domain behind the Smart Workspace, the Nova Assistant,
/// and Install Health Pro. Everything here is pure: a clock and facts in,
/// an order / a list of suggestions / a report out.
final class NovaTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour))!
    }

    // MARK: - Workspace layout

    func testDefaultOrderWithNoUsageAndNothingLive() {
        let policy = WorkspaceLayoutPolicy()
        let order = policy.order(usage: [], context: WorkspaceContext(), now: date(hour: 14), calendar: calendar)
        XCTAssertEqual(order.count, WorkspaceWidget.allCases.count)
        XCTAssertEqual(Set(order), Set(WorkspaceWidget.allCases), "the policy never hides a widget")
        // Afternoon nudges the queue and the score up, everything else keeps the default order.
        XCTAssertEqual(order.first, .healthScore)
        XCTAssertEqual(order[1], .signingQueue)
        XCTAssertEqual(Array(order.dropFirst(2)), WorkspaceWidget.defaultOrder.filter { $0 != .healthScore && $0 != .signingQueue })
    }

    func testLiveWorkOutranksEverything() {
        let policy = WorkspaceLayoutPolicy()
        let usage = [WorkspaceUsageSignal(widget: .collections, openCount: 50, lastOpenedAt: date(hour: 9))]
        let order = policy.order(
            usage: usage,
            context: WorkspaceContext(activeSigningJobs: 1, activeDownloads: 2),
            now: date(hour: 9), calendar: calendar)
        XCTAssertEqual(order[0], .signingQueue)
        XCTAssertEqual(order[1], .downloads)
    }

    func testMorningLeadsWithContinueLastSession() {
        let policy = WorkspaceLayoutPolicy()
        let order = policy.order(usage: [], context: WorkspaceContext(hasLastSession: true), now: date(hour: 8), calendar: calendar)
        XCTAssertEqual(order.first, .continueLastSession)
        XCTAssertTrue(order.firstIndex(of: .recentApps)! < order.firstIndex(of: .collections)!)
    }

    func testNightRecommendsBackupWhenStale() {
        let policy = WorkspaceLayoutPolicy(backupReminderDays: 7)
        let stale = policy.order(usage: [], context: WorkspaceContext(daysSinceBackup: 10), now: date(hour: 23), calendar: calendar)
        XCTAssertEqual(stale.first, .backupStatus)
        let fresh = policy.order(usage: [], context: WorkspaceContext(daysSinceBackup: 1), now: date(hour: 23), calendar: calendar)
        XCTAssertNotEqual(fresh.first, .backupStatus)
    }

    func testUsageReordersWithRecencyDecay() {
        let policy = WorkspaceLayoutPolicy()
        let now = date(hour: 14)
        // Heavy usage so the decayed signal still clears the afternoon's
        // fixed nudges when it is fresh, and sinks to the floor when it is
        // not — that crossing is what reorders the two layouts.
        let recent = [WorkspaceUsageSignal(widget: .collections, openCount: 50, lastOpenedAt: now.addingTimeInterval(-day))]
        let old = [WorkspaceUsageSignal(widget: .collections, openCount: 50, lastOpenedAt: now.addingTimeInterval(-90 * day))]
        let recentOrder = policy.order(usage: recent, context: WorkspaceContext(), now: now, calendar: calendar)
        let oldOrder = policy.order(usage: old, context: WorkspaceContext(), now: now, calendar: calendar)
        XCTAssertTrue(recentOrder.firstIndex(of: .collections)! < oldOrder.firstIndex(of: .collections)!)
    }

    func testDaypartsAndGreetings() {
        XCTAssertEqual(WorkspaceDaypart(hour: 6), .morning)
        XCTAssertEqual(WorkspaceDaypart(hour: 13), .afternoon)
        XCTAssertEqual(WorkspaceDaypart(hour: 20), .evening)
        XCTAssertEqual(WorkspaceDaypart(hour: 2), .night)
        XCTAssertEqual(WorkspaceDaypart(hour: 20).greeting, "Good Evening")
    }

    // MARK: - Session

    func testSessionSummaryAndResumeWindow() {
        let now = date(hour: 10)
        let session = WorkspaceSession(activity: .signing, applicationRecordID: "id", applicationDisplayName: "Example", recordedAt: now.addingTimeInterval(-day))
        XCTAssertEqual(session.summary, "Signing · Example")
        XCTAssertTrue(session.isResumable(now: now))
        XCTAssertFalse(session.isResumable(now: now.addingTimeInterval(30 * day)))
        XCTAssertEqual(WorkspaceSession(activity: .browsingStore, recordedAt: now).summary, "Browsing the Store")
    }

    func testSessionRoundTripsThroughCodable() throws {
        let session = WorkspaceSession(activity: .inspecting, applicationRecordID: "abc", applicationDisplayName: "App", recordedAt: date(hour: 1))
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSession.self, from: data), session)
    }

    // MARK: - Nova Assistant

    private func facts(now: Date) -> NovaFacts {
        NovaFacts(
            certificates: [
                .init(name: "Team Cert", expiresAt: now.addingTimeInterval(4 * day)),
                .init(name: "Old Cert", expiresAt: now.addingTimeInterval(-1 * day)),
                .init(name: "Fresh Cert", expiresAt: now.addingTimeInterval(300 * day)),
            ],
            profiles: [
                .init(name: "Wildcard", expiresAt: now.addingTimeInterval(200 * day), bundleIdentifierPatterns: ["ABCDE12345.*"]),
                .init(name: "Exact", expiresAt: now.addingTimeInterval(2 * day), bundleIdentifierPatterns: ["com.example.app"]),
            ],
            applications: [
                .init(displayName: "Example", bundleIdentifier: "com.example.app", importedAt: now, wasSignedBefore: true),
                .init(displayName: "Example (old)", bundleIdentifier: "com.example.app", importedAt: now.addingTimeInterval(-day), wasSignedBefore: false),
                .init(displayName: "Other", bundleIdentifier: "com.other.app", importedAt: now, wasSignedBefore: false),
            ],
            daysSinceBackup: 9
        )
    }

    func testAdvisorFlagsExpiringAndExpiredIdentities() {
        let now = date(hour: 12)
        let recs = NovaAdvisor(limit: 50).recommendations(for: facts(now: now), now: now)
        let kinds = recs.map(\.kind)
        XCTAssertTrue(kinds.contains(.certificateExpired))
        XCTAssertTrue(kinds.contains(.certificateExpiring))
        XCTAssertTrue(recs.contains { $0.kind == .certificateExpiring && $0.title == "Team Cert expires in 4 days" })
        XCTAssertFalse(recs.contains { $0.title.hasPrefix("Fresh Cert") })
        XCTAssertTrue(kinds.contains(.profileExpiring))
    }

    func testAdvisorMatchesProfilesToApps() {
        let now = date(hour: 12)
        let recs = NovaAdvisor(limit: 50).recommendations(for: facts(now: now), now: now)
        XCTAssertTrue(recs.contains { $0.kind == .previouslySignedApp && $0.subject == "com.example.app" })
        XCTAssertTrue(recs.contains { $0.kind == .matchingProfileExists && $0.subject == "com.other.app" }, "the wildcard covers it")
        XCTAssertTrue(recs.contains { $0.kind == .duplicateBundle && $0.subject == "com.example.app" })
        XCTAssertTrue(recs.contains { $0.kind == .backupRecommended })
    }

    func testAdvisorIsQuietWithNothingToSay() {
        let now = date(hour: 12)
        XCTAssertTrue(NovaAdvisor().recommendations(for: NovaFacts(), now: now).isEmpty)
    }

    func testAdvisorOrdersUrgentFirstAndRespectsTheLimit() {
        let now = date(hour: 12)
        let recs = NovaAdvisor(limit: 3).recommendations(for: facts(now: now), now: now)
        XCTAssertEqual(recs.count, 3)
        XCTAssertEqual(recs.first?.severity, .urgent)
        XCTAssertTrue(zip(recs, recs.dropFirst()).allSatisfy { $0.severity >= $1.severity })
    }

    func testAdvisorNudgesFirstStepsWithoutIdentities() {
        let now = date(hour: 12)
        let onlyApps = NovaFacts(applications: [.init(displayName: "A", bundleIdentifier: "com.a", importedAt: now, wasSignedBefore: false)])
        XCTAssertEqual(NovaAdvisor().recommendations(for: onlyApps, now: now).map(\.kind), [.noIdentityYet])
        let onlyCert = NovaFacts(certificates: [.init(name: "C", expiresAt: now.addingTimeInterval(100 * day))])
        XCTAssertEqual(NovaAdvisor().recommendations(for: onlyCert, now: now).map(\.kind), [.noProfileYet])
    }

    func testAppIdentifierPatternMatching() {
        XCTAssertTrue(NovaAdvisor.pattern("*", matches: "com.x.y"))
        XCTAssertTrue(NovaAdvisor.pattern("ABCDE12345.*", matches: "com.x.y"))
        XCTAssertTrue(NovaAdvisor.pattern("com.x.*", matches: "com.x.y"))
        XCTAssertFalse(NovaAdvisor.pattern("com.x.*", matches: "com.xy"))
        XCTAssertTrue(NovaAdvisor.pattern("ABCDE12345.com.x.y", matches: "com.x.y"))
        XCTAssertFalse(NovaAdvisor.pattern("com.x.y", matches: "com.x.z"))
    }

    func testRecommendationIdentityIsStable() {
        let now = date(hour: 12)
        let a = NovaAdvisor(limit: 50).recommendations(for: facts(now: now), now: now)
        let b = NovaAdvisor(limit: 50).recommendations(for: facts(now: now), now: now)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "ids are unique")
    }

    // MARK: - Install Health Pro

    func testHealthReportFillsMissingChecksAsNotPerformed() {
        let report = InstallHealthReport(checks: [
            InstallHealthCheck(kind: .certificateValid, status: .passed, note: "ok"),
        ])
        XCTAssertEqual(report.checks.count, InstallHealthCheck.Kind.allCases.count)
        XCTAssertEqual(report.notPerformed.count, InstallHealthCheck.Kind.allCases.count - 1)
        XCTAssertEqual(report.score, 20, "not-performed earns nothing")
        XCTAssertEqual(report.verdict, .attention)
    }

    func testHealthReportIsReadyOnlyWhenEverythingPassed() {
        let all = InstallHealthCheck.Kind.allCases.map { InstallHealthCheck(kind: $0, status: .passed, note: "ok") }
        let report = InstallHealthReport(checks: all)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.verdict, .ready)
    }

    func testHealthReportBlocksOnGatingFailure() {
        var checks = InstallHealthCheck.Kind.allCases.map { InstallHealthCheck(kind: $0, status: .passed, note: "ok") }
        checks[0] = InstallHealthCheck(kind: .certificateValid, status: .failed, note: "expired")
        let report = InstallHealthReport(checks: checks)
        XCTAssertEqual(report.verdict, .blocked)
        XCTAssertEqual(report.score, 80)
        XCTAssertEqual(report.failed.map(\.kind), [.certificateValid])
    }

    func testHealthReportNonGatingFailureNeedsAttention() {
        var checks = InstallHealthCheck.Kind.allCases.map { InstallHealthCheck(kind: $0, status: .passed, note: "ok") }
        checks[7] = InstallHealthCheck(kind: .installHistory, status: .failed, note: "never installed")
        XCTAssertEqual(InstallHealthReport(checks: checks).verdict, .attention)
    }

    func testHealthPreviewNeverClaimsReady() {
        let now = date(hour: 12)
        let all = facts(now: now)
        let report = InstallHealthReport.preview(for: all.applications[2], facts: all, now: now)   // "Other", covered by the wildcard
        XCTAssertNotEqual(report.verdict, .ready, "binary checks have not run")
        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .profileCompatible }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .noBundleConflict }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .installHistory }?.status, .notPerformed)
        XCTAssertEqual(report.notPerformed.count, 5)
        XCTAssertEqual(report.score, 50)
    }

    func testHealthPreviewFlagsConflictsExpiryAndMissingCoverage() {
        let now = date(hour: 12)
        let all = facts(now: now)
        let duplicate = InstallHealthReport.preview(for: all.applications[0], facts: all, now: now)
        XCTAssertEqual(duplicate.checks.first { $0.kind == .noBundleConflict }?.status, .failed)
        XCTAssertTrue(duplicate.checks.first { $0.kind == .certificateValid }?.note.contains("healthy") == true, "the best certificate is the fresh one")

        let uncovered = NovaFacts(
            certificates: [.init(name: "C", expiresAt: now.addingTimeInterval(5 * day))],
            profiles: [.init(name: "P", expiresAt: now.addingTimeInterval(100 * day), bundleIdentifierPatterns: ["com.else"])],
            applications: [.init(displayName: "A", bundleIdentifier: "com.a", importedAt: now, wasSignedBefore: true)])
        let report = InstallHealthReport.preview(for: uncovered.applications[0], facts: uncovered, now: now)
        XCTAssertEqual(report.verdict, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.note, "C expires in 5 days.")
        XCTAssertEqual(report.checks.first { $0.kind == .profileCompatible }?.note, "No profile covers com.a.")
        XCTAssertEqual(report.checks.first { $0.kind == .installHistory }?.status, .passed)

        let empty = InstallHealthReport.preview(for: uncovered.applications[0], facts: NovaFacts(applications: uncovered.applications), now: now)
        XCTAssertEqual(empty.checks.first { $0.kind == .certificateValid }?.status, .notPerformed)
        XCTAssertEqual(empty.checks.first { $0.kind == .profileCompatible }?.status, .notPerformed)
        XCTAssertEqual(empty.verdict, .attention)
    }

    func testHealthWeightsSumToOneHundred() {
        XCTAssertEqual(InstallHealthCheck.Kind.allCases.reduce(0) { $0 + $1.weight }, 100)
    }

    // MARK: - File store

    func testFileWorkspaceStateStoreRoundTrips() throws {
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SmartWorkspace.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let store = FileWorkspaceStateStore(documentLocation: location)
        XCTAssertTrue(try store.usage().isEmpty)
        XCTAssertNil(try store.lastSession())

        let now = date(hour: 9)
        try store.recordOpen(of: .downloads, at: now)
        try store.recordOpen(of: .downloads, at: now.addingTimeInterval(60))
        try store.setLastSession(WorkspaceSession(activity: .signing, applicationDisplayName: "App", recordedAt: now))

        let reread = FileWorkspaceStateStore(documentLocation: location)
        let usage = try reread.usage()
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.openCount, 2)
        XCTAssertEqual(usage.first?.lastOpenedAt, now.addingTimeInterval(60))
        XCTAssertEqual(try reread.lastSession()?.summary, "Signing · App")

        try reread.setLastSession(nil)
        XCTAssertNil(try FileWorkspaceStateStore(documentLocation: location).lastSession())
    }

    func testFileWorkspaceStateStoreTreatsDamageAsAbsent() throws {
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: location) }
        try Data("not json".utf8).write(to: location)
        let store = FileWorkspaceStateStore(documentLocation: location)
        XCTAssertTrue(try store.usage().isEmpty)
        try store.recordOpen(of: .activity, at: date(hour: 1))
        XCTAssertEqual(try FileWorkspaceStateStore(documentLocation: location).usage().first?.widget, .activity)
    }
}
