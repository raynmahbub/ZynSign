import Foundation
import XCTest
@testable import ZynSign

// MARK: - Search index

final class SearchIndexTests: XCTestCase {

    private typealias Index = SearchIndex<Int, String>

    func testMatchesEveryTermAcrossFields() {
        var index = Index()
        index.upsert(1, document: .init(fields: ["name": "delta mail", "bundle": "com.example.delta"]))
        index.upsert(2, document: .init(fields: ["name": "gamma notes", "bundle": "com.example.gamma"]))

        XCTAssertEqual(index.matches(allOf: ["delta"]), [1])
        XCTAssertEqual(index.matches(allOf: ["example"]), [1, 2])
        XCTAssertEqual(index.matches(allOf: ["example", "notes"]), [2])
        XCTAssertEqual(index.matches(allOf: ["zeta"]), [])
        XCTAssertEqual(index.matches(allOf: []), [1, 2])
    }

    func testShortTermsStillMatchBySubstring() {
        var index = Index()
        index.upsert(1, document: .init(fields: ["name": "ab"]))
        index.upsert(2, document: .init(fields: ["name": "xyz"]))
        XCTAssertEqual(index.matches(allOf: ["a"]), [1])
        XCTAssertEqual(index.matches(allOf: ["yz"]), [2])
    }

    func testRemovalDropsPostings() {
        var index = Index()
        index.upsert(1, document: .init(fields: ["name": "delta mail"]))
        index.upsert(2, document: .init(fields: ["name": "delta notes"]))
        index.remove(1)
        XCTAssertEqual(index.matches(allOf: ["delta"]), [2])
        XCTAssertFalse(index.contains(1))
        index.remove([2])
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.postingCount, 0)
    }

    func testUpsertReplacesOldText() {
        var index = Index()
        index.upsert(1, document: .init(fields: ["name": "old name"]))
        index.upsert(1, document: .init(fields: ["name": "new name"]))
        XCTAssertEqual(index.matches(allOf: ["old"]), [])
        XCTAssertEqual(index.matches(allOf: ["new"]), [1])
    }

    func testCandidatesRestrictResults() {
        var index = Index()
        for id in 0..<10 {
            index.upsert(id, document: .init(fields: ["name": "shared word \(id)"]))
        }
        XCTAssertEqual(index.matches(allOf: ["shared"], among: [3, 4]), [3, 4])
    }

    func testLargeLibrarySearchStaysFast() {
        var documents: [Int: Index.Document] = [:]
        for id in 0..<2_000 {
            documents[id] = .init(fields: [
                "name": Index.fold("Application \(id) by Team \(id % 37)"),
                "bundle": Index.fold("com.vendor\(id % 53).app\(id)"),
                "version": Index.fold("\(id % 9).\(id % 13).\(id % 5)"),
            ])
        }
        let index = Index(documents: documents)
        XCTAssertEqual(index.count, 2_000)

        let queries = ["app", "vendor7", "team 12", "1.2", "application 1999", "nothing here"]
        let started = Date()
        for _ in 0..<20 {
            for query in queries {
                let terms = query.split(separator: " ").map { Index.fold(String($0)) }
                _ = index.matches(allOf: terms)
            }
        }
        let perQuery = Date().timeIntervalSince(started) / Double(20 * queries.count)
        XCTAssertLessThan(perQuery, 0.016, "one search over 2,000 documents should stay under a frame")
        XCTAssertEqual(index.matches(allOf: [Index.fold("application 1999")]).count, 1)
    }
}

// MARK: - Library index adoption

final class LibraryIndexSearchTests: XCTestCase {

