import Foundation

// MARK: - Categories

/// One area the Compatibility Lab validates before a release candidate.
///
/// The set is deliberately small and fixed: it is the dashboard's shape, and
/// a release decision reads it top to bottom. Adding an area is a new case
/// plus a new suite; nothing that already exists has to change.
///
/// The Lab is validation, not a user feature: it appears only in Debug and
/// internal builds (see `CompatibilityLabAvailability`).
enum CompatibilityCategory: String, CaseIterable, Identifiable, Codable, Sendable {

    /// The supported iOS versions, and what each one was checked for.
    case iOSCompatibility

    /// The device classes ZynSign runs on, and what differs between them.
    case deviceCompatibility

    /// The signing pipeline: the scenario lab and the frozen regressions.
    case signingPipeline

    /// The repository browser and the download path, including failures.
    case storeBrowser

    /// Measured performance against the internal benchmarks.
    case performance

    /// Crash resilience: cancellation, concurrency, hostile input, recovery.
    case crashStatus

    /// Sensitive material: temporary files, logs, Keychain access, exports,
    /// backup behaviour, workspace cleanup.
    case securityPosture

    /// VoiceOver, Dynamic Type, Reduce Motion, contrast, targets, focus.
    case accessibility

    /// Low storage, memory pressure, large imports, cleanup behaviour.
    case resourceResilience

    /// The behaviour frozen by the regression suite.
    case regressionCoverage

    var id: String { rawValue }

    /// The six rows the Compatibility Lab dashboard shows.
    ///
    /// The extended categories are real and reported — they appear beneath
    /// the dashboard and feed the release verdict — but the dashboard keeps
    /// the shape a release decision reads: the platform, the pipeline, the
    /// store, the numbers, the resilience.
    static let dashboard: [CompatibilityCategory] = [
        .iOSCompatibility,
        .deviceCompatibility,
        .signingPipeline,
        .storeBrowser,
        .performance,
        .crashStatus
    ]

    /// Every category the Lab reports, dashboard first, then the extended ones.
    static let reported: [CompatibilityCategory] = dashboard + [
        .securityPosture,
        .accessibility,
        .resourceResilience,
        .regressionCoverage
    ]

    /// The name the dashboard shows.
    var displayName: String {
        switch self {
        case .iOSCompatibility: return "iOS Compatibility"
        case .deviceCompatibility: return "Device Compatibility"
        case .signingPipeline: return "Signing Pipeline"
        case .storeBrowser: return "Store Browser"
        case .performance: return "Performance"
        case .crashStatus: return "Crash Status"
        case .securityPosture: return "Security Posture"
        case .accessibility: return "Accessibility"
        case .resourceResilience: return "Resource Resilience"
        case .regressionCoverage: return "Regression Coverage"
        }
    }

    /// The SF Symbol for the category.
    var symbolName: String {
        switch self {
        case .iOSCompatibility: return "applelogo"
        case .deviceCompatibility: return "iphone.and.ipad"
        case .signingPipeline: return "signature"
        case .storeBrowser: return "bag.fill"
        case .performance: return "gauge.with.dots.needle.bottom.50percent"
        case .crashStatus: return "ladybug.fill"
        case .securityPosture: return "lock.shield.fill"
        case .accessibility: return "accessibility"
        case .resourceResilience: return "internaldrive.fill"
        case .regressionCoverage: return "checkmark.seal.fill"
        }
    }

    /// One sentence describing what the category proves.
    var summary: String {
        switch self {
        case .iOSCompatibility:
            return "ZynSign launches, imports, signs, exports and hands off on every supported iOS version."
        case .deviceCompatibility:
            return "Layout, performance, memory, multitasking and orientation hold on every supported device class."
        case .signingPipeline:
            return "Every package shape ZynSign accepts is discovered, planned and validated reproducibly."
        case .storeBrowser:
            return "Sources and downloads degrade gracefully on offline, slow, broken and partial responses."
        case .performance:
            return "Launch, search, import, signing preparation, scrolling and memory stay inside the benchmarks."
        case .crashStatus:
            return "Cancellation, concurrency, hostile input and interrupted work end in typed recoveries, not crashes."
        case .securityPosture:
            return "Sensitive material is handled to ZynSign's security architecture: temporary files, logs, Keychain, exports, backups, cleanup."
        case .accessibility:
            return "Core workflows are reachable with VoiceOver, Dynamic Type and Reduce Motion, and hold contrast and target sizes."
        case .resourceResilience:
            return "Low storage, memory pressure, large imports and cleanup fail safely instead of corrupting the workspace."
        case .regressionCoverage:
            return "Previously working behaviour is frozen: no workflow silently changed."
        }
    }
}

// MARK: - Status

