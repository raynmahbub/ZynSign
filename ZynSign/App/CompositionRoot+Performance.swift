import Foundation

/// The performance engine and its benchmarks.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Builds the Performance Engine: the scheduler, the thumbnail cache
    /// over the icon extractor, the metadata index, the memory manager over
    /// the system's pressure source, the cache manager with one store per
    /// category, the benchmark runner, the launch recorder, and the store
    /// manifest cache. Every cache lives under Caches — the system may
    /// reclaim it — and none of them is anywhere near the library's
    /// artifacts, so no cache policy can ever remove an imported
    /// application. Registration with the managers runs asynchronously;
    /// until it finishes the engine reports empty statistics rather than
    /// blocking composition.
    static func makePerformanceEngine(
        appIcons: AppIconExtraction,
        preferences: ZynSignPreferences = ZynSignPreferences.shippedDefault
    ) -> PerformanceEngine {
        let scheduler = sharedScheduler
        let caches = cachesDirectory
        let metadataDirectory = caches.appendingPathComponent("ZynSignMetadata", isDirectory: true)
        let diagnosticsDirectory = caches.appendingPathComponent("ZynSignDiagnostics", isDirectory: true)
        let thumbnails = ThumbnailCache(
            renderer: ImageIOThumbnailRenderer(),
            sourceProvider: AppIconThumbnailSource(icons: appIcons),
            directory: caches.appendingPathComponent("ZynSignThumbnails", isDirectory: true),
            scheduler: scheduler
        )
        let metadata = MetadataIndexService(
            store: FileMetadataIndexStore(location: metadataDirectory.appendingPathComponent("MetadataIndex.json", isDirectory: false)),
            scheduler: scheduler
        )
        let storeManifests = StoreManifestCache(
            directory: caches.appendingPathComponent("ZynSignStoreManifests", isDirectory: true)
        )
        let memory = MemoryManager(observer: SystemMemoryPressureObserver())
        let cacheManager = CacheManager()
        let info = ApplicationInfo.current(bundle: .main)
        let benchmarks = PerformanceBenchmarkRunner(
            store: FilePerformanceBaselineStore(directory: diagnosticsDirectory),
            buildIdentifier: "\(info.marketingVersion) (\(info.buildVersion))"
        )
        let engine = PerformanceEngine(
            scheduler: scheduler,
            thumbnails: thumbnails,
            metadata: metadata,
            entryTables: sharedEntryTables,
            memory: memory,
            caches: cacheManager,
            benchmarks: benchmarks,
            launch: LaunchPerformanceRecorder(),
            storeManifests: storeManifests,
            state: UserDefaultsPerformanceStateStore()
        )
        let temporaryData = FileTemporaryStorage(directories: temporaryDirectories(preferences: preferences))
        Task {
            await cacheManager.register(CompositeCacheStore(cacheCategory: .metadata, stores: [
                DirectoryCacheStore(
                    category: .metadata,
                    directories: [metadataDirectory],
                    // The index document is rebuilt, not evicted: it is the
                    // reason the list opens without reading a package.
                    protectedFileNames: ["MetadataIndex.json"]
                ),
                StoreManifestCacheStore(cache: storeManifests),
            ]))
            await cacheManager.register(DirectoryCacheStore(
                category: .diagnostics,
                directories: [diagnosticsDirectory],
                // The accepted baseline is the standard later runs are held
                // to; clearing it is an explicit action on the page.
                protectedFileNames: ["Baseline.json"]
            ))
            await cacheManager.register(TemporaryFilesCacheStore(temporaryData: temporaryData))
            await engine.start()
        }
        return engine
    }

    /// The benchmark suite the Performance page runs. Each benchmark
    /// measures real work over the user's own data where that is safe and
    /// read-only, and synthetic work in a scratch location where it is not:
    /// the library is read, indexed, and searched as it is; store loading
    /// decodes and indexes a generated manifest; import speed writes a
    /// generated package to the temporary directory and reads it back the
    /// way intake does; signing preparation reads the identities and
    /// profiles a signing session would choose from; thumbnail generation
    /// renders the first library icon it finds. Nothing signs, imports,
    /// or writes to the library.
    static func makePerformanceBenchmarks(environment: ApplicationEnvironment) -> [PerformanceBenchmark] {
        let library = environment.library
        let provenance = environment.applicationProvenance
        let organizer = environment.libraryOrganizer
        let identities = environment.identityStore
        let profiles = environment.provisioningProfiles
        let icons = environment.appIcons
        var suite: [PerformanceBenchmark] = []

        suite.append(PerformanceBenchmark(kind: .libraryLoad) {
            let entries = try await library.entries()
            let organization = (try? await organizer?.organization()) ?? .empty
            let known = await provenance?.knownProvenance() ?? [:]
            let index = LibraryIndex(entries: entries, organization: organization, provenance: known)
            return index.count
        })
        suite.append(PerformanceBenchmark(kind: .indexBuild) {
            let entries = try await library.entries()
            let known = await provenance?.knownProvenance() ?? [:]
            let index = LibraryIndex(entries: entries, provenance: known)
            return index.searchIndex.count
        })
        suite.append(PerformanceBenchmark(kind: .searchLatency) {
            let entries = try await library.entries()
            let known = await provenance?.knownProvenance() ?? [:]
            let index = LibraryIndex(entries: entries, provenance: known)
            let queries = ["a", "com", "app 1", "2.0", "xyzzy"]
            var total = 0
            for text in queries {
                total += index.results(for: LibraryQuery(searchText: text, filters: [], sort: .name), in: .all, now: Date()).count
            }
            _ = total
            return max(1, index.count) * queries.count
        })
        suite.append(PerformanceBenchmark(kind: .storeLoading) {
            let count = 500
            let apps = (0..<count).map { offset in
                "{\"name\":\"Sample App \(offset)\",\"bundleIdentifier\":\"com.example.sample\(offset)\",\"version\":\"1.\(offset % 20)\",\"subtitle\":\"Benchmark entry\"}"
            }.joined(separator: ",")
            let data = Data("{\"name\":\"Benchmark\",\"apps\":[\(apps)]}".utf8)
            guard let benchmarkURL = URL(string: "https://example.invalid/apps.json"),
                  let manifest = StoreManifestCache.decodeFeed(
                data, sourceID: "benchmark", url: benchmarkURL,
                entityTag: nil, lastModified: nil, fetchedAt: Date()
            ) else { throw ZynSignError.packagingFailure(diagnosticDetail: "The benchmark manifest did not decode.") }
            let catalog = StoreCatalog(manifests: [manifest])
            _ = catalog.matching("sample 4")
            return catalog.count
        })
        suite.append(PerformanceBenchmark(kind: .importSpeed) {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZynSignBenchmark", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let package = scratch.appendingPathComponent("Benchmark.ipa", isDirectory: false)
            let payload = Data(repeating: 0x5A, count: 64 * 1_024)
            var entries: [ArchiveWriteEntry] = []
            for offset in 0..<200 {
                guard let path = ArchivePath(rawValue: "Payload/Benchmark.app/Resources/file\(offset).bin") else { continue }
                entries.append(ArchiveWriteEntry(path: path, kind: .regularFile(isExecutable: false), content: payload))
            }
            var bytes = Data()
            try ZipArchiveWriter().writeArchive(entries: entries, policy: .default) { bytes.append($0) }
            try bytes.write(to: package, options: .atomic)
            // Intake copies the file into its own directory, then reads
            // the entry table; the benchmark does the same.
            let staged = scratch.appendingPathComponent("Staged.ipa", isDirectory: false)
            try FileManager.default.copyItem(at: package, to: staged)
            let table = try ZipArchiveReader(location: staged).readEntryTable()
            return table.count
        })
        suite.append(PerformanceBenchmark(kind: .signingPreparation) {
            let identityCount = (try? identities.listIdentities().count) ?? 0
            let profileCount = (try? await profiles?.allProfiles().count) ?? 0
            let entries = try await library.entries()
            return max(1, identityCount + profileCount + entries.count)
        })
        if let icons {
            suite.append(PerformanceBenchmark(kind: .thumbnailGeneration) {
                let entries = try await library.entries()
                var source: Data?
                for entry in entries where entry.isArtifactAvailable {
                    if let data = await icons.iconData(for: entry.record.artifact.artifactID) {
                        source = data
                        break
                    }
                }
                guard let source else {
                    throw ZynSignError.packagingFailure(diagnosticDetail: "No library icon is available to render.")
                }
                let renderer = ImageIOThumbnailRenderer()
                var rendered = 0
                for variant in ThumbnailVariant.allCases where renderer.renderThumbnail(from: source, maximumPixelSize: variant.maximumPixelSize) != nil {
                    rendered += 1
                }
                return max(1, rendered)
            })
        }
        return suite
    }
}