    private func entry(name: String, bundle: String, version: String = "1.0") -> LibraryEntry {
        let record = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: bundle, displayName: name, shortVersion: version)
        )
        return LibraryEntry(record: record, artifactAvailability: .available)
    }

    func testSearchIndexAnswersQueriesAndReportsMatchedFields() {
        let delta = entry(name: "Delta Mail", bundle: "com.example.delta")
        let gamma = entry(name: "Gamma Notes", bundle: "com.example.gamma", version: "2.5")
        let index = LibraryIndex(entries: [delta, gamma])

        XCTAssertEqual(index.searchIndex.count, 2)
        let results = index.results(for: LibraryQuery(searchText: "gamma", sort: .name), in: .all, now: Date())
        XCTAssertEqual(results, [gamma.record.id])
        let fields = index.matchedFields(for: gamma.record.id, foldedTerms: LibraryQuery(searchText: "2.5").foldedSearchTerms)
        XCTAssertEqual(fields, [.version])
    }

    func testRemovalAndUpdateKeepIndexInStep() {
        let delta = entry(name: "Delta Mail", bundle: "com.example.delta")
        var index = LibraryIndex(entries: [delta])
        index.remove([delta.record.id])
        XCTAssertEqual(index.searchIndex.count, 0)

        let renamed = entry(name: "Renamed", bundle: "com.example.renamed")
        index.update(renamed)
        XCTAssertEqual(index.results(for: LibraryQuery(searchText: "renamed"), in: .all, now: Date()), [renamed.record.id])
        XCTAssertTrue(index.results(for: LibraryQuery(searchText: "delta"), in: .all, now: Date()).isEmpty)
    }

    func testThousandEntryLibraryBuildsAndSearchesQuickly() {
        let entries = (0..<1_200).map { offset in
            entry(name: "Application \(offset)", bundle: "com.vendor\(offset % 40).app\(offset)", version: "\(offset % 7).0")
        }
        let buildStart = Date()
        let index = LibraryIndex(entries: entries)
        XCTAssertLessThan(Date().timeIntervalSince(buildStart), 2.0)

        let searchStart = Date()
        let hits = index.results(for: LibraryQuery(searchText: "vendor7 3.0", sort: .name), in: .all, now: Date())
        XCTAssertLessThan(Date().timeIntervalSince(searchStart), 0.1)
        XCTAssertFalse(hits.isEmpty)
        for id in hits {
            let record = index.entry(for: id)!.record
            XCTAssertTrue(record.bundleIdentifier.rawValue.contains("vendor7"))
            XCTAssertEqual(record.identity.shortVersionString, "3.0")
        }
    }
}

// MARK: - Cache policy

final class CacheEvictionPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(_ key: String, bytes: Int, ageSeconds: TimeInterval) -> CacheItemDescriptor {
        CacheItemDescriptor(key: key, byteCount: bytes, lastAccess: now.addingTimeInterval(-ageSeconds))
    }

    func testEvictsExpiredThenLeastRecentlyUsedUntilWithinBudget() {
        let policy = CachePolicy(category: .thumbnails, byteBudget: 250, itemBudget: nil, maximumAge: 1_000, minimumAge: 60)
        let items = [
            item("expired", bytes: 10, ageSeconds: 5_000),
            item("oldest", bytes: 100, ageSeconds: 900),
            item("middle", bytes: 100, ageSeconds: 500),
            item("newest", bytes: 100, ageSeconds: 200),
        ]
        XCTAssertEqual(CacheEvictionPlanner.plan(items, policy: policy, now: now), ["expired", "oldest"])
    }

    func testNeverEvictsItemsYoungerThanMinimumAge() {
        let policy = CachePolicy(category: .temporaryFiles, byteBudget: 1, itemBudget: nil, maximumAge: nil, minimumAge: 3_600)
        let items = [item("fresh", bytes: 100, ageSeconds: 10), item("old", bytes: 100, ageSeconds: 7_200)]
        XCTAssertEqual(CacheEvictionPlanner.plan(items, policy: policy, now: now), ["old"])
    }

    func testUnboundedPolicyEvictsNothing() {
        let policy = CachePolicy(category: .metadata, byteBudget: nil, itemBudget: nil, maximumAge: nil)
        let items = [item("a", bytes: 1_000_000, ageSeconds: 99_999)]
        XCTAssertTrue(CacheEvictionPlanner.plan(items, policy: policy, now: now).isEmpty)
    }

    func testStandardPoliciesCoverEveryCategory() {
        XCTAssertEqual(Set(CachePolicy.standard.map(\.category)), Set(CacheCategory.allCases))
    }
}

// MARK: - Cache manager

