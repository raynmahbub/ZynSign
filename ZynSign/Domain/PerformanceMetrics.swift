import Foundation

/// One figure the Performance page shows: a name, a value already phrased
/// for people, and an optional detail line.
///
/// Values are strings on purpose. The page is a diagnostic table, not a
/// data source; every number is formatted where it is measured, by the
/// code that knows its unit, so the table cannot mis-format a byte count as
/// a duration or a count as a size.
struct PerformanceMetric: Equatable, Hashable, Sendable, Identifiable {

    /// A stable identity for the row, so lists diff by metric rather than
    /// by value.
    let id: String

    /// The metric's name, as the table's leading column.
    let title: String

    /// The value, formatted.
    let value: String

    /// One line of explanation or context, or `nil`.
    let detail: String?

    init(id: String, title: String, value: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

/// The runtime picture the Performance page renders: the fixed metrics the
/// page always shows, then the per-category cache statistics and the most
/// recent benchmark results.
struct PerformanceSnapshot: Equatable, Sendable {

    /// Entries the library holds.
    let libraryItemCount: Int

    /// Entries the search index answers for.
    let indexedApplicationCount: Int

    /// The search index's readiness.
    let searchIndexStatus: SearchIndexStatus

    /// Every cache category's statistics, in category order.
    let cacheStatistics: [CacheStatistics]

    /// When `optimize()` last completed, or `nil` when it never has.
    let lastOptimization: Date?

    /// The most recent measurement of each benchmark, most recent first.
    let recentBenchmarks: [BenchmarkMeasurement]

    /// The last regression report, when a baseline exists.
    let regressionReport: PerformanceRegressionReport?

    /// The current memory pressure ZynSign has observed.
    let memoryPressure: MemoryPressureLevel

    /// How many times caches were trimmed for memory this launch.
    let memoryTrimCount: Int

    /// Background work in flight and waiting, for the diagnostics table.
    let backgroundWork: BackgroundWorkSummary

    /// The recorded launch timeline, when one was recorded.
    let launch: LaunchTimeline?

    /// The bytes every cache category holds together.
    var totalCacheByteCount: Int {
        cacheStatistics.reduce(0) { $0 + $1.byteCount }
    }

    /// The thumbnail category's statistics.
    var thumbnailStatistics: CacheStatistics {
        cacheStatistics.first { $0.category == .thumbnails } ?? .empty(.thumbnails)
    }

    /// A snapshot in which nothing has been measured.
    static let empty = PerformanceSnapshot(
        libraryItemCount: 0,
        indexedApplicationCount: 0,
        searchIndexStatus: .empty,
        cacheStatistics: CacheCategory.allCases.map { .empty($0) },
        lastOptimization: nil,
        recentBenchmarks: [],
        regressionReport: nil,
        memoryPressure: .nominal,
        memoryTrimCount: 0,
        backgroundWork: .idle,
        launch: nil
    )
}

/// How much background work the scheduler is carrying.
struct BackgroundWorkSummary: Equatable, Hashable, Sendable {
    let runningCount: Int
    let waitingCount: Int
    let completedCount: Int

    static let idle = BackgroundWorkSummary(runningCount: 0, waitingCount: 0, completedCount: 0)
}

/// The memory pressure the system has reported, from ZynSign's point of
/// view. The levels map onto the platform's own warning levels; `nominal`
/// is the absence of a report.
enum MemoryPressureLevel: Int, Comparable, Codable, Hashable, Sendable, CaseIterable {
    case nominal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .nominal: return "Nominal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// The instants a launch passes through, as offsets from the process
/// start, so the Performance page can show where launch time went and a
/// later build can be compared against an earlier one.
struct LaunchTimeline: Equatable, Hashable, Sendable, Codable {

    /// One named instant.
    struct Mark: Equatable, Hashable, Sendable, Codable, Identifiable {
        let name: String
        let offset: TimeInterval

        var id: String { name }
    }

    /// The marks, in the order they were recorded.
    private(set) var marks: [Mark] = []

    init(marks: [Mark] = []) {
        self.marks = marks
    }

    /// Records `name` at `offset` seconds after process start. A name
    /// recorded twice keeps its first offset: a launch has one first frame.
    mutating func record(_ name: String, at offset: TimeInterval) {
        guard !marks.contains(where: { $0.name == name }) else { return }
        marks.append(Mark(name: name, offset: max(0, offset)))
    }

    /// The offset of `name`, when recorded.
    func offset(of name: String) -> TimeInterval? {
        marks.first { $0.name == name }?.offset
    }

    /// The offset of the latest mark, or zero.
    var totalDuration: TimeInterval {
        marks.map(\.offset).max() ?? 0
    }

    /// The names ZynSign records. Fixed so two launches compare like for like.
    enum Milestone {
        static let environmentReady = "Environment ready"
        static let firstFrame = "First frame"
        static let essentialWorkDone = "Essential launch work done"
        static let deferredWorkStarted = "Deferred work started"
        static let deferredWorkDone = "Deferred work done"
    }
}
