import Foundation

/// Where benchmark measurements and the accepted baseline are kept.
protocol PerformanceBaselineStore: Sendable {
    func loadBaseline() throws -> BenchmarkBaseline?
    func saveBaseline(_ baseline: BenchmarkBaseline) throws
    func removeBaseline() throws
    func loadMeasurements() throws -> [BenchmarkMeasurement]
    func saveMeasurements(_ measurements: [BenchmarkMeasurement]) throws
}

/// One benchmark the suite can run: a name and an operation that returns
/// how many items it covered.
struct PerformanceBenchmark: Sendable {
    let kind: BenchmarkKind
    let operation: @Sendable () async throws -> Int

    init(kind: BenchmarkKind, operation: @escaping @Sendable () async throws -> Int) {
        self.kind = kind
        self.operation = operation
    }
}

/// Times operations, keeps a bounded history of measurements, and compares
/// them against the accepted baseline.
///
/// **Measuring.** `measure(_:)` runs one benchmark once and records it.
/// `record(kind:duration:itemCount:)` accepts a measurement taken in
/// place — the library model timing its own read, the search timing its
/// own answer — so ordinary use produces the same figures a benchmark run
/// does. Every measurement carries the build it was taken on.
///
/// **History.** The most recent `historyLimit` measurements are kept,
/// persisted through the store, and shown on the Performance page.
///
/// **Baseline.** `acceptCurrentAsBaseline()` freezes the latest
/// measurement of each kind as the standard to hold; `regressionReport()`
/// compares the latest measurements against it with the detector. A
/// baseline from another build is still compared — a regression across
/// builds is exactly what the developer wants to see — and named as such
/// in the finding.
actor PerformanceBenchmarkRunner {

    private let store: (any PerformanceBaselineStore)?
    private let detector: PerformanceRegressionDetector
    private let buildIdentifier: String
    private let now: @Sendable () -> Date
    private let historyLimit: Int

    private var measurements: [BenchmarkMeasurement] = []
    private var baseline: BenchmarkBaseline?
    private var hasLoaded = false

    init(
        store: (any PerformanceBaselineStore)?,
        detector: PerformanceRegressionDetector = PerformanceRegressionDetector(),
        buildIdentifier: String,
        historyLimit: Int = 200,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.detector = detector
        self.buildIdentifier = buildIdentifier
        self.historyLimit = max(1, historyLimit)
        self.now = now
    }

    // MARK: - Measuring

    /// Runs `benchmark` once and records the measurement.
    @discardableResult
    func measure(_ benchmark: PerformanceBenchmark) async throws -> BenchmarkMeasurement {
        loadIfNeeded()
        let clock = ContinuousClock()
        let start = clock.now
        let itemCount = try await benchmark.operation()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return record(kind: benchmark.kind, duration: seconds, itemCount: itemCount)
    }

    /// Runs every benchmark in `suite`, in order, continuing past failures.
    /// Returns the measurements that succeeded.
    func run(_ suite: [PerformanceBenchmark]) async -> [BenchmarkMeasurement] {
        var results: [BenchmarkMeasurement] = []
        for benchmark in suite {
            if Task.isCancelled { break }
            if let measurement = try? await measure(benchmark) {
                results.append(measurement)
            }
        }
        return results
    }

    /// Records a measurement taken elsewhere.
    @discardableResult
    func record(kind: BenchmarkKind, duration: TimeInterval, itemCount: Int) -> BenchmarkMeasurement {
        loadIfNeeded()
        let measurement = BenchmarkMeasurement(
            kind: kind,
            duration: duration,
            itemCount: itemCount,
            measuredAt: now(),
            buildIdentifier: buildIdentifier
        )
        measurements.insert(measurement, at: 0)
        if measurements.count > historyLimit {
            measurements.removeLast(measurements.count - historyLimit)
        }
        try? store?.saveMeasurements(measurements)
        return measurement
    }

    // MARK: - Reading

    /// Every measurement kept, most recent first.
    func history() -> [BenchmarkMeasurement] {
        loadIfNeeded()
        return measurements
    }

    /// The latest measurement of each kind, in kind order.
    func latestMeasurements() -> [BenchmarkMeasurement] {
        loadIfNeeded()
        var latest: [BenchmarkKind: BenchmarkMeasurement] = [:]
        for measurement in measurements.reversed() {
            latest[measurement.kind] = measurement
        }
        return BenchmarkKind.allCases.compactMap { latest[$0] }
    }

    /// The accepted baseline, if any.
    func currentBaseline() -> BenchmarkBaseline? {
        loadIfNeeded()
        return baseline
    }

    /// The latest measurements compared against the baseline. `nil` when
    /// nothing has been measured.
    func regressionReport() -> PerformanceRegressionReport? {
        loadIfNeeded()
        let latest = latestMeasurements()
        guard !latest.isEmpty else { return nil }
        return detector.compare(latest, against: baseline, now: now())
    }

    // MARK: - Baseline

    /// Freezes the latest measurement of each kind as the baseline.
    @discardableResult
    func acceptCurrentAsBaseline() -> BenchmarkBaseline? {
        loadIfNeeded()
        let latest = latestMeasurements()
        guard !latest.isEmpty else { return nil }
        let accepted = BenchmarkBaseline(latestOf: latest, recordedAt: now())
        baseline = accepted
        try? store?.saveBaseline(accepted)
        return accepted
    }

    /// Forgets the baseline.
    func clearBaseline() {
        baseline = nil
        try? store?.removeBaseline()
    }

    /// Forgets every measurement. The baseline is kept.
    func clearHistory() {
        measurements.removeAll()
        try? store?.saveMeasurements([])
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let store else { return }
        measurements = (try? store.loadMeasurements()) ?? []
        baseline = try? store.loadBaseline()
    }
}
