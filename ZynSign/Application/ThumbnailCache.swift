import Foundation

/// The sizes the interface draws an application image at.
///
/// A thumbnail is generated once per size and never resampled on the way
/// to the screen: a 52-point row icon is decoded from a 52-point-class
/// thumbnail, not from the 180-pixel home-screen icon the package carries,
/// and certainly not from a screenshot. The pixel sizes are ceilings for
/// the longest edge at 3× scale, so every device draws a thumbnail at or
/// above its own resolution without ever decoding more.
enum ThumbnailVariant: String, CaseIterable, Codable, Hashable, Sendable {

    /// Rows and compact cards (up to 52 points).
    case small

    /// Grid cards and headers (up to 96 points).
    case medium

    /// Detail headers and previews (up to 256 points).
    case large

    /// The longest edge, in pixels, the variant is rendered at.
    var maximumPixelSize: Int {
        switch self {
        case .small: return 160
        case .medium: return 288
        case .large: return 768
        }
    }

    /// The variant that serves a square drawn at `points` on a screen of
    /// `scale`: the smallest whose pixel ceiling covers the request.
    static func serving(points: Double, scale: Double) -> ThumbnailVariant {
        let pixels = points * max(1, scale)
        for variant in allCases where Double(variant.maximumPixelSize) >= pixels {
            return variant
        }
        return .large
    }
}

/// What a thumbnail was made from. Icons and screenshots live in different
/// cache families so a screenshot sweep cannot cost the library its icons.
enum ThumbnailSource: String, Codable, Hashable, Sendable {
    case icon
    case screenshot
    case assetPreview

    /// The cache category the family is accounted under.
    var cacheCategory: CacheCategory {
        switch self {
        case .icon: return .thumbnails
        case .screenshot, .assetPreview: return .screenshots
        }
    }
}

/// Identifies one thumbnail: which image, which family, which size.
struct ThumbnailKey: Hashable, Sendable {

    /// The artifact the image came from.
    let artifactID: ArtifactIdentifier

    /// The image within the artifact — `nil` for the application icon, a
    /// stable name otherwise (a screenshot's entry path, an asset name).
    let imageName: String?

    let source: ThumbnailSource
    let variant: ThumbnailVariant

    init(artifactID: ArtifactIdentifier, imageName: String? = nil, source: ThumbnailSource = .icon, variant: ThumbnailVariant) {
        self.artifactID = artifactID
        self.imageName = imageName
        self.source = source
        self.variant = variant
    }

    /// A file-system-safe name for the thumbnail's disk entry.
    var fileName: String {
        var name = artifactID.rawValue
        if let imageName {
            var hasher = UInt64(14_695_981_039_346_656_037)
            for byte in imageName.utf8 {
                hasher ^= UInt64(byte)
                hasher = hasher &* 1_099_511_628_211
            }
            name += "-" + String(hasher, radix: 16)
        }
        return name + "." + source.rawValue + "." + variant.rawValue + ".thumb"
    }
}

/// Produces downsampled image bytes from original image bytes.
///
/// The port hides the imaging framework. The application layer hands over
/// encoded bytes and a pixel ceiling and receives encoded bytes back; it
/// never sees a bitmap, so the same cache works with any renderer and the
/// tests use one that needs no graphics stack.
protocol ThumbnailRendering: Sendable {

    /// The encoded thumbnail, or `nil` when the bytes are not an image the
    /// renderer can decode. The result's longest edge is at most
    /// `maximumPixelSize` pixels.
    func renderThumbnail(from data: Data, maximumPixelSize: Int) -> Data?
}

/// Supplies the original bytes of an image on demand.
///
/// The cache asks for originals only on a miss, so an application icon is
/// read from its package once, not once per size: the first miss reads the
/// original, and every variant is rendered from those bytes in one go.
protocol ThumbnailSourceProviding: Sendable {

    /// The original encoded image for `key`'s artifact and image name, or
    /// `nil` when none can be read.
    func originalImageData(artifactID: ArtifactIdentifier, imageName: String?, source: ThumbnailSource) async -> Data?
}