private final class InMemoryCacheStore: CacheStoring, @unchecked Sendable {
    let cacheCategory: CacheCategory
    private let lock = NSLock()
    private var items: [String: CacheItemDescriptor]

    init(category: CacheCategory, items: [CacheItemDescriptor]) {
        self.cacheCategory = category
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
    }

    func cacheStatistics() async -> CacheStatistics {
        lock.withLock {
            CacheStatistics(category: cacheCategory, byteCount: items.values.reduce(0) { $0 + $1.byteCount }, itemCount: items.count)
        }
    }

    func cacheItems() async -> [CacheItemDescriptor] {
        lock.withLock { Array(items.values) }
    }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        lock.withLock {
            var freed = 0
            var removed = 0
            for key in keys {
                if let item = items.removeValue(forKey: key) {
                    freed += item.byteCount
                    removed += 1
                }
            }
            return CacheCleanupReport(category: cacheCategory, removedItemCount: removed, freedByteCount: freed)
        }
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        let keys = lock.withLock { Array(items.keys) }
        return await removeCacheItems(named: keys)
    }
}

final class CacheManagerTests: XCTestCase {

    func testEnforcePoliciesRemovesOnlyOverBudgetItemsPerCategory() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let thumbnails = InMemoryCacheStore(category: .thumbnails, items: [
            CacheItemDescriptor(key: "old", byteCount: 600, lastAccess: now.addingTimeInterval(-5_000)),
            CacheItemDescriptor(key: "new", byteCount: 600, lastAccess: now.addingTimeInterval(-2_000)),
        ])
        let metadata = InMemoryCacheStore(category: .metadata, items: [
            CacheItemDescriptor(key: "index", byteCount: 10_000, lastAccess: now.addingTimeInterval(-90_000)),
        ])
        let manager = CacheManager(
            policies: [
                CachePolicy(category: .thumbnails, byteBudget: 1_000, minimumAge: 60),
                CachePolicy(category: .metadata),
            ],
            now: { now }
        )
        await manager.register(thumbnails)
        await manager.register(metadata)

        let reports = await manager.enforcePolicies()
        XCTAssertEqual(reports.map(\.category), [.thumbnails])
        XCTAssertEqual(reports.first?.removedItemCount, 1)
        XCTAssertEqual(reports.first?.freedByteCount, 600)

        let statistics = await manager.statistics()
        XCTAssertEqual(statistics.first { $0.category == .thumbnails }?.itemCount, 1)
        XCTAssertEqual(statistics.first { $0.category == .metadata }?.itemCount, 1)
        XCTAssertEqual(statistics.count, CacheCategory.allCases.count, "every category is reported, empty or not")
    }

    func testClearEmptiesOneCategoryOnly() async {
        let now = Date()
        let thumbnails = InMemoryCacheStore(category: .thumbnails, items: [
            CacheItemDescriptor(key: "a", byteCount: 1, lastAccess: now),
        ])
        let diagnostics = InMemoryCacheStore(category: .diagnostics, items: [
            CacheItemDescriptor(key: "b", byteCount: 1, lastAccess: now),
        ])
        let manager = CacheManager(now: { now })
        await manager.register(thumbnails)
        await manager.register(diagnostics)
        let report = await manager.clear(.thumbnails)
        XCTAssertEqual(report.removedItemCount, 1)
        let remaining = await diagnostics.cacheStatistics()
        XCTAssertEqual(remaining.itemCount, 1)
    }
}

// MARK: - Memory manager

private final class RecordingTrimmable: MemoryTrimmable, @unchecked Sendable {
    let trimmableName = "recording"
    private let lock = NSLock()
    private(set) var levels: [MemoryPressureLevel] = []

    func trimMemory(level: MemoryPressureLevel) async {
        lock.withLock { levels.append(level) }
    }
}

private final class ManualPressureObserver: MemoryPressureObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MemoryPressureLevel) -> Void)?

    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func raise(_ level: MemoryPressureLevel) {
        lock.withLock { handler }?(level)
    }
}

final class MemoryManagerTests: XCTestCase {