/// The outcome of one compatibility check.
///
/// `notRun` and `skipped` are first-class answers, not gaps in the report.
/// A check that cannot execute honestly in this environment — an iOS version
/// this device does not run, a device class this device is not — says so.
/// Inventing a pass is the one thing the Lab must never do.
enum CompatibilityStatus: String, Codable, CaseIterable, Sendable, Equatable {

    /// The check ran and met its expectation.
    case passed

    /// The check ran and met its expectation with something worth a look.
    case warning

    /// The check ran and did not meet its expectation.
    case failed

    /// The check exists but did not execute in this environment.
    case notRun

    /// The check does not apply to this environment.
    case skipped

    /// The name the dashboard shows.
    var displayName: String {
        switch self {
        case .passed: return "Passed"
        case .warning: return "Needs attention"
        case .failed: return "Failed"
        case .notRun: return "Not run"
        case .skipped: return "Not applicable"
        }
    }

    /// The glyph the matrix tables show. Chosen to stay legible in a
    /// monospaced column and in VoiceOver's reading of the row.
    var mark: String {
        switch self {
        case .passed: return "✓"
        case .warning: return "!"
        case .failed: return "✗"
        case .notRun: return "—"
        case .skipped: return "·"
        }
    }

    /// How bad this outcome is when several checks roll up into one.
    /// Higher is worse; `notRun` outranks `passed` because an unrun check is
    /// an open question, not a result.
    var severity: Int {
        switch self {
        case .passed: return 0
        case .skipped: return 1
        case .warning: return 2
        case .notRun: return 3
        case .failed: return 4
        }
    }

    /// Whether this outcome settles the question the check asked.
    var isSettled: Bool {
        switch self {
        case .passed, .warning, .failed: return true
        case .notRun, .skipped: return false
        }
    }
}

// MARK: - Measurements

/// One number a check measured, against the benchmark ZynSign holds itself to.
///
/// A measurement without a threshold is information, not a verdict, and it
/// never decides a check's status on its own.
struct CompatibilityMeasurement: Codable, Equatable, Sendable, Identifiable {

    /// Which way the number is good.
    enum Comparison: String, Codable, Sendable {
        /// Smaller is better: durations, byte counts, latencies.
        case lowerIsBetter
        /// Larger is better: throughput, free space.
        case higherIsBetter
        /// Recorded for the record; no expectation is attached.
        case informational
    }

    /// What was measured. Fixed text.
    let name: String

    /// The measured value.
    let value: Double

    /// The unit the value is in (`ms`, `MB`, `count`, …).
    let unit: String

    /// The internal benchmark, when one exists.
    let threshold: Double?

    /// Which way the number is good.
    let comparison: Comparison

    var id: String { name }

    init(
        name: String,
        value: Double,
        unit: String,
        threshold: Double? = nil,
        comparison: Comparison = .informational
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.threshold = threshold
        self.comparison = comparison
    }

    /// Whether the measurement met its benchmark. `nil` when there is no
    /// benchmark to meet, or when the comparison carries no expectation.
    var isWithinBenchmark: Bool? {
        guard let threshold else { return nil }
        switch comparison {
        case .lowerIsBetter: return value <= threshold
        case .higherIsBetter: return value >= threshold
        case .informational: return nil
        }
    }

    /// The measurement as one line: `search latency 42 ms (benchmark 120 ms)`.
    var rendered: String {
        var text = "\(name): \(Self.rendered(value)) \(unit)"
        if let threshold {
            text += " (benchmark \(Self.rendered(threshold)) \(unit))"
        }
        return text
    }