/// A bounded in-memory tier keyed by thumbnail, with least-recently-used
/// eviction by byte cost.
///
/// Kept as a value type inside the actor so it is trivially serialised,
/// and exposed only through the actor. The presentation layer keeps its
/// own decoded-image tier (`ThumbnailImageStore`) on top of this one; this
/// tier holds encoded bytes, which are small and cheap to hand across
/// actors.
struct ThumbnailMemoryTier: Equatable, Sendable {

    private(set) var byteBudget: Int
    private(set) var entries: [ThumbnailKey: Data] = [:]
    private var order: [ThumbnailKey] = []
    private(set) var byteCount = 0

    init(byteBudget: Int) {
        self.byteBudget = max(0, byteBudget)
    }

    var count: Int { entries.count }

    mutating func value(for key: ThumbnailKey) -> Data? {
        guard let data = entries[key] else { return nil }
        touch(key)
        return data
    }

    func peek(_ key: ThumbnailKey) -> Data? {
        entries[key]
    }

    mutating func insert(_ data: Data, for key: ThumbnailKey) {
        if let existing = entries[key] {
            byteCount -= existing.count
        } else {
            order.append(key)
        }
        entries[key] = data
        byteCount += data.count
        touch(key)
        evictIfNeeded()
    }

    mutating func remove(_ key: ThumbnailKey) {
        guard let existing = entries.removeValue(forKey: key) else { return }
        byteCount -= existing.count
        order.removeAll { $0 == key }
    }

    mutating func removeAll(where shouldRemove: (ThumbnailKey) -> Bool) {
        for key in order where shouldRemove(key) {
            if let existing = entries.removeValue(forKey: key) {
                byteCount -= existing.count
            }
        }
        order.removeAll(where: shouldRemove)
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        byteCount = 0
    }

    /// Shrinks the tier to `fraction` of its budget, evicting least
    /// recently used first, without changing the budget.
    mutating func trim(toFraction fraction: Double) {
        let target = Int(Double(byteBudget) * min(1, max(0, fraction)))
        while byteCount > target, let oldest = order.first {
            remove(oldest)
        }
    }

    private mutating func touch(_ key: ThumbnailKey) {
        if let index = order.firstIndex(of: key), index != order.count - 1 {
            order.remove(at: index)
            order.append(key)
        }
    }

    private mutating func evictIfNeeded() {
        while byteCount > byteBudget, let oldest = order.first {
            remove(oldest)
        }
    }
}