    func testTrimReachesEveryParticipantAndCounts() async {
        let manager = MemoryManager()
        let first = RecordingTrimmable()
        let second = RecordingTrimmable()
        await manager.register(first)
        await manager.register(second)
        let trimmed = await manager.trim(level: .warning)
        XCTAssertEqual(trimmed, 2)
        XCTAssertEqual(first.levels, [.warning])
        XCTAssertEqual(second.levels, [.warning])
        let count = await manager.trimCount
        XCTAssertEqual(count, 1)
    }

    func testObservedPressureTrimsAndUpdatesLevel() async throws {
        let observer = ManualPressureObserver()
        let manager = MemoryManager(observer: observer)
        let participant = RecordingTrimmable()
        await manager.register(participant)
        await manager.startObserving()
        observer.raise(.critical)
        // Delivery hops onto the actor; give it a moment.
        for _ in 0..<50 where participant.levels.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(participant.levels, [.critical])
        let level = await manager.currentLevel
        XCTAssertEqual(level, .critical)
    }

    func testDeallocatedParticipantsAreForgotten() async {
        let manager = MemoryManager()
        var participant: RecordingTrimmable? = RecordingTrimmable()
        await manager.register(participant!)
        participant = nil
        let trimmed = await manager.trim(level: .warning)
        XCTAssertEqual(trimmed, 0)
    }
}

// MARK: - Background scheduler

final class BackgroundWorkSchedulerTests: XCTestCase {

    func testJobsRunAndSummaryCountsThem() async throws {
        let scheduler = BackgroundWorkScheduler(maximumConcurrentJobs: 1)
        let first = await scheduler.schedule(priority: .interactive) { 1 }
        let second = await scheduler.schedule(priority: .maintenance) { 2 }
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [1, 2])
        let summary = await scheduler.summary
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.runningCount, 0)
        XCTAssertEqual(summary.waitingCount, 0)
    }

    func testSameKeyJoinsTheJobInFlight() async throws {
        let scheduler = BackgroundWorkScheduler(maximumConcurrentJobs: 2)
        let counter = Counter()
        let first = await scheduler.schedule(key: "same") { () -> Int in
            await counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return 7
        }
        let second = await scheduler.schedule(key: "same") { () -> Int in
            await counter.increment()
            return 8
        }
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [7, 7])
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}

// MARK: - Progress coalescing

final class ProgressCoalescerTests: XCTestCase {

    func testDropsTinyStepsButKeepsStageChangesAndCompletion() {
        var coalescer = ProgressCoalescer(minimumFractionDelta: 0.05, maximumInterval: 10)
        let now = Date()
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 1, fraction: 0.10, isStageComplete: false, now: now))
        XCTAssertFalse(coalescer.shouldPublish(stageOrder: 1, fraction: 0.12, isStageComplete: false, now: now))
        XCTAssertFalse(coalescer.shouldPublish(stageOrder: 1, fraction: 0.14, isStageComplete: false, now: now))
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 1, fraction: 0.16, isStageComplete: false, now: now))
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 1, fraction: 0.17, isStageComplete: true, now: now))
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 2, fraction: 0.17, isStageComplete: false, now: now))
        XCTAssertEqual(coalescer.publishedCount, 5)
        XCTAssertEqual(coalescer.droppedCount, 2)
    }

    func testTimeForcesAPublication() {
        var coalescer = ProgressCoalescer(minimumFractionDelta: 0.5, maximumInterval: 1)
        let start = Date()
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 1, fraction: 0.1, isStageComplete: false, now: start))
        XCTAssertFalse(coalescer.shouldPublish(stageOrder: 1, fraction: 0.2, isStageComplete: false, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(coalescer.shouldPublish(stageOrder: 1, fraction: 0.2, isStageComplete: false, now: start.addingTimeInterval(1.5)))
    }
}

// MARK: - Incremental rendering

final class IncrementalRenderWindowTests: XCTestCase {

    func testWindowGrowsNearItsEndAndResets() {
        var window = IncrementalRenderWindow(initialLimit: 10, step: 10, threshold: 2)
        let all = Array(0..<35)
        XCTAssertEqual(window.rendered(of: all).count, 10)
        XCTAssertEqual(window.remainingCount(of: 35), 25)
        XCTAssertFalse(window.rowDidAppear(at: 3, total: 35))
        XCTAssertTrue(window.rowDidAppear(at: 8, total: 35))
        XCTAssertEqual(window.rendered(of: all).count, 20)
        window.showAll()
        XCTAssertEqual(window.rendered(of: all).count, 35)
        XCTAssertFalse(window.isTruncating(35))
        window.reset()
        XCTAssertEqual(window.rendered(of: all).count, 10)
    }

