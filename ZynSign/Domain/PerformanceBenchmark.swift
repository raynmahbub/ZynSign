import Foundation

/// One thing ZynSign measures about itself.
///
/// Each kind names an operation the user feels — how long the library
/// takes to appear, how long a search keystroke takes to answer, how long
/// an import or a signing preparation or a store manifest takes — and
/// carries the budget a build is expected to meet. The budgets are
/// ZynSign's own targets, not platform guarantees.
enum BenchmarkKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case libraryLoad
    case searchLatency
    case importSpeed
    case signingPreparation
    case storeLoading
    case thumbnailGeneration
    case indexBuild
    case launch

    var id: Self { self }

    var displayName: String {
        switch self {
        case .libraryLoad: return "Library Load"
        case .searchLatency: return "Search Latency"
        case .importSpeed: return "Import Speed"
        case .signingPreparation: return "Signing Preparation"
        case .storeLoading: return "Store Loading"
        case .thumbnailGeneration: return "Thumbnail Generation"
        case .indexBuild: return "Index Build"
        case .launch: return "Launch to First Frame"
        }
    }

    /// The duration a build is expected to stay under for a representative
    /// workload. Used by the regression detector as an absolute ceiling in
    /// addition to the relative comparison against the baseline.
    var budget: TimeInterval {
        switch self {
        case .libraryLoad: return 0.500
        case .searchLatency: return 0.016
        case .importSpeed: return 5.0
        case .signingPreparation: return 2.0
        case .storeLoading: return 1.0
        case .thumbnailGeneration: return 0.050
        case .indexBuild: return 0.250
        case .launch: return 1.5
        }
    }

    /// What the measurement covers, for the diagnostics table.
    var explanation: String {
        switch self {
        case .libraryLoad: return "Reading every record and building the library index."
        case .searchLatency: return "Answering one search query against the index."
        case .importSpeed: return "Admitting a synthetic package into a scratch library."
        case .signingPreparation: return "Preparing the inputs of one signing operation, without signing."
        case .storeLoading: return "Decoding and indexing a cached source manifest."
        case .thumbnailGeneration: return "Producing one thumbnail set from cached icon bytes."
        case .indexBuild: return "Building the search index over the library's documents."
        case .launch: return "From process start to the first frame of the Home screen."
        }
    }
}

/// One measurement of one benchmark.
struct BenchmarkMeasurement: Equatable, Hashable, Sendable, Codable, Identifiable {

    let id: UUID

    /// What was measured.
    let kind: BenchmarkKind

    /// How long the operation took, in seconds.
    let duration: TimeInterval

    /// How many items the operation covered — records loaded, documents
    /// searched, bytes imported — so two measurements can be compared per
    /// item as well as in total.
    let itemCount: Int

    /// When the measurement was taken.
    let measuredAt: Date

    /// The build the measurement was taken on, so a baseline from another
    /// build is recognised as such.
    let buildIdentifier: String

    init(
        id: UUID = UUID(),
        kind: BenchmarkKind,
        duration: TimeInterval,
        itemCount: Int,
        measuredAt: Date,
        buildIdentifier: String
    ) {
        self.id = id
        self.kind = kind
        self.duration = max(0, duration)
        self.itemCount = max(0, itemCount)
        self.measuredAt = measuredAt
        self.buildIdentifier = buildIdentifier
    }

    /// Seconds per item, or the whole duration when nothing was counted.
    var durationPerItem: TimeInterval {
        itemCount > 0 ? duration / Double(itemCount) : duration
    }

    /// Whether the measurement met its kind's budget.
    var isWithinBudget: Bool {
        duration <= kind.budget
    }
}

/// The reference measurements a build is compared against: one per kind,
/// recorded when the developer accepted the current performance as the
/// standard to hold.
struct BenchmarkBaseline: Equatable, Sendable, Codable {

    /// The reference measurement for each kind.
    let measurements: [BenchmarkKind: BenchmarkMeasurement]

    /// When the baseline was recorded.
    let recordedAt: Date

    init(measurements: [BenchmarkKind: BenchmarkMeasurement], recordedAt: Date) {
        self.measurements = measurements
        self.recordedAt = recordedAt
    }

    /// A baseline built from the latest measurement of each kind.
    init(latestOf measurements: [BenchmarkMeasurement], recordedAt: Date) {
        var byKind: [BenchmarkKind: BenchmarkMeasurement] = [:]
        for measurement in measurements.sorted(by: { $0.measuredAt < $1.measuredAt }) {
            byKind[measurement.kind] = measurement
        }
        self.init(measurements: byKind, recordedAt: recordedAt)
    }

    func measurement(for kind: BenchmarkKind) -> BenchmarkMeasurement? {
        measurements[kind]
    }

