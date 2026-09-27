import Foundation
import Combine

/// The presentation state behind Settings → Advanced → Performance.
///
/// The model is a window into the Performance Engine: it asks for a
/// snapshot when the page appears and after every action, runs the
/// benchmark suite the composition supplied, and phrases every figure for
/// the table. It owns no cache and no policy; each action is one engine
/// call, and the page shows what the engine reports afterwards rather
/// than what the action intended.
@MainActor
final class PerformanceDashboardModel: ObservableObject {

    /// One row of the diagnostics table.
    typealias Metric = PerformanceMetric

    /// A confirmation the page asks for before a destructive-looking action.
    enum PendingAction: Identifiable, Equatable {
        case clearCache(CacheCategory)
        case clearAllCaches
        case clearBenchmarkHistory

        var id: String {
            switch self {
            case .clearCache(let category): return "clear-\(category.rawValue)"
            case .clearAllCaches: return "clear-all"
            case .clearBenchmarkHistory: return "clear-benchmarks"
            }
        }

        var title: String {
            switch self {
            case .clearCache(let category): return "Clear \(category.displayName)?"
            case .clearAllCaches: return "Clear All Caches?"
            case .clearBenchmarkHistory: return "Clear Benchmark History?"
            }
        }

        var message: String {
            switch self {
            case .clearCache(let category):
                return category.explanation + " Imported applications are not touched."
            case .clearAllCaches:
                return "Every cache category is emptied. Everything here is derived data and is rebuilt as needed. Imported applications, signed artifacts, and history are not touched."
            case .clearBenchmarkHistory:
                return "Every recorded measurement is removed. The accepted baseline is kept."
            }
        }
    }

    @Published private(set) var snapshot: PerformanceSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isOptimizing = false
    @Published private(set) var isBenchmarking = false
    @Published private(set) var benchmarkProgress: (completed: Int, total: Int)?
    @Published private(set) var message: String?
    @Published var pendingAction: PendingAction?

    private let engine: PerformanceEngine?
    private let benchmarkSuite: () -> [PerformanceBenchmark]
    private var hasLoaded = false

    init(engine: PerformanceEngine?, benchmarkSuite: @escaping () -> [PerformanceBenchmark] = { [] }) {
        self.engine = engine
        self.benchmarkSuite = benchmarkSuite
    }

    /// Whether the engine is composed. Without it the page says so.
    var isAvailable: Bool { engine != nil }

    /// Whether any action is running.
    var isBusy: Bool { isRefreshing || isOptimizing || isBenchmarking }

    // MARK: - Loading

    /// Loads the snapshot when the page appears.
    func load() async {
        if hasLoaded { await refresh(); return }
        hasLoaded = true
        await refresh()
    }

    /// Asks the engine for a fresh snapshot.
    func refresh() async {
        guard let engine else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await engine.snapshot()
    }

    // MARK: - Actions

    /// Runs one optimization pass and reports what it did.
    func optimize() async {
        guard let engine, !isOptimizing else { return }
        isOptimizing = true
        defer { isOptimizing = false }
        let report = await engine.optimize()
        message = Self.describe(report)
        await refresh()
    }

    /// Runs the benchmark suite, one benchmark at a time.
    func runBenchmarks() async {
        guard let engine, !isBenchmarking else { return }
        let suite = benchmarkSuite()
        guard !suite.isEmpty else {
            message = "No benchmarks are composed in this build."
            return
        }
        isBenchmarking = true
        benchmarkProgress = (0, suite.count)
        defer {
            isBenchmarking = false
            benchmarkProgress = nil
        }
        var failures = 0
        for (offset, benchmark) in suite.enumerated() {
            benchmarkProgress = (offset, suite.count)
            do {
                _ = try await engine.benchmarks.measure(benchmark)
            } catch {
                failures += 1
            }
        }
        benchmarkProgress = (suite.count, suite.count)
        await refresh()
        if failures > 0 {
            message = "\(suite.count - failures) of \(suite.count) benchmarks ran; \(failures) could not."
        } else if let report = snapshot.regressionReport, report.hasRegressions {
            let names = report.regressions.map { $0.kind.displayName }.joined(separator: ", ")
            message = "Benchmarks finished. Regressed: \(names)."
        } else {
            message = "Benchmarks finished. No regressions against the baseline."
        }
    }

    /// Freezes the latest measurements as the baseline.
    func acceptBaseline() async {
        guard let engine else { return }
        if await engine.benchmarks.acceptCurrentAsBaseline() != nil {
            message = "Baseline recorded from the latest measurements."
        } else {
            message = "Run the benchmarks first; there is nothing to accept yet."
        }
        await refresh()
    }

    /// Forgets the baseline.
    func clearBaseline() async {
        guard let engine else { return }
        await engine.benchmarks.clearBaseline()
        message = "Baseline cleared."
        await refresh()
    }