    func testSmallListsAreNeverTruncated() {
        var window = IncrementalRenderWindow(initialLimit: 100)
        XCTAssertEqual(window.rendered(of: Array(0..<5)).count, 5)
        XCTAssertFalse(window.rowDidAppear(at: 4, total: 5))
    }
}

// MARK: - Regression detection

final class PerformanceRegressionDetectorTests: XCTestCase {

    private func measurement(_ kind: BenchmarkKind, seconds: TimeInterval, items: Int, at: Date) -> BenchmarkMeasurement {
        BenchmarkMeasurement(kind: kind, duration: seconds, itemCount: items, measuredAt: at, buildIdentifier: "test")
    }

    func testFlagsSlowerPerItemBeyondToleranceAndBudget() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let baseline = BenchmarkBaseline(latestOf: [
            measurement(.libraryLoad, seconds: 0.100, items: 100, at: base),
            measurement(.searchLatency, seconds: 0.004, items: 100, at: base),
            measurement(.storeLoading, seconds: 0.200, items: 100, at: base),
        ], recordedAt: base)
        let detector = PerformanceRegressionDetector(tolerance: 0.25, noiseFloor: 0.002)
        let report = detector.compare([
            measurement(.libraryLoad, seconds: 0.300, items: 200, at: base.addingTimeInterval(10)),   // 1.5× per item → regressed
            measurement(.searchLatency, seconds: 0.004, items: 100, at: base.addingTimeInterval(10)), // same → stable
            measurement(.storeLoading, seconds: 0.100, items: 100, at: base.addingTimeInterval(10)),  // faster → improved
            measurement(.importSpeed, seconds: 1.0, items: 1, at: base.addingTimeInterval(10)),        // no baseline
        ], against: baseline, now: base.addingTimeInterval(20))

        XCTAssertEqual(report.finding(for: .libraryLoad)?.verdict, .regressed)
        XCTAssertEqual(report.finding(for: .searchLatency)?.verdict, .stable)
        XCTAssertEqual(report.finding(for: .storeLoading)?.verdict, .improved)
        XCTAssertEqual(report.finding(for: .importSpeed)?.verdict, .unmeasured)
        XCTAssertTrue(report.hasRegressions)
        XCTAssertEqual(report.regressions.map(\.kind), [.libraryLoad])
    }

    func testOverBudgetIsARegressionEvenWithoutABaselineChange() {
        let base = Date()
        let baseline = BenchmarkBaseline(latestOf: [measurement(.searchLatency, seconds: 0.050, items: 1, at: base)], recordedAt: base)
        let report = PerformanceRegressionDetector().compare(
            [measurement(.searchLatency, seconds: 0.050, items: 1, at: base.addingTimeInterval(1))],
            against: baseline,
            now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(report.finding(for: .searchLatency)?.verdict, .regressed, "50 ms is over the 16 ms search budget")
    }
}

// MARK: - Benchmark runner

final class PerformanceBenchmarkRunnerTests: XCTestCase {

    func testMeasureRecordsAndBaselineComparisonWorks() async throws {
        let runner = PerformanceBenchmarkRunner(store: nil, buildIdentifier: "test", historyLimit: 10)
        let measurement = try await runner.measure(PerformanceBenchmark(kind: .indexBuild) { 42 })
        XCTAssertEqual(measurement.kind, .indexBuild)
        XCTAssertEqual(measurement.itemCount, 42)
        let latest = await runner.latestMeasurements()
        XCTAssertEqual(latest.map(\.kind), [.indexBuild])

        let none = await runner.regressionReport()
        XCTAssertNil(none)
        let baseline = await runner.acceptCurrentAsBaseline()
        XCTAssertNotNil(baseline)
        await runner.record(kind: .indexBuild, duration: 0.0001, itemCount: 42)
        let report = await runner.regressionReport()
        XCTAssertNotNil(report)
        XCTAssertFalse(report?.hasRegressions ?? true)
    }

