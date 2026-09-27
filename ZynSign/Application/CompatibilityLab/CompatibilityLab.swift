import Foundation

/// One family of compatibility checks.
///
/// A suite is a pure question about ZynSign and its environment: it receives
/// a context, runs its checks, and returns them. Adding a suite is adding a
/// type and one line in `CompatibilityLab.suites` — the dashboard, the
/// checklist, the report and the release verdict all pick it up, because they
/// read the checks rather than the suites that produced them.
protocol CompatibilitySuite {

    /// The checks this suite contributes.
    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck]
}

// MARK: - Orchestrator

/// Runs the Compatibility Lab and holds what it found.
///
/// The Lab is the single place a release candidate is judged. It composes
/// every suite, runs them in a deterministic order, applies any results a
/// maintainer imported for checks the device cannot make itself, and reduces
/// the outcome to three things a decision needs: the report, the checklist,
/// and whether the candidate may move on.
///
/// It is also deliberately non-destructive. Every file the Lab writes goes to
/// its own scratch directory under the temporary workspace, and the directory
/// is swept before and after each run. The Lab never imports into the library,
/// never signs, never exports, and never cleans up anything the user made.
@MainActor
final class CompatibilityLab: ObservableObject {

    /// Where a run is.
    enum Phase: Equatable {
        /// Nothing has run yet in this session.
        case idle
        /// A run is under way, with the fraction of suites completed.
        case running(progress: Double, suite: String)
        /// A run finished, with its report.
        case finished(CompatibilityLabReport)
        /// A run could not be completed.
        case failed(String)

        /// Whether a run is under way.
        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// The suites, in the order they run.
    ///
    /// Signing first: it is the pipeline everything else exists to serve, it
    /// builds the largest artifacts, and it warms the readers the later suites
    /// measure.
    private let suites: [(name: String, suite: any CompatibilitySuite)]

    /// The application environment the Lab reads through. It is set when the
    /// screen appears rather than at construction, so the view layer stays
    /// the only place SwiftUI and the application layer meet.
    var environment: ApplicationEnvironment?

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: CompatibilityLabReport?
    @Published private(set) var checklist: [QAReleaseChecklistResult] = []
    @Published private(set) var verdict: ReleaseReadinessVerdict?
    @Published private(set) var overlaySource: String = "none"

    init(
        environment: ApplicationEnvironment? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.now = now
        self.suites = [
            ("Signing scenarios", SigningScenarioLab()),
            ("iOS compatibility", IOSCompatibilitySuite()),
            ("Device compatibility", DeviceCompatibilitySuite()),
            ("Store and downloads", NetworkResilienceSuite()),
            ("Resources", ResourceResilienceSuite()),
            ("Crash resilience", CrashResilienceSuite()),
            ("Performance", PerformanceSuite()),
            ("Security posture", SecurityHardeningSuite()),
            ("Accessibility", AccessibilityAuditSuite()),
            ("Regressions", RegressionSuite())
        ]
    }

    // MARK: Running

    /// Runs every suite once and reduces the outcome.
    func run() async {
        let started = now()
        // A re-run replaces the previous result: the Lab is a measurement,
        // not a journal, and there is no value in keeping the older one.
        let preferences = environment?.preferencesStore.snapshot ?? .shippedDefault
        let overlayLocation = CompositionRoot.diagnosticReportDirectory()
            .appendingPathComponent("lab-overlay.json", isDirectory: false)
        let overlay = CompatibilityLabOverlay.load(from: overlayLocation, fileManager: fileManager)
        overlaySource = overlay.statuses.isEmpty ? "none" : overlay.source

        let scratchRoot = CompositionRoot.signingWorkspaceRoot()
            .appendingPathComponent("CompatibilityLab", isDirectory: true)
        // Sweep before, so a run that is interrupted twice over does not
        // inherit the first one's files, and after, so nothing is left.
        sweep(scratchRoot)

        var collected: [CompatibilityCheck] = []
        for (index, entry) in suites.enumerated() {
            phase = .running(progress: Double(index) / Double(suites.count), suite: entry.name)
            let context = CompatibilityLabContext(
                now: now,
                fileManager: fileManager,
                scratchRoot: scratchRoot,
                preferences: preferences,
                environment: environment,
                overlay: overlay
            )
            let checks = await entry.suite.checks(context: context)
            collected.append(contentsOf: checks.map { context.applyingOverlay(to: $0) })
        }
        sweep(scratchRoot)

        let facts = LabDeviceFacts.current(fileManager: fileManager)
        let information = ApplicationInfo.current()
        let finished = CompatibilityLabReport(
            generatedAt: started,
            releaseStage: ReleaseTrain.current.tag,
            marketingVersion: information.marketingVersion,
            buildVersion: information.buildVersion,
            osVersion: IOSCompatibilitySuite.runningVersionText,
            // ZynSign does not read a device's model identifier, and the Lab
            // does not start reading one to fill in a report field.
            deviceModel: "not recorded",
            deviceClass: facts.summary,
            checks: collected,
            notes: Self.notes(overlaySource: overlaySource, facts: facts)
        )
        report = finished
        checklist = QAReleaseChecklistEvaluator.items(report: finished)
        verdict = ReleaseReadinessEvaluator.verdict(for: finished)
        phase = .finished(finished)
    }