    /// Trims memory at the warning level, as the system would.
    func trimMemory() async {
        guard let engine else { return }
        let count = await engine.memory.trim(level: .warning)
        message = count == 1 ? "1 cache trimmed." : "\(count) caches trimmed."
        await refresh()
    }

    /// Runs the confirmed action.
    func perform(_ action: PendingAction) async {
        guard let engine else { return }
        switch action {
        case .clearCache(let category):
            let report = await engine.caches.clear(category)
            message = Self.describe(report)
        case .clearAllCaches:
            let reports = await engine.caches.clearAll()
            let freed = reports.reduce(0) { $0 + $1.freedByteCount }
            let removed = reports.reduce(0) { $0 + $1.removedItemCount }
            message = "Removed \(removed) cached items, freeing \(Self.formatted(bytes: freed))."
        case .clearBenchmarkHistory:
            await engine.benchmarks.clearHistory()
            message = "Benchmark history cleared."
        }
        await refresh()
    }

    /// Clears the message once shown.
    func clearMessage() {
        message = nil
    }

    // MARK: - Rows

    /// The fixed metrics table, in the order the page shows them.
    var metrics: [Metric] {
        let snapshot = snapshot
        return [
            Metric(id: "library", title: "Library Items", value: "\(snapshot.libraryItemCount)"),
            Metric(id: "indexed", title: "Indexed Apps", value: "\(snapshot.indexedApplicationCount)"),
            Metric(id: "cache", title: "Cache Size", value: Self.formatted(bytes: snapshot.totalCacheByteCount), detail: "Every category together."),
            Metric(
                id: "thumbnails",
                title: "Thumbnail Cache",
                value: Self.formatted(bytes: snapshot.thumbnailStatistics.byteCount),
                detail: "\(snapshot.thumbnailStatistics.itemCount) on disk · \(snapshot.thumbnailStatistics.memoryItemCount) in memory"
            ),
            Metric(id: "search", title: "Search Index Status", value: snapshot.searchIndexStatus.displayText),
            Metric(id: "optimized", title: "Last Optimization", value: snapshot.lastOptimization.map(Self.formatted(date:)) ?? "Never"),
            Metric(id: "memory", title: "Memory Pressure", value: snapshot.memoryPressure.displayName, detail: "\(snapshot.memoryTrimCount) trims this launch"),
            Metric(
                id: "work",
                title: "Background Work",
                value: "\(snapshot.backgroundWork.runningCount) running · \(snapshot.backgroundWork.waitingCount) waiting",
                detail: "\(snapshot.backgroundWork.completedCount) completed this launch"
            ),
        ]
    }

    /// The launch timeline as rows, when recorded.
    var launchMetrics: [Metric] {
        guard let launch = snapshot.launch else { return [] }
        return launch.marks.map { mark in
            Metric(id: "launch-\(mark.name)", title: mark.name, value: Self.formatted(duration: mark.offset))
        }
    }

    /// The latest benchmark of each kind as rows, with the regression
    /// verdict where a baseline exists.
    var benchmarkMetrics: [Metric] {
        snapshot.recentBenchmarks.map { measurement in
            let finding = snapshot.regressionReport?.finding(for: measurement.kind)
            var detail = "\(measurement.itemCount) items · \(measurement.kind.explanation)"
            if let finding, let baseline = finding.baseline {
                detail = "\(finding.verdict.displayName) · baseline \(Self.formatted(duration: baseline))/item · \(measurement.kind.explanation)"
            } else if let finding {
                detail = "\(finding.verdict.displayName) · \(measurement.kind.explanation)"
            }
            return Metric(
                id: "benchmark-\(measurement.kind.rawValue)",
                title: measurement.kind.displayName,
                value: Self.formatted(duration: measurement.duration),
                detail: detail
            )
        }
    }

    // MARK: - Formatting

    static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func formatted(duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(format: "%.0f µs", duration * 1_000_000)
        }
        if duration < 1 {
            return String(format: "%.1f ms", duration * 1_000)
        }
        return String(format: "%.2f s", duration)
    }

    static func formatted(date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func describe(_ report: PerformanceOptimizationReport) -> String {
        let removed = report.cacheReports.reduce(0) { $0 + $1.removedItemCount }
        if removed == 0 {
            return "Optimized in \(formatted(duration: report.duration)). Caches were already within policy."
        }
        return "Optimized in \(formatted(duration: report.duration)): removed \(removed) cached items, freeing \(formatted(bytes: report.freedByteCount))."
    }

    static func describe(_ report: CacheCleanupReport) -> String {
        if report.removedItemCount == 0 && report.skippedItemCount == 0 {
            return "\(report.category.displayName) was already empty."
        }
        var text = "Removed \(report.removedItemCount) \(report.category.displayName.lowercased()) items, freeing \(formatted(bytes: report.freedByteCount))."
        if report.skippedItemCount > 0 {
            text += " \(report.skippedItemCount) left alone."
        }
        return text
    }
}