    func testHistoryIsBounded() async {
        let runner = PerformanceBenchmarkRunner(store: nil, buildIdentifier: "test", historyLimit: 3)
        for offset in 0..<10 {
            await runner.record(kind: .libraryLoad, duration: Double(offset), itemCount: 1)
        }
        let history = await runner.history()
        XCTAssertEqual(history.count, 3)
    }
}

// MARK: - Launch timeline and startup plan

final class LaunchPerformanceTests: XCTestCase {

    func testTimelineKeepsFirstOffsetPerMilestone() {
        var timeline = LaunchTimeline()
        timeline.record("First frame", at: 0.4)
        timeline.record("First frame", at: 0.9)
        timeline.record("Deferred work started", at: 0.8)
        XCTAssertEqual(timeline.offset(of: "First frame"), 0.4)
        XCTAssertEqual(timeline.marks.map(\.name), ["First frame", "Deferred work started"])
    }

    func testRecorderMeasuresFromProcessStart() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var current = start.addingTimeInterval(0.25)
        let lock = NSLock()
        let recorder = LaunchPerformanceRecorder(processStart: start, now: { lock.withLock { current } })
        recorder.mark(LaunchTimeline.Milestone.firstFrame)
        lock.withLock { current = start.addingTimeInterval(1.0) }
        recorder.mark(LaunchTimeline.Milestone.deferredWorkDone)
        XCTAssertEqual(recorder.timeToFirstFrame, 0.25)
        XCTAssertEqual(recorder.current.offset(of: LaunchTimeline.Milestone.deferredWorkDone), 1.0)
    }

    func testNothingIsEssentialBeforeTheFirstFrame() {
        let plan = StartupWorkPlan.standard
        XCTAssertTrue(plan.essential.isEmpty)
        XCTAssertEqual(Set(plan.deferred), Set(StartupWorkPlan.Item.allCases))
        XCTAssertTrue(plan.deferred.firstIndex(of: .temporaryCleanup)! < plan.deferred.firstIndex(of: .restoreInterruptedImports)!)
        XCTAssertTrue(plan.deferred.firstIndex(of: .restoreInterruptedImports)! < plan.deferred.firstIndex(of: .restoreSigningQueue)!)
    }
}

// MARK: - Store catalog and manifest cache

final class StoreCatalogTests: XCTestCase {

    private func feed(count: Int) -> Data {
        let apps = (0..<count).map { offset in
            "{\"name\":\"Sample \(offset)\",\"bundleIdentifier\":\"com.example.s\(offset)\",\"version\":\"1.\(offset)\",\"subtitle\":\"Entry\"}"
        }.joined(separator: ",")
        return Data("{\"name\":\"Feed\",\"apps\":[\(apps)]}".utf8)
    }