    // The dictionary is encoded as a list so the document is a plain JSON
    // array of measurements rather than the alternating key/value array
    // Swift produces for enum-keyed dictionaries.
    private enum CodingKeys: String, CodingKey {
        case measurements
        case recordedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decode([BenchmarkMeasurement].self, forKey: .measurements)
        let recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        self.init(latestOf: list, recordedAt: recordedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let list = measurements.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        try container.encode(list, forKey: .measurements)
        try container.encode(recordedAt, forKey: .recordedAt)
    }
}

/// How one benchmark compares to its baseline.
struct PerformanceRegressionFinding: Equatable, Hashable, Sendable, Identifiable {

    enum Verdict: String, Hashable, Sendable {

        /// Within tolerance of the baseline and within budget.
        case stable

        /// Faster than the baseline by more than the tolerance.
        case improved

        /// Slower than the baseline by more than the tolerance, or over
        /// budget.
        case regressed

        /// No baseline to compare against.
        case unmeasured

        var displayName: String {
            switch self {
            case .stable: return "Stable"
            case .improved: return "Improved"
            case .regressed: return "Regressed"
            case .unmeasured: return "No Baseline"
            }
        }
    }

    let kind: BenchmarkKind
    let verdict: Verdict

    /// The current duration per item.
    let current: TimeInterval

    /// The baseline duration per item, when a baseline exists.
    let baseline: TimeInterval?

    /// `current / baseline`, when a baseline exists. Greater than one means
    /// slower.
    let ratio: Double?

    var id: BenchmarkKind { kind }
}

/// The comparison of a set of measurements against a baseline.
struct PerformanceRegressionReport: Equatable, Sendable {

    let findings: [PerformanceRegressionFinding]

    /// When the comparison was made.
    let comparedAt: Date

    /// The findings whose verdict is `regressed`.
    var regressions: [PerformanceRegressionFinding] {
        findings.filter { $0.verdict == .regressed }
    }

    /// Whether any benchmark regressed.
    var hasRegressions: Bool { !regressions.isEmpty }

    func finding(for kind: BenchmarkKind) -> PerformanceRegressionFinding? {
        findings.first { $0.kind == kind }
    }
}

/// Compares measurements against a baseline. Pure, so the rule is testable
/// and the same in a test target as on a device.
///
/// The comparison is per item: a library that doubled in size is allowed
/// to take longer to load. A kind regresses when its per-item duration
/// exceeds the baseline by more than `tolerance` (a fraction), or when its
/// absolute duration exceeds the kind's budget. It improves when it is
/// faster by more than the tolerance. Anything else is stable.
struct PerformanceRegressionDetector: Equatable, Sendable {

    /// The relative slowdown tolerated before a regression is declared.
    /// 0.25 means a quarter slower per item.
    let tolerance: Double

    /// Durations below this floor are treated as noise and never compared
    /// by ratio: a 0.1 ms search that became 0.2 ms is not a regression.
    let noiseFloor: TimeInterval

    init(tolerance: Double = 0.25, noiseFloor: TimeInterval = 0.002) {
        self.tolerance = max(0, tolerance)
        self.noiseFloor = max(0, noiseFloor)
    }

    func compare(
        _ measurements: [BenchmarkMeasurement],
        against baseline: BenchmarkBaseline?,
        now: Date
    ) -> PerformanceRegressionReport {
        var latest: [BenchmarkKind: BenchmarkMeasurement] = [:]
        for measurement in measurements.sorted(by: { $0.measuredAt < $1.measuredAt }) {
            latest[measurement.kind] = measurement
        }
        let findings: [PerformanceRegressionFinding] = BenchmarkKind.allCases.compactMap { kind in
            guard let current = latest[kind] else { return nil }
            return finding(for: current, baseline: baseline?.measurement(for: kind))
        }
        return PerformanceRegressionReport(findings: findings, comparedAt: now)
    }

    func finding(
        for current: BenchmarkMeasurement,
        baseline: BenchmarkMeasurement?
    ) -> PerformanceRegressionFinding {
        let currentPerItem = current.durationPerItem
        guard let baseline else {
            return PerformanceRegressionFinding(
                kind: current.kind,
                verdict: current.isWithinBudget ? .unmeasured : .regressed,
                current: currentPerItem,
                baseline: nil,
                ratio: nil
            )
        }
        let baselinePerItem = baseline.durationPerItem
        let ratio: Double? = baselinePerItem > 0 ? currentPerItem / baselinePerItem : nil
        let verdict: PerformanceRegressionFinding.Verdict
        if !current.isWithinBudget {
            verdict = .regressed
        } else if current.duration < noiseFloor && baseline.duration < noiseFloor {
            verdict = .stable
        } else if let ratio {
            if ratio > 1 + tolerance {
                verdict = .regressed
            } else if ratio < 1 - tolerance {
                verdict = .improved
            } else {
                verdict = .stable
            }
        } else {
            verdict = .stable
        }
        return PerformanceRegressionFinding(
            kind: current.kind,
            verdict: verdict,
            current: currentPerItem,
            baseline: baselinePerItem,
            ratio: ratio
        )
    }
}
