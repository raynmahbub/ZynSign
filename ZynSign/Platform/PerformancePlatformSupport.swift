import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Thumbnail rendering

/// Renders thumbnails with ImageIO's downsampling, which decodes at the
/// target size instead of decoding the full image and scaling it down —
/// the difference between a few hundred kilobytes and a few megabytes of
/// transient memory per icon, and the reason a scroll through a thousand
/// rows never has to decode a thousand home-screen icons.
///
/// Output is PNG so alpha survives; icons in packages are PNG already.
struct ImageIOThumbnailRenderer: ThumbnailRendering {

    func renderThumbnail(from data: Data, maximumPixelSize: Int) -> Data? {
        guard !data.isEmpty, maximumPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - Memory pressure

/// Reports memory pressure from the kernel's pressure source and, on iOS,
/// from the application's memory warning.
///
/// The dispatch source reports warning and critical levels and returns to
/// nominal when the system does; the UIKit notification carries no level
/// and is treated as a warning. Both arrive on a utility queue and are
/// forwarded as they are; the memory manager decides what to do.
final class SystemMemoryPressureObserver: MemoryPressureObserving, @unchecked Sendable {

    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var notificationToken: NSObjectProtocol?
    private let queue = DispatchQueue(label: "ZynSign.MemoryPressure", qos: .utility)

    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak pressure] in
            guard let pressure else { return }
            let event = pressure.data
            if event.contains(.critical) {
                handler(.critical)
            } else if event.contains(.warning) {
                handler(.warning)
            } else if event.contains(.normal) {
                handler(.nominal)
            }
        }
        pressure.activate()
        source = pressure

        #if canImport(UIKit)
        notificationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            handler(.warning)
        }
        #endif
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
        notificationToken = nil
    }
}

// MARK: - Artifact stamps

/// Stamps an artifact's file by size and modification date, so values
/// derived from it are keyed to exactly those bytes.
struct FileArtifactStampProvider: ArtifactStampProviding {

    let directories: [URL]
    let fileExtension: String

    init(directories: [URL], fileExtension: String = "ipa") {
        self.directories = directories
        self.fileExtension = fileExtension
    }

    func stamp(for artifact: ArtifactIdentifier) -> String? {
        for directory in directories {
            let location = directory
                .appendingPathComponent(artifact.rawValue, isDirectory: false)
                .appendingPathExtension(fileExtension)
            guard let values = try? location.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(size):\(Int64(modified * 1_000))"
        }
        return nil
    }
}

// MARK: - Document stores

/// The metadata index as one JSON document in the caches directory.
struct FileMetadataIndexStore: MetadataIndexStore {

    let location: URL

    func loadMetadataIndex() throws -> MetadataIndex? {
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let data = try Data(contentsOf: location)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MetadataIndex.self, from: data)
    }

    func saveMetadataIndex(_ index: MetadataIndex) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: location, options: .atomic)
    }

    func removeMetadataIndex() throws {
        guard FileManager.default.fileExists(atPath: location.path) else { return }
        try FileManager.default.removeItem(at: location)
    }
}

/// Benchmark measurements and the baseline as two JSON documents in the
/// diagnostics cache directory.
struct FilePerformanceBaselineStore: PerformanceBaselineStore {

    let directory: URL

    private var baselineLocation: URL { directory.appendingPathComponent("Baseline.json", isDirectory: false) }
    private var measurementsLocation: URL { directory.appendingPathComponent("Measurements.json", isDirectory: false) }

    func loadBaseline() throws -> BenchmarkBaseline? {
        try load(BenchmarkBaseline.self, at: baselineLocation)
    }

    func saveBaseline(_ baseline: BenchmarkBaseline) throws {
        try save(baseline, at: baselineLocation)
    }

    func removeBaseline() throws {
        guard FileManager.default.fileExists(atPath: baselineLocation.path) else { return }
        try FileManager.default.removeItem(at: baselineLocation)
    }

    func loadMeasurements() throws -> [BenchmarkMeasurement] {
        try load([BenchmarkMeasurement].self, at: measurementsLocation) ?? []
    }

    func saveMeasurements(_ measurements: [BenchmarkMeasurement]) throws {
        try save(measurements, at: measurementsLocation)
    }

    private func load<T: Decodable>(_ type: T.Type, at location: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: location))
    }

    private func save<T: Encodable>(_ value: T, at location: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: location, options: .atomic)
    }
}

/// The engine's last-optimization instant, in `UserDefaults`.
struct UserDefaultsPerformanceStateStore: PerformanceStateStoring {

