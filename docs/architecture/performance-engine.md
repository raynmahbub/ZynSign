# Performance Engine & Large Library Optimization

**Milestone:** Beta 2 · Step 25 · `0.9.0-beta.2`
**Entry point:** Settings → Advanced → **Performance** (hidden page, gated by `ReleaseFeature.performanceDashboard`)
**Status:** implemented; the optimizations themselves are ungated core behaviour, only the page is gated.

The Performance Engine makes ZynSign stay fast with a library of 1,000+
applications without changing the architecture: every piece is a Domain
value, an Application service behind a port, or a Platform adapter chosen in
`CompositionRoot`. Nothing here removes an imported application, a signed
artifact, a profile, or history — every cache is derived data under `Caches/`
and is rebuilt on demand.

## Components

| Layer | Type | Responsibility |
|---|---|---|
| Domain | `SearchIndex<ID, Field>` | Trigram postings + substring verification. Incremental `upsert`/`remove`, `matches(allOf:among:)`, generation counter. `SearchIndexStatus` (empty / building / ready / stale). |
| Domain | `CacheCategory`, `CachePolicy`, `CacheItemDescriptor`, `CacheStatistics`, `CacheCleanupReport`, `CacheEvictionPlanner` | Per-category budgets (bytes, items, max age, min age). Pure planner: expired first, then LRU until within budget; items younger than `minimumAge` are never chosen. |
| Domain | `PerformanceSnapshot`, `PerformanceMetric`, `MemoryPressureLevel`, `BackgroundWorkSummary`, `LaunchTimeline` | The page's model and the launch marks. |
| Domain | `BenchmarkKind`, `BenchmarkMeasurement`, `BenchmarkBaseline`, `PerformanceRegressionDetector`, `PerformanceRegressionReport` | Per-item comparison with a tolerance (25 %), a noise floor (2 ms), and an absolute budget per kind. |
| Domain | `ProgressCoalescer`, `IncrementalRenderWindow` | Publication policy for progress; the row window for long lists. |
| Application | `BackgroundWorkScheduler` (actor) | Keyed, prioritised (`interactive` / `maintenance`), bounded-concurrency jobs; the same key joins the job in flight. |
| Application | `ThumbnailCache` (actor), `ThumbnailKey`, `ThumbnailVariant`, `ThumbnailRendering`, `ThumbnailSourceProviding` | Three sizes; memory tier (byte budget, trimmed under pressure) over a disk tier; one render per key; originals read through `AppIconExtraction`. |
| Application | `MetadataIndex`, `MetadataIndexService`, `LibraryMetadata` | Name, version, bundle ID, developer, import date, signing state — persisted separately from archives, reconciled in the background by diff. |
| Application | `InspectionResultCache<Value>`, `CachingArtifactArchiveReaderProvider`, `ArtifactStampProviding` | Entry tables cached per `(artifact, file stamp, aspect)`; a changed or missing file never hits. Applied only to read-only library inspectors (icons, provenance, explorer, App Details, entry preview, binary inspector) — never to import or staging. |
| Application | `MemoryManager` (actor), `MemoryTrimmable`, `MemoryPressureObserving` | Registers trimmables weakly; trims on warning/critical; counts trims. |
| Application | `CacheManager` (actor), `CacheStoring` | One store per category; `statistics()`, `enforcePolicies()`, `clear(_:)`, `clearAll()`. |
| Application | `PerformanceBenchmarkRunner` (actor), `PerformanceBenchmark`, `PerformanceBaselineStore` | Measures or records; bounded history; baseline accept/clear; regression report. |
| Application | `LaunchPerformanceRecorder`, `StartupWorkPlan` | Marks from kernel process start; the ordered deferred plan (nothing essential before the first frame). |
| Application | `StoreManifestCache` (actor), `StoreSourceManifest`, `StoreCatalog`, `StoreFeedFetching` | Cached manifests with ETag/Last-Modified; stale-only refresh; indexed, paged catalog. |
| Application | `PerformanceEngine` (actor) | Façade: `start()`, `reportLibrary`, `snapshot()`, `optimize()`, `scheduleMaintenance()`, `forget(artifactID:)`. |
| Platform | `ImageIOThumbnailRenderer`, `SystemMemoryPressureObserver`, `FileArtifactStampProvider`, `FileMetadataIndexStore`, `FilePerformanceBaselineStore`, `UserDefaultsPerformanceStateStore`, `DirectoryCacheStore`, `TemporaryFilesCacheStore`, `StoreManifestCacheStore`, `CompositeCacheStore`, `URLSessionStoreFeedFetcher` | The adapters. |
| Presentation | `ThumbnailPipeline`, `ApplicationIconView`, `PerformanceDashboardModel`/`Section`, `LibraryRenderMoreRow`, `LibrarySkeletonRow`, `ZMotion` | Decoded-image sharing, the page, progressive rows, motion policy. |

## How each requirement is met

