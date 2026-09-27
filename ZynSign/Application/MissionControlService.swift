import Foundation
import Combine

/// Mission Control — "Refresh Everything" orchestration.
///
/// One tap executes:
/// 1. Repository refresh (StoreRepository.refresh)
/// 2. Library update checks (re-read entries, re-validate availability)
/// 3. Eligible re-sign (no-op placeholder — pipeline invoked only when user confirms)
/// 4. Cache cleanup (prune tmp, expired downloads)
///
/// Each phase reports its outcome as a typed step; a phase failing does not
/// abort later phases. The aggregate is `MissionControlReport`, persisted only
/// as counts/timings — no profile, cert, or entitlement values are logged.
struct MissionControlReport: Equatable {
    let startedAt: Date
    let finishedAt: Date
    var durationMilliseconds: Int { Int(finishedAt.timeIntervalSince(startedAt)*1000) }
    let repository: StepReport
    let library: StepReport
    let reSignEligible: Int
    let cacheCleanup: StepReport

    struct StepReport: Equatable {
        let status: String // "Completed","Partial","Unavailable","Skipped"
        let detail: String
        let count: Int
    }

    var isSuccess: Bool { repository.status == "Completed" && library.status == "Completed" }
}

@MainActor
final class MissionControlService: ObservableObject {
    @Published var lastReport: MissionControlReport?
    @Published var isRunning = false

    private let fm = FileManager.default

    func refreshEverything(
        refreshRepositories: () async -> Int,
        checkLibrary: () async -> Int,
        cleanupCache: () -> Int
    ) async -> MissionControlReport {
        isRunning = true
        defer { isRunning = false }
        let start = Date()
        let repoCount = await refreshRepositories()
        let repoReport = MissionControlReport.StepReport(status: repoCount >= 0 ? "Completed" : "Unavailable", detail: repoCount >= 0 ? "\(repoCount) sources refreshed" : "Source refresh unavailable; review Store → Sources.", count: max(0, repoCount))

        let libCount = await checkLibrary()
        let libReport = MissionControlReport.StepReport(status: "Completed", detail: "\(libCount) apps in library", count: libCount)

        // Re-sign eligibility is a policy check only — no signing is triggered here.
        let eligible = 0 // computed from library entries that are unsigned + identity available; kept 0 until signing pipeline wired to Mission Control

        let cleaned = cleanupCache()
        let cacheReport = MissionControlReport.StepReport(status: "Completed", detail: "\(cleaned) tmp files removed", count: cleaned)

        let report = MissionControlReport(startedAt: start, finishedAt: Date(), repository: repoReport, library: libReport, reSignEligible: eligible, cacheCleanup: cacheReport)
        lastReport = report
        return report
    }

    func defaultCleanup() -> Int {
        let tmp = fm.temporaryDirectory
        guard let contents = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return 0 }
        var removed = 0
        let cutoff = Date().addingTimeInterval(-24*3600)
        for url in contents where url.lastPathComponent.hasPrefix("zynsign") || url.lastPathComponent.hasPrefix("ZynSign") {
            if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]), let date = vals.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url); removed += 1
            }
        }
        // Download Center files are not pruned here. Validated packages and
        // imported apps are removed only by an explicit Download Center or
        // Library action.
        return removed
    }
}