    /// Removes the Lab's own scratch directory. It contains nothing but files
    /// the Lab created, so a failed removal is reported rather than retried.
    private func sweep(_ root: URL) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    /// The notes that travel with every report: what it does not claim.
    private static func notes(overlaySource: String, facts: LabDeviceFacts) -> [String] {
        var notes = [
            "This report records what the Compatibility Lab executed on the device it ran on. A row marked \"Not run\" is an open question, not a pass.",
            "Checks marked as imported come from the overlay named \"\(overlaySource)\", supplied by a maintainer; they are never measurements this device took."
        ]
        if facts.isSimulator {
            notes.append("This run was made on a simulator. Timing and memory figures are not device figures, and are never compared against them.")
        }
        notes.append("Nothing in this run signed, imported, exported or deleted anything of the user's. The Lab works on synthetic packages it builds itself.")
        return notes
    }

    // MARK: Counting

    /// How many suites a run executes.
    var suiteCount: Int { suites.count }

    /// The report's checks grouped into the dashboard's six rows.
    var dashboard: [CompatibilityCategorySummary] {
        (report?.dashboardSummaries ?? []).isEmpty
            ? CompatibilityCategory.dashboard.map {
                CompatibilityCategorySummary(
                    category: $0, status: .notRun, checkCount: 0,
                    passedCount: 0, failedCount: 0, notRunCount: 0
                )
            }
            : report?.dashboardSummaries ?? []
    }

    /// The categories beyond the dashboard rows.
    var extendedSummaries: [CompatibilityCategorySummary] {
        guard let report else { return [] }
        return report.categorySummaries.filter { !CompatibilityCategory.dashboard.contains($0.category) }
    }

    // MARK: Export

    /// Writes the report as JSON to the diagnostics directory and returns its
    /// location, for sharing or for attaching to a release.
    ///
    /// The file holds no absolute path, no credential, and no user content:
    /// the report's vocabulary is counts, classifications, durations and the
    /// fixed text of its own checks.
    func writeReport() throws -> URL {
        guard let report else {
            throw ZynSignError(
                category: .internalFailure,
                userMessage: "There is no compatibility report to export yet.",
                diagnosticDetail: "Run the Compatibility Lab before exporting its report."
            )
        }
        let directory = CompositionRoot.diagnosticReportDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = directory
            .appendingPathComponent(Self.reportFileName(stage: report.releaseStage), isDirectory: false)
            .appendingPathExtension("json")
        let data = try report.jsonData()
        try data.write(to: location, options: .atomic)
        return location
    }

    /// The report file's base name: stable enough to compare between runs and
    /// between devices, and dated so two runs do not overwrite each other.
    static func reportFileName(stage: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "compatibility-lab-\(stage)-\(formatter.string(from: date))"
    }

    /// The report as text a human can read and paste into an issue.
    func reportText() -> String {
        guard let report else { return "No compatibility report has been produced yet." }
        var lines: [String] = [
            "ZynSign Compatibility Lab report",
            "Release stage: \(report.releaseStage) · \(report.marketingVersion) (\(report.buildVersion))",
            "Environment: iOS \(report.osVersion) · \(report.deviceClass)",
            "Generated: \(Self.timestamp(report.generatedAt))",
            ""
        ]
        if let verdict {
            lines.append("Verdict: \(verdict.readiness.displayName) — \(verdict.headline)")
            lines.append("")
        }
        for summary in report.categorySummaries {
            guard summary.checkCount > 0 else { continue }
            lines.append("\(summary.category.displayName) — \(summary.status.displayName) (\(summary.passedCount)/\(summary.checkCount) passed)")
            for check in report.checks(in: summary.category) {
                lines.append("  \(check.status.mark) \(check.title): \(check.summary)")
                if let next = check.nextStep, check.status != .passed {
                    lines.append("      next: \(next)")
                }
            }
            lines.append("")
        }
        lines.append("Checklist")
        for item in checklist {
            lines.append("  \(item.status.mark) \(item.item.title): \(item.status.displayName)")
            if let next = item.nextStep { lines.append("      next: \(next)") }
        }
        lines.append("")
        for note in report.notes { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }

    /// One timestamp, written the same way wherever it appears.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter.string(from: date)
    }
}