1. **Dashboard** — `PerformanceDashboardSection` polls `engine.snapshot()` on appear, on pull-to-refresh, and after each action. Rows: Library Items, Indexed Apps, Cache Size, Thumbnail Cache, Search Index Status, Last Optimization, Memory Pressure, Background Work; a Caches section with per-category size and clear; Benchmarks with verdicts; This Launch timeline.
2. **Large library rendering** — `List`/`LazyVGrid` with stable `ApplicationRecordIdentifier` identity, plus `IncrementalRenderWindow` (120 rows, +120 near the end, reset on query change) and `LibraryRenderMoreRow` skeletons with "Show all".
3. **Instant search** — `LibraryIndex.searchIndex` over name, bundle ID, version, file name, developer, team, collection; `update`/`remove`/`setOrganization`/`mergeProvenance` touch only affected documents; a full reload rebuilds. Status is reported as `building(indexed:total:)` while provenance resolves.
4. **Thumbnail cache** — `ThumbnailVariant.serving(points:scale:)` picks the size; `ThumbnailPipeline` keeps decoded `UIImage`s in an `NSCache`, is a `MemoryTrimmable`, and `ApplicationIconView` draws a synchronous hit in the same frame.
5. **Metadata index** — `MetadataIndexService.reconcile` runs from the library model off the main actor after every index change; `forget` on removal.
6. **Archive access** — entry tables cached by file stamp; deeper reads (`readEntryData`) pass through unchanged.
7. **Memory Manager** — thumbnail memory tier, decoded images, entry tables, and store manifests are trimmed; user state is never touched.
8. **Scheduler** — thumbnails, metadata persistence, cache sweeps, and startup sweeps run through it.
9. **Progressive loading** — skeletons for the loading state and for unrendered rows; icons fall back to a monogram until decoded.
10. **Store** — `StoreManifestCache` (conditional ETag/Last-Modified refresh, stale-only fetching, one decode per launch) and the indexed, paged `StoreCatalog` are composed into the engine (cache accounting under *metadata*, memory trimming, the store-loading benchmark). The Step 21 Store Browser keeps its own `StoreRepository`/`FileStoreCache`; moving it onto `StoreManifestCache` is a follow-up, not part of this step.
11. **Job queue** — `SigningQueue.apply` coalesces reports through `ProgressCoalescer` (1 % / 250 ms); stage changes and completions always publish.
12. **Persistence** — metadata index diffs before writing and persists in the background; store manifests decode once per launch; entry tables are read once per file stamp.
13. **Cache management** — `CachePolicy.standard(for:)` per category; automatic (`optimize()`, `scheduleMaintenance()`) and manual (page) cleanup; statistics per category; `DirectoryCacheStore` asserts it is never pointed at Application Support (where the library lives); protected files (`MetadataIndex.json`, `Baseline.json`).
14. **Launch** — `RootView` marks the first frame in `.task`, waits `StartupWorkPlan.deferralDelay`, then runs cleanup → restore imports → sweep inbox → restore queue → warm index → enforce policies → start memory observation, and records launch-to-first-frame.
15. **Animation** — `ZMotion` (environment) returns `nil` animations and identity transitions under Reduce Motion or a reduced preference; icon fades and toasts respect it.
16. **Benchmarks** — `CompositionRoot.makePerformanceBenchmarks` measures library load, index build, search latency, store loading (generated 500-app manifest), import speed (generated package in the temporary directory read the way intake reads), signing preparation (identities + profiles + library read), thumbnail generation (first available icon); the library model and store model also record in place. Accept as baseline → later runs compared.
17. **Accessibility** — every row combines children with a value; skeletons are hidden; the Show-all control reads the remaining count; nothing depends on motion.
18. **Future-proof** — `SearchIndex` is generic (used by the library and the store), `CacheStoring`/`MemoryTrimmable`/`ThumbnailSourceProviding` are ports, and the engine is optional in `ApplicationEnvironment` so tests and previews compose without it.

## Composition

`CompositionRoot.makePerformanceEngine(appIcons:preferences:)` builds the engine; `cachingLibraryReaderProvider(fileExtension:limits:)` wraps the library-directory provider for read-only inspectors over one shared `InspectionResultCache`. Cache directories: `Caches/ZynSignThumbnails`, `Caches/ZynSignMetadata`, `Caches/ZynSignDiagnostics`, `Caches/ZynSignStoreManifests`. The temporary-files category is backed by the same `FileTemporaryStorage` the Storage screen uses. Registration and `engine.start()` run asynchronously after composition; until then the page shows empty statistics rather than blocking launch.

## What it does not do

- It never removes imported applications, signed artifacts, profiles, identities, presets, or history; those are not caches and have no `CacheStoring` adapter.
- It does not benchmark a real import or a real signing run; those measurements would write to the library and the Export Center.
- Benchmarks depend on the device and the library size; the regression detector compares per item and ignores sub-2 ms noise, but a baseline from a different device is still a different device.

## Validation

`Tests/ZynSignTests/PerformanceEngineTests.swift` — Foundation-only tests for every pure and actor component, including a 2,000-document search staying under a frame and a 1,200-entry `LibraryIndex` build/search. Presentation code (`PerformanceDashboardSection`, `ApplicationIconView`, `ThumbnailPipeline`) and ImageIO rendering are validated on device.