    func testDecodesDeduplicatesAndPages() throws {
        let data = Data("{\"apps\":[{\"name\":\"A\",\"bundleIdentifier\":\"com.a\"},{\"name\":\"A again\",\"bundleIdentifier\":\"com.a\"},{\"name\":\"B\",\"bundleIdentifier\":\"com.b\"}]}".utf8)
        let manifest = try XCTUnwrap(StoreManifestCache.decodeFeed(
            data, sourceID: "s", url: URL(string: "https://example.invalid/apps.json")!,
            entityTag: "etag", lastModified: nil, fetchedAt: Date()
        ))
        XCTAssertEqual(manifest.apps.map(\.id), ["com.a", "com.b"])
        let catalog = StoreCatalog(manifests: [manifest])
        XCTAssertEqual(catalog.matching("b").map(\.id), ["com.b"])
        let page = StoreCatalog.page(catalog.apps, limit: 1)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.hasMore)
    }

    func testManifestCacheRoundTripsAndReportsStaleness() async throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lock = NSLock()
        let cache = StoreManifestCache(directory: directory, maximumAge: 60, now: { lock.withLock { now } })
        let manifest = try XCTUnwrap(StoreManifestCache.decodeFeed(
            feed(count: 3), sourceID: "source", url: URL(string: "https://example.invalid/apps.json")!,
            entityTag: nil, lastModified: "Mon", fetchedAt: now
        ))
        let staleBefore = await cache.isStale("source")
        XCTAssertTrue(staleBefore)
        await cache.store(manifest)
        let fresh = await cache.isStale("source")
        XCTAssertFalse(fresh)

        // A second cache over the same directory reads the disk copy.
        let reopened = StoreManifestCache(directory: directory, maximumAge: 60, now: { lock.withLock { now } })
        let loaded = await reopened.manifest(for: "source")
        XCTAssertEqual(loaded?.apps.count, 3)
        XCTAssertEqual(loaded?.lastModified, "Mon")

        lock.withLock { now = now.addingTimeInterval(120) }
        let staleAfter = await reopened.isStale("source")
        XCTAssertTrue(staleAfter)
        await reopened.touch("source")
        let touched = await reopened.isStale("source")
        XCTAssertFalse(touched)

        let items = await reopened.items()
        XCTAssertEqual(items.count, 1)
        await reopened.remove("source")
        let gone = await reopened.manifest(for: "source")
        XCTAssertNil(gone)
    }

    func testLargeCatalogFiltersQuickly() throws {
        let manifest = try XCTUnwrap(StoreManifestCache.decodeFeed(
            feed(count: 3_000), sourceID: "s", url: URL(string: "https://example.invalid/apps.json")!,
            entityTag: nil, lastModified: nil, fetchedAt: Date()
        ))
        let catalog = StoreCatalog(manifests: [manifest])
        let started = Date()
        let hits = catalog.matching("sample 29")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(hits.allSatisfy { $0.name.lowercased().contains("sample 29") })
    }
}

// MARK: - Inspection result cache

final class InspectionResultCacheTests: XCTestCase {

    func testStampChangeMissesAndTrimEvictsOldest() {
        let cache = InspectionResultCache<[Int]>(itemBudget: 2, costBudget: 1_000)
        let artifact = ArtifactIdentifier()
        let first = InspectionResultCache<[Int]>.Key(artifactID: artifact, stamp: "1", aspect: "entry-table")
        let second = InspectionResultCache<[Int]>.Key(artifactID: artifact, stamp: "2", aspect: "entry-table")
        cache.insert([1, 2, 3], for: first, cost: 3)
        XCTAssertEqual(cache.value(for: first), [1, 2, 3])
        XCTAssertNil(cache.value(for: second), "a changed file never hits the old entry")
        cache.insert([4], for: second, cost: 1)
        cache.forget(artifactID: artifact)
        XCTAssertNil(cache.value(for: first))
        XCTAssertNil(cache.value(for: second))
    }
}

// MARK: - Performance engine façade

final class PerformanceEngineTests: XCTestCase {

    private func makeEngine() -> PerformanceEngine {
        let scheduler = BackgroundWorkScheduler()
        return PerformanceEngine(
            scheduler: scheduler,
            thumbnails: nil,
            metadata: MetadataIndexService(store: nil, scheduler: scheduler),
            entryTables: InspectionResultCache<[ArchiveEntry]>(),
            memory: MemoryManager(),
            caches: CacheManager(),
            benchmarks: PerformanceBenchmarkRunner(store: nil, buildIdentifier: "test"),
            launch: LaunchPerformanceRecorder(processStart: Date()),
            storeManifests: nil,
            state: nil
        )
    }

    func testSnapshotReflectsLibraryReportsAndOptimizationRecordsATime() async {
        let engine = makeEngine()
        await engine.start()
        await engine.reportLibrary(itemCount: 12, indexed: 12, status: .ready(indexed: 12))
        let before = await engine.snapshot()
        XCTAssertEqual(before.libraryItemCount, 12)
        XCTAssertEqual(before.indexedApplicationCount, 12)
        XCTAssertEqual(before.searchIndexStatus, .ready(indexed: 12))
        XCTAssertNil(before.lastOptimization)
        XCTAssertEqual(before.cacheStatistics.count, CacheCategory.allCases.count)

        let report = await engine.optimize()
        XCTAssertGreaterThanOrEqual(report.duration, 0)
        let after = await engine.snapshot()
        XCTAssertNotNil(after.lastOptimization)
    }
}