    /// Renders without a `.0` for whole numbers, so `42 ms` stays `42 ms`.
    private static func rendered(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded(), abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - Checks

/// One compatibility check and what it established.
///
/// Every check answers the same three questions the error-recovery audit
/// asks of a failure, because a validation result nobody can act on is
/// noise:
///
/// - **What happened?** `summary`.
/// - **What was verified?** `verified` — the precise claim, and its limits.
/// - **What next?** `nextStep` — for a failing or unrun check, the action.
///
/// `evidence` carries the reproducible facts behind the answer: counts,
/// digests, classifications. It is written to be safe to share — no key
/// material, no credentials, no user content, and no absolute filesystem
/// paths.
struct CompatibilityCheck: Identifiable, Codable, Equatable, Sendable {

    /// A stable identifier, so a result can be tracked across runs and
    /// releases (`signing.scenario.simpleApplication`).
    let id: String

    /// The area the check belongs to.
    let category: CompatibilityCategory

    /// What the check asked.
    let title: String

    /// The outcome.
    let status: CompatibilityStatus

    /// One sentence on what happened.
    let summary: String

    /// The precise claim the run established, and its limits.
    let verified: String

    /// What to do when the outcome is not a pass. `nil` when there is
    /// nothing to do.
    let nextStep: String?

    /// The reproducible facts behind the outcome.
    let evidence: [String]

    /// What the run measured.
    let measurements: [CompatibilityMeasurement]

    /// How long the run took, in milliseconds. `0` for recorded checks.
    let durationMilliseconds: Int

    /// How badly a failure of this check blocks the release.
    let blocker: ReleaseBlockerSeverity?

    init(
        id: String,
        category: CompatibilityCategory,
        title: String,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        measurements: [CompatibilityMeasurement] = [],
        durationMilliseconds: Int = 0,
        blocker: ReleaseBlockerSeverity? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.status = status
        self.summary = summary
        self.verified = verified
        self.nextStep = nextStep
        self.evidence = evidence
        self.measurements = measurements
        self.durationMilliseconds = durationMilliseconds
        self.blocker = blocker
    }

    /// A one-line rendering for logs and exports, free of anything but the
    /// fixed text and the outcome.
    var logLine: String {
        "\(status.mark) \(category.rawValue).\(id): \(summary)"
    }
}

// MARK: - Report

/// The Lab's rollup for one category.
struct CompatibilityCategorySummary: Identifiable, Codable, Equatable, Sendable {
    let category: CompatibilityCategory
    let status: CompatibilityStatus
    let checkCount: Int
    let passedCount: Int
    let failedCount: Int
    let notRunCount: Int

    var id: String { category.rawValue }
}

/// The result of one Compatibility Lab run.
///
/// The report is versioned and exportable so the same artifact can be
/// attached to a beta, an RC, a hotfix, or a future iOS review, and so two
/// runs can be compared field by field. The JSON encoding is deterministic:
/// sorted keys, ISO-8601 timestamps, and a fixed key order, so a diff
/// between two reports contains only what actually changed.
struct CompatibilityLabReport: Codable, Equatable, Sendable {

    /// The schema this build writes. A reader that sees a newer schema says
    /// so rather than guessing at fields it does not know.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let releaseStage: String
    let marketingVersion: String
    let buildVersion: String
    let osVersion: String
    let deviceModel: String
    let deviceClass: String
    let checks: [CompatibilityCheck]
    let notes: [String]

    init(
        generatedAt: Date = Date(),
        releaseStage: String,
        marketingVersion: String,
        buildVersion: String,
        osVersion: String,
        deviceModel: String,
        deviceClass: String,
        checks: [CompatibilityCheck],
        notes: [String] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.releaseStage = releaseStage
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.deviceClass = deviceClass
        self.checks = checks
        self.notes = notes
    }

    /// Whether the report was written by a schema this build reads.
    var isReadableByThisBuild: Bool {
        schemaVersion <= Self.currentSchemaVersion
    }

    /// The checks of one category, in the order the suite produced them.
    func checks(in category: CompatibilityCategory) -> [CompatibilityCheck] {
        checks.filter { $0.category == category }
    }

    /// The worst outcome in a category. An empty category is `notRun`:
    /// a suite that produced nothing answered nothing.
    func status(of category: CompatibilityCategory) -> CompatibilityStatus {
        let matching = checks(in: category)
        guard let worst = matching.map(\.status).max(by: { $0.severity < $1.severity }) else {
            return .notRun
        }
        return worst
    }

    /// Every category, in dashboard order, with its rollup.
    var categorySummaries: [CompatibilityCategorySummary] {
        CompatibilityCategory.reported.map { category in
            let matching = checks(in: category)
            return CompatibilityCategorySummary(
                category: category,
                status: status(of: category),
                checkCount: matching.count,
                passedCount: matching.filter { $0.status == .passed }.count,
                failedCount: matching.filter { $0.status == .failed }.count,
                notRunCount: matching.filter { $0.status == .notRun || $0.status == .skipped }.count
            )
        }
    }

    /// The six rows the dashboard shows.
    var dashboardSummaries: [CompatibilityCategorySummary] {
        categorySummaries.filter { CompatibilityCategory.dashboard.contains($0.category) }
    }

    /// Whether every reported category settled. An unrun category leaves the
    /// report incomplete: it is an open question, not a pass.
    var isComplete: Bool {
        CompatibilityCategory.reported.allSatisfy { status(of: $0).isSettled }
    }

    /// The deterministic JSON export.
    ///
    /// Sorted keys and fixed date encoding keep two runs of the same build
    /// byte-comparable apart from the values that genuinely changed.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads a report written by this or an earlier schema version.
    static func decode(from data: Data) throws -> CompatibilityLabReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CompatibilityLabReport.self, from: data)
    }
}