    static let lastOptimizationKey = "ZynSignPerformance.lastOptimization"

    var lastOptimization: Date? {
        UserDefaults.standard.object(forKey: Self.lastOptimizationKey) as? Date
    }

    func setLastOptimization(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date, forKey: Self.lastOptimizationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastOptimizationKey)
        }
    }
}

// MARK: - Cache stores

/// A `CacheStoring` over one or more directories of derived files.
///
/// The store lists regular files directly inside its directories, reports
/// their sizes and modification dates, and removes the ones it is asked
/// to. It is constructed only over caches-directory folders by the
/// composition root, which refuses to build one over the library root —
/// so no configuration can point a cache store at imported applications.
struct DirectoryCacheStore: CacheStoring {

    let cacheCategory: CacheCategory
    let directories: [URL]

    /// File names never removed by this store, for documents that are
    /// cheap to keep and expensive to rebuild.
    let protectedFileNames: Set<String>

    init(category: CacheCategory, directories: [URL], protectedFileNames: Set<String> = []) {
        // A cache store sweeps whole directories, so it is only ever pointed
        // at reclaimable locations. Application Support — where the library,
        // profiles, and history live — is refused outright.
        for directory in directories {
            assert(
                !directory.standardizedFileURL.path.contains("/Application Support/"),
                "A cache store must not be pointed at Application Support: \(directory.path)"
            )
        }
        self.cacheCategory = category
        self.directories = directories
        self.protectedFileNames = protectedFileNames
    }

    func cacheStatistics() async -> CacheStatistics {
        let items = allItems()
        return CacheStatistics(
            category: cacheCategory,
            byteCount: items.reduce(0) { $0 + $1.byteCount },
            itemCount: items.count
        )
    }

    func cacheItems() async -> [CacheItemDescriptor] {
        allItems().filter { !protectedFileNames.contains(URL(fileURLWithPath: $0.key).lastPathComponent) }
    }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        var removed = 0
        var freed = 0
        var skipped = 0
        for key in keys {
            let url = URL(fileURLWithPath: key)
            guard directories.contains(where: { url.deletingLastPathComponent().standardizedFileURL.path == $0.standardizedFileURL.path }),
                  !protectedFileNames.contains(url.lastPathComponent) else {
                skipped += 1
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
                freed += size
            } catch {
                skipped += 1
            }
        }
        return CacheCleanupReport(category: cacheCategory, removedItemCount: removed, freedByteCount: freed, skippedItemCount: skipped)
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        await removeCacheItems(named: allItems().map(\.key))
    }

    /// Every regular file directly inside the directories, keyed by its
    /// full path so two directories cannot collide.
    private func allItems() -> [CacheItemDescriptor] {
        var items: [CacheItemDescriptor] = []
        for directory in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                items.append(CacheItemDescriptor(
                    key: url.standardizedFileURL.path,
                    byteCount: values.fileSize ?? 0,
                    lastAccess: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        return items
    }
}

/// A `CacheStoring` for temporary files, over the existing temporary-data
/// boundary so the retention rule and the recognition of ZynSign's own
/// files stay in one place. "Remove all" is the policy cleanup: only
/// entries older than the retention interval, only ZynSign's own.
struct TemporaryFilesCacheStore: CacheStoring {

    let temporaryData: any TemporaryDataCleaning
    let now: @Sendable () -> Date

    init(temporaryData: any TemporaryDataCleaning, now: @escaping @Sendable () -> Date = { Date() }) {
        self.temporaryData = temporaryData
        self.now = now
    }

    var cacheCategory: CacheCategory { .temporaryFiles }

    func cacheStatistics() async -> CacheStatistics {
        let usage = (try? temporaryData.temporaryDataUsage()) ?? (byteCount: 0, fileCount: 0)
        return CacheStatistics(category: .temporaryFiles, byteCount: usage.byteCount, itemCount: usage.fileCount)
    }

    /// Temporary files are not planned item by item: the boundary applies
    /// its own age rule, so the planner is given nothing to choose from.
    func cacheItems() async -> [CacheItemDescriptor] { [] }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        CacheCleanupReport(category: .temporaryFiles, skippedItemCount: keys.count)
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        let cutoff = StorageCleanupPolicy.temporaryDataCutoff(now: now())
        guard let cleanup = try? temporaryData.removeTemporaryData(olderThan: cutoff) else {
            return CacheCleanupReport(category: .temporaryFiles)
        }
        return CacheCleanupReport(
            category: .temporaryFiles,
            removedItemCount: cleanup.removedFileCount,
            freedByteCount: cleanup.freedByteCount,
            skippedItemCount: cleanup.skippedItemCount
        )
    }
}