/// The smart thumbnail cache: one generation per image per size, a memory
/// tier for what is on screen, a disk tier for what was on screen before,
/// and eviction that keeps both within policy.
///
/// **Never decode twice.** A request for a size is answered from memory,
/// then from disk, and only then by rendering — and a render produces
/// *every* variant from one read of the original, so the row icon, the grid
/// icon, and the detail header cost one archive read between them.
/// Concurrent requests for the same key share one render through the
/// scheduler's key coalescing.
///
/// **Disk tier.** Thumbnails live in a caches-directory folder the system
/// may reclaim. The cache tracks access by touching the file's
/// modification date on read, so the eviction planner sees real recency.
/// A missing or reclaimed file is a miss, never an error.
///
/// **Bounded.** The memory tier is bounded by bytes; the disk tier by the
/// `thumbnails` and `screenshots` cache policies; `trimMemory(level:)`
/// answers memory pressure by shrinking or emptying the memory tier while
/// leaving disk alone, so nothing has to be re-rendered after a warning.
actor ThumbnailCache {

    private let renderer: any ThumbnailRendering
    private let sourceProvider: any ThumbnailSourceProviding
    private let directory: URL
    private let scheduler: BackgroundWorkScheduler
    private let fileManager = FileManager.default
    private let now: @Sendable () -> Date

    private var memory: ThumbnailMemoryTier

    /// Renders counted this launch, for the diagnostics table.
    private(set) var renderCount = 0
    private(set) var memoryHitCount = 0
    private(set) var diskHitCount = 0

    /// Creates the cache.
    ///
    /// - Parameters:
    ///   - renderer: Produces downsampled bytes.
    ///   - sourceProvider: Reads original image bytes on a miss.
    ///   - directory: Where the disk tier lives. Created on first write.
    ///   - scheduler: Runs renders off the main actor and coalesces them.
    ///   - memoryByteBudget: The memory tier's ceiling. Eight megabytes of
    ///     encoded thumbnails is several hundred rows' worth.
    init(
        renderer: any ThumbnailRendering,
        sourceProvider: any ThumbnailSourceProviding,
        directory: URL,
        scheduler: BackgroundWorkScheduler,
        memoryByteBudget: Int = 8 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.renderer = renderer
        self.sourceProvider = sourceProvider
        self.directory = directory
        self.scheduler = scheduler
        self.memory = ThumbnailMemoryTier(byteBudget: memoryByteBudget)
        self.now = now
    }

    // MARK: - Reading

    /// The thumbnail already in memory for `key`, without touching disk or
    /// rendering. Cheap enough to call while laying out a row.
    func cachedInMemory(_ key: ThumbnailKey) -> Data? {
        memory.peek(key)
    }

    /// The thumbnail for `key`, rendering it when necessary. `nil` when the
    /// original cannot be read or is not an image.
    func thumbnail(for key: ThumbnailKey) async -> Data? {
        if let data = memory.value(for: key) {
            memoryHitCount += 1
            return data
        }
        if let data = readFromDisk(key) {
            diskHitCount += 1
            memory.insert(data, for: key)
            return data
        }
        let ticket = await scheduler.schedule(
            key: "thumbnail:\(key.artifactID.rawValue):\(key.imageName ?? ""):\(key.source.rawValue)",
            priority: .interactive
        ) { () async throws -> [ThumbnailVariant: Data] in
            try Task.checkCancellation()
            return await self.renderAllVariants(artifactID: key.artifactID, imageName: key.imageName, source: key.source)
        }
        guard let rendered = try? await ticket.value else { return nil }
        return rendered[key.variant]
    }

    /// Stores original bytes that were already read elsewhere — the Import
    /// Hub extracts icons while it analyses a package — rendering every
    /// variant now so the library shows the icon without reading the
    /// package again.
    func prime(originalImageData data: Data, artifactID: ArtifactIdentifier, imageName: String? = nil, source: ThumbnailSource = .icon) {
        guard !data.isEmpty else { return }
        store(renderVariants(from: data, artifactID: artifactID, imageName: imageName, source: source))
    }

    // MARK: - Maintenance

    /// Answers memory pressure. Warning halves the memory tier; critical
    /// empties it. Disk is untouched, so nothing is re-rendered later.
    func trimMemory(level: MemoryPressureLevel) {
        switch level {
        case .nominal:
            break
        case .warning:
            memory.trim(toFraction: 0.5)
        case .critical:
            memory.removeAll()
        }
    }

    /// Forgets every thumbnail of `artifactID`, in memory and on disk. Used
    /// when the library removes an application.
    func forget(artifactID: ArtifactIdentifier) {
        memory.removeAll { $0.artifactID == artifactID }
        for url in diskEntries(matching: { $0.hasPrefix(artifactID.rawValue) }) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// What the cache holds on disk and in memory for `source`'s category.
    func statistics(for category: CacheCategory) -> CacheStatistics {
        let sources = ThumbnailSource.allSources.filter { $0.cacheCategory == category }
        guard !sources.isEmpty else { return .empty(category) }
        let suffixes = sources.map { ".\($0.rawValue)." }
        var bytes = 0
        var count = 0
        for url in diskEntries(matching: { name in suffixes.contains { name.contains($0) } }) {
            count += 1
            bytes += fileSize(of: url)
        }
        var memoryBytes = 0
        var memoryCount = 0
        for (key, data) in memory.entries where sources.contains(key.source) {
            memoryCount += 1
            memoryBytes += data.count
        }
        return CacheStatistics(
            category: category,
            byteCount: bytes,
            itemCount: count,
            memoryItemCount: memoryCount,
            memoryByteCount: memoryBytes
        )
    }

    /// The disk tier's items for `category`, for the eviction planner.
    func diskDescriptors(for category: CacheCategory) -> [CacheItemDescriptor] {
        let sources = ThumbnailSource.allSources.filter { $0.cacheCategory == category }
        let suffixes = sources.map { ".\($0.rawValue)." }
        return diskEntries(matching: { name in suffixes.contains { name.contains($0) } }).map { url in
            CacheItemDescriptor(key: url.lastPathComponent, byteCount: fileSize(of: url), lastAccess: lastAccess(of: url))
        }
    }

    /// Removes the disk entries named by `keys` (file names), and any
    /// memory entries behind them. Returns what was removed.
    func removeDiskEntries(named keys: [String], category: CacheCategory) -> CacheCleanupReport {
        var removed = 0
        var freed = 0
        var skipped = 0
        for name in keys {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let size = fileSize(of: url)
            do {
                try fileManager.removeItem(at: url)
                removed += 1
                freed += size
            } catch {
                skipped += 1
            }
        }
        let removedNames = Set(keys)
        memory.removeAll { removedNames.contains($0.fileName) }
        return CacheCleanupReport(category: category, removedItemCount: removed, freedByteCount: freed, skippedItemCount: skipped)
    }

    /// Removes every thumbnail of `category`, on disk and in memory.
    func removeAll(category: CacheCategory) -> CacheCleanupReport {
        let names = diskDescriptors(for: category).map(\.key)
        let report = removeDiskEntries(named: names, category: category)
        memory.removeAll { $0.source.cacheCategory == category }
        return report
    }

    // MARK: - Private

    private func renderAllVariants(artifactID: ArtifactIdentifier, imageName: String?, source: ThumbnailSource) async -> [ThumbnailVariant: Data] {
        guard let original = await sourceProvider.originalImageData(artifactID: artifactID, imageName: imageName, source: source),
              !original.isEmpty else {
            return [:]
        }
        let rendered = renderVariants(from: original, artifactID: artifactID, imageName: imageName, source: source)
        store(rendered)
        return Dictionary(uniqueKeysWithValues: rendered.map { ($0.key.variant, $0.value) })
    }

    private func renderVariants(from original: Data, artifactID: ArtifactIdentifier, imageName: String?, source: ThumbnailSource) -> [ThumbnailKey: Data] {
        var result: [ThumbnailKey: Data] = [:]
        for variant in ThumbnailVariant.allCases {
            guard let data = renderer.renderThumbnail(from: original, maximumPixelSize: variant.maximumPixelSize), !data.isEmpty else {
                continue
            }
            renderCount += 1
            result[ThumbnailKey(artifactID: artifactID, imageName: imageName, source: source, variant: variant)] = data
        }
        return result
    }

    private func store(_ rendered: [ThumbnailKey: Data]) {
        guard !rendered.isEmpty else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, data) in rendered {
            memory.insert(data, for: key)
            try? data.write(to: fileURL(for: key), options: .atomic)
        }
    }

    private func readFromDisk(_ key: ThumbnailKey) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Touching the modification date is how the eviction planner learns
        // the thumbnail is still in use.
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    private func fileURL(for key: ThumbnailKey) -> URL {
        directory.appendingPathComponent(key.fileName, isDirectory: false)
    }

    private func diskEntries(matching nameFilter: (String) -> Bool) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.filter { $0.pathExtension == "thumb" && nameFilter($0.lastPathComponent) }
    }

    private func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func lastAccess(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

extension ThumbnailSource {
    /// Every family, in declaration order.
    static var allSources: [ThumbnailSource] { [.icon, .screenshot, .assetPreview] }
}

/// Supplies application icons to the thumbnail cache from the library's
/// packages, through the same bounded extraction the cards have always
/// used. Screenshots and asset previews are not read from packages yet;
/// the source answers `nil` for them, so the cache renders nothing and the
/// interface shows its placeholder.
struct AppIconThumbnailSource: ThumbnailSourceProviding {

    let icons: AppIconExtraction

    func originalImageData(artifactID: ArtifactIdentifier, imageName: String?, source: ThumbnailSource) async -> Data? {
        switch source {
        case .icon:
            return await icons.iconData(for: artifactID)
        case .screenshot, .assetPreview:
            return nil
        }
    }
}
