import Foundation

/// Where the engine keeps the little state that outlives a launch and is
/// not a cache: when it last optimized.
protocol PerformanceStateStoring: Sendable {
    var lastOptimization: Date? { get }
    func setLastOptimization(_ date: Date?)
}

/// What one optimization pass did.
struct PerformanceOptimizationReport: Equatable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    let cacheReports: [CacheCleanupReport]
    let metadataEntriesFlushed: Int
    let memoryParticipantsTrimmed: Int

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    var freedByteCount: Int { cacheReports.reduce(0) { $0 + $1.freedByteCount } }
}

/// The Performance Engine: one owner for the machinery that keeps ZynSign
/// fast as the library grows, and one place the Performance page reads.
///
/// The engine adds no capability of its own. It composes the background
/// scheduler, the thumbnail cache, the metadata index, the shared entry-
/// table cache, the memory manager, the cache manager, the benchmark
/// runner, and the launch recorder, wires them together — caches register
/// as memory participants and as cache stores — and answers three
/// questions: what is the runtime picture (`snapshot()`), tidy everything
/// (`optimize()`), and how did the build do (`benchmarks`).
///
/// Every part is optional at composition so tests and lighter compositions
/// can build an engine over exactly the parts they exercise, and every
/// part is reachable so later versions can add a store, a benchmark, or a
/// participant without changing the engine's shape.
actor PerformanceEngine {

    let scheduler: BackgroundWorkScheduler
    let thumbnails: ThumbnailCache?
    let metadata: MetadataIndexService
    let entryTables: InspectionResultCache<[ArchiveEntry]>
    let memory: MemoryManager
    let caches: CacheManager
    let benchmarks: PerformanceBenchmarkRunner
    let launch: LaunchPerformanceRecorder
    let storeManifests: StoreManifestCache?

    private let state: (any PerformanceStateStoring)?
    private let now: @Sendable () -> Date

    /// The library's size and the search index's readiness, as the library
    /// model last reported them. The engine does not read the library
    /// itself; the model that owns the index tells it.
    private(set) var libraryItemCount = 0
    private(set) var searchIndexStatus: SearchIndexStatus = .empty
    private(set) var indexedApplicationCount = 0

    /// Whether `optimize()` is running, so a second request waits.
    private(set) var isOptimizing = false

    private var hasStarted = false

    init(
        scheduler: BackgroundWorkScheduler,
        thumbnails: ThumbnailCache?,
        metadata: MetadataIndexService,
        entryTables: InspectionResultCache<[ArchiveEntry]>,
        memory: MemoryManager,
        caches: CacheManager,
        benchmarks: PerformanceBenchmarkRunner,
        launch: LaunchPerformanceRecorder,
        storeManifests: StoreManifestCache? = nil,
        state: (any PerformanceStateStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.thumbnails = thumbnails
        self.metadata = metadata
        self.entryTables = entryTables
        self.memory = memory
        self.caches = caches
        self.benchmarks = benchmarks
        self.launch = launch
        self.storeManifests = storeManifests
        self.state = state
        self.now = now
    }

    // MARK: - Lifecycle

    /// Registers the caches with the memory and cache managers. Called once
    /// by the composition root after construction; idempotent.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let thumbnails {
            await memory.register(thumbnails)
            await caches.register(ThumbnailCacheStore(cacheCategory: .thumbnails, cache: thumbnails))
            await caches.register(ThumbnailCacheStore(cacheCategory: .screenshots, cache: thumbnails))
        }
        await memory.register(entryTables)
        if let storeManifests {
            await memory.register(StoreManifestTrimmable(cache: storeManifests))
        }
    }

    /// Begins reacting to the platform's memory pressure. Deferred launch
    /// work; not part of `start()` so composition stays side-effect free.
    func startMemoryObservation() async {
        await memory.startObserving()
    }

    // MARK: - Reports from the library

    /// The library model reports its size and its index's readiness here
    /// whenever they change.
    func reportLibrary(itemCount: Int, indexed: Int, status: SearchIndexStatus) {
        libraryItemCount = max(0, itemCount)
        indexedApplicationCount = max(0, indexed)
        searchIndexStatus = status
    }

    // MARK: - Snapshot

    /// The runtime picture the Performance page renders.
    func snapshot() async -> PerformanceSnapshot {
        let cacheStatistics = await caches.statistics()
        let recent = await benchmarks.latestMeasurements()
        let regression = await benchmarks.regressionReport()
        let memoryLevel = await memory.currentLevel
        let trimCount = await memory.trimCount
        let work = await scheduler.summary
        return PerformanceSnapshot(
            libraryItemCount: libraryItemCount,
            indexedApplicationCount: indexedApplicationCount,
            searchIndexStatus: searchIndexStatus,
            cacheStatistics: cacheStatistics,
            lastOptimization: state?.lastOptimization,
            recentBenchmarks: recent,
            regressionReport: regression,
            memoryPressure: memoryLevel,
            memoryTrimCount: trimCount,
            backgroundWork: work,
            launch: launch.current
        )
    }

    // MARK: - Optimization

    /// Tidies everything: flushes the metadata index, applies every cache
    /// policy, and trims memory at the warning level so what is on screen
    /// stays warm. Never removes an imported application — nothing it
    /// calls can.
    @discardableResult
    func optimize() async -> PerformanceOptimizationReport {
        while isOptimizing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        isOptimizing = true
        defer { isOptimizing = false }
        let started = now()
        let metadataCount = await metadata.current().count
        await metadata.flush()
        let cacheReports = await caches.enforcePolicies()
        let trimmed = await memory.trim(level: .warning)
        let finished = now()
        state?.setLastOptimization(finished)
        return PerformanceOptimizationReport(
            startedAt: started,
            finishedAt: finished,
            cacheReports: cacheReports,
            metadataEntriesFlushed: metadataCount,
            memoryParticipantsTrimmed: trimmed
        )
    }

    /// Applies cache policies in the background, coalesced, after work that
    /// grew a cache.
    func scheduleMaintenance() async {
        await scheduler.schedule(key: "performance.maintenance", priority: .maintenance) { [caches] in
            await caches.enforcePolicies()
        }
    }

    // MARK: - Removal

    /// Forgets everything derived from `artifactID`: thumbnails, cached
    /// entry tables. Called when the library removes an application.
    func forget(artifactID: ArtifactIdentifier) async {
        await thumbnails?.forget(artifactID: artifactID)
        entryTables.forget(artifactID: artifactID)
    }
}

// MARK: - Memory participants

extension ThumbnailCache: MemoryTrimmable {
    nonisolated var trimmableName: String { "Thumbnails" }
}

extension InspectionResultCache: MemoryTrimmable {
    var trimmableName: String { "Inspection results" }

    func trimMemory(level: MemoryPressureLevel) async {
        switch level {
        case .nominal: break
        case .warning: trim(toFraction: 0.5)
        case .critical: removeAll()
        }
    }
}

/// Lets the store's manifest cache take part in memory trimming.
final class StoreManifestTrimmable: MemoryTrimmable, Sendable {
    private let cache: StoreManifestCache

    init(cache: StoreManifestCache) {
        self.cache = cache
    }

    var trimmableName: String { "Store manifests" }

    func trimMemory(level: MemoryPressureLevel) async {
        guard level > .nominal else { return }
        await cache.trimMemory()
    }
}