/// A `CacheStoring` over the store's manifest cache.
struct StoreManifestCacheStore: CacheStoring {

    let cache: StoreManifestCache

    var cacheCategory: CacheCategory { .metadata }

    func cacheStatistics() async -> CacheStatistics {
        let items = await cache.items()
        return CacheStatistics(category: .metadata, byteCount: items.reduce(0) { $0 + $1.byteCount }, itemCount: items.count)
    }

    func cacheItems() async -> [CacheItemDescriptor] {
        await cache.items()
    }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        await cache.removeItems(named: keys)
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        let keys = await cache.items().map(\.key)
        return await cache.removeItems(named: keys)
    }
}

/// Several stores of one category presented as one, so metadata — the
/// provenance document, the metadata index, and the manifests — is
/// reported and swept together.
struct CompositeCacheStore: CacheStoring {

    let cacheCategory: CacheCategory
    let stores: [any CacheStoring]

    func cacheStatistics() async -> CacheStatistics {
        var bytes = 0
        var items = 0
        var memoryItems = 0
        var memoryBytes = 0
        for store in stores {
            let statistics = await store.cacheStatistics()
            bytes += statistics.byteCount
            items += statistics.itemCount
            memoryItems += statistics.memoryItemCount
            memoryBytes += statistics.memoryByteCount
        }
        return CacheStatistics(category: cacheCategory, byteCount: bytes, itemCount: items, memoryItemCount: memoryItems, memoryByteCount: memoryBytes)
    }

    func cacheItems() async -> [CacheItemDescriptor] {
        var result: [CacheItemDescriptor] = []
        for store in stores {
            result.append(contentsOf: await store.cacheItems())
        }
        return result
    }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        var removed = 0
        var freed = 0
        var skipped = 0
        // Each store removes the keys it recognises and skips the rest;
        // a key is counted skipped only when no store removed it.
        var removedKeys: Set<String> = []
        for store in stores {
            let items = Set(await store.cacheItems().map(\.key))
            let mine = keys.filter { items.contains($0) }
            guard !mine.isEmpty else { continue }
            let report = await store.removeCacheItems(named: mine)
            removed += report.removedItemCount
            freed += report.freedByteCount
            removedKeys.formUnion(mine)
        }
        skipped = keys.count - removedKeys.count
        return CacheCleanupReport(category: cacheCategory, removedItemCount: removed, freedByteCount: freed, skippedItemCount: max(0, skipped))
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        var removed = 0
        var freed = 0
        var skipped = 0
        for store in stores {
            let report = await store.removeAllCacheItems()
            removed += report.removedItemCount
            freed += report.freedByteCount
            skipped += report.skippedItemCount
        }
        return CacheCleanupReport(category: cacheCategory, removedItemCount: removed, freedByteCount: freed, skippedItemCount: skipped)
    }
}

// MARK: - Store feed fetching

/// Fetches source manifests with `URLSession`, sending the cached
/// validators so an unchanged manifest returns `304 Not Modified`.
struct URLSessionStoreFeedFetcher: StoreFeedFetching {

    let timeout: TimeInterval

    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    func fetch(_ url: URL, entityTag: String?, lastModified: String?) async -> StoreFeedFetchOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let start = Date()
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1_000)
            guard let http = response as? HTTPURLResponse else {
                return .failed(latencyMilliseconds: latency, httpStatus: nil)
            }
            if http.statusCode == 304 {
                return .notModified(latencyMilliseconds: latency)
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed(latencyMilliseconds: latency, httpStatus: http.statusCode)
            }
            let maximum = 8 * 1_024 * 1_024
            guard response.expectedContentLength <= Int64(maximum) else {
                return .failed(latencyMilliseconds: latency, httpStatus: http.statusCode)
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(response.expectedContentLength), maximum))
            }
            do {
                for try await byte in bytes {
                    guard data.count < maximum else {
                        return .failed(latencyMilliseconds: latency, httpStatus: http.statusCode)
                    }
                    data.append(byte)
                }
            } catch {
                return .failed(latencyMilliseconds: latency, httpStatus: http.statusCode)
            }
            return .updated(
                data: data,
                entityTag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                latencyMilliseconds: latency
            )
        } catch {
            return .failed(latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1_000), httpStatus: nil)
        }
    }
}
