import Foundation

/// One application as a source manifest lists it. Metadata only: nothing
/// here is executed, and a download happens only when the user asks.
struct StoreCatalogApp: Equatable, Hashable, Sendable, Codable, Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let versionText: String
    let subtitle: String?
    let iconURL: URL?
    let downloadURL: URL?

    /// The source the entry came from.
    let sourceID: String

    init(id: String, name: String, bundleID: String, versionText: String, subtitle: String?, iconURL: URL?, downloadURL: URL?, sourceID: String) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.versionText = versionText
        self.subtitle = subtitle
        self.iconURL = iconURL
        self.downloadURL = downloadURL
        self.sourceID = sourceID
    }
}

/// A source's manifest as last fetched, with the validators the next
/// fetch sends so an unchanged manifest costs a header round trip and no
/// body.
struct StoreSourceManifest: Equatable, Sendable, Codable {
    let sourceID: String
    let url: URL
    let name: String?
    let apps: [StoreCatalogApp]
    let fetchedAt: Date
    let entityTag: String?
    let lastModified: String?

    /// Whether the manifest is younger than `maxAge` at `now`.
    func isFresh(maxAge: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) < maxAge
    }
}

/// The outcome of fetching one source.
enum StoreFeedFetchOutcome: Equatable, Sendable {

    /// The server confirmed the cached manifest is current.
    case notModified(latencyMilliseconds: Int)

    /// A new body arrived, with its validators.
    case updated(data: Data, entityTag: String?, lastModified: String?, latencyMilliseconds: Int)

    /// The fetch failed; the cached manifest, if any, stands.
    case failed(latencyMilliseconds: Int?, httpStatus: Int?)
}

/// Fetches source manifests, conditionally when validators are known.
protocol StoreFeedFetching: Sendable {
    func fetch(_ url: URL, entityTag: String?, lastModified: String?) async -> StoreFeedFetchOutcome
}

/// Keeps every source's last manifest on disk and decodes each once.
///
/// **Incremental refresh.** A refresh asks the cache which sources are
/// stale; fresh ones are skipped entirely, stale ones are fetched with
/// their validators, and only a changed body is decoded and stored. The
/// store screen therefore opens from the cache instantly and refreshes
/// only what changed.
///
/// **Bounded and trimmable.** Decoded manifests live in memory only while
/// the store screen needs them; `trimMemory` drops them and the next read
/// decodes from disk again. Disk entries are accounted under the
/// `metadata` cache category and swept by its policy.
actor StoreManifestCache {

    private let directory: URL
    private let fileManager = FileManager.default
    private let now: @Sendable () -> Date

    private var decoded: [String: StoreSourceManifest] = [:]

    /// The longest a manifest is considered fresh without a network check.
    let maximumAge: TimeInterval

    init(directory: URL, maximumAge: TimeInterval = 15 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maximumAge = maximumAge
        self.now = now
    }

    /// The cached manifest for `sourceID`, decoding it from disk on first
    /// use. `nil` when none is cached.
    func manifest(for sourceID: String) -> StoreSourceManifest? {
        if let cached = decoded[sourceID] { return cached }
        let url = fileURL(for: sourceID)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? Self.decoder.decode(StoreSourceManifest.self, from: data) else {
            return nil
        }
        decoded[sourceID] = manifest
        return manifest
    }

    /// Whether `sourceID` needs a fetch: no manifest, or one older than
    /// the maximum age.
    func isStale(_ sourceID: String) -> Bool {
        guard let manifest = manifest(for: sourceID) else { return true }
        return !manifest.isFresh(maxAge: maximumAge, now: now())
    }

    /// Stores `manifest` for its source.
    func store(_ manifest: StoreSourceManifest) {
        decoded[manifest.sourceID] = manifest
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(manifest)
            try data.write(to: fileURL(for: manifest.sourceID), options: .atomic)
        } catch {
            // Without the disk copy the source is fetched again next launch.
        }
    }

    /// Records that the server confirmed `sourceID`'s manifest is current,
    /// so its age restarts without re-decoding anything.
    func touch(_ sourceID: String) {
        guard let manifest = manifest(for: sourceID) else { return }
        store(StoreSourceManifest(
            sourceID: manifest.sourceID,
            url: manifest.url,
            name: manifest.name,
            apps: manifest.apps,
            fetchedAt: now(),
            entityTag: manifest.entityTag,
            lastModified: manifest.lastModified
        ))
    }

    /// Forgets `sourceID`'s manifest.
    func remove(_ sourceID: String) {
        decoded[sourceID] = nil
        try? fileManager.removeItem(at: fileURL(for: sourceID))
    }

    /// Drops decoded manifests from memory. Disk is untouched.
    func trimMemory() {
        decoded.removeAll()
    }

    /// How many manifests are decoded in memory.
    var decodedCount: Int { decoded.count }

    /// The cached manifests' files, for the cache manager.
    func items() -> [CacheItemDescriptor] {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.filter { $0.pathExtension == "manifest" }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return CacheItemDescriptor(
                key: url.lastPathComponent,
                byteCount: values?.fileSize ?? 0,
                lastAccess: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    /// Removes the files named by `keys`.
    func removeItems(named keys: [String]) -> CacheCleanupReport {
        var removed = 0
        var freed = 0
        var skipped = 0
        for name in keys {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try fileManager.removeItem(at: url)
                removed += 1
                freed += size
            } catch {
                skipped += 1
            }
        }
        decoded.removeAll()
        return CacheCleanupReport(category: .metadata, removedItemCount: removed, freedByteCount: freed, skippedItemCount: skipped)
    }

    // MARK: - Decoding manifests

    /// Decodes an AltSource-compatible feed body into a manifest.
    static func decodeFeed(_ data: Data, sourceID: String, url: URL, entityTag: String?, lastModified: String?, fetchedAt: Date) -> StoreSourceManifest? {
        guard let feed = try? JSONDecoder().decode(AltSourceFeed.self, from: data) else { return nil }
        var seen: Set<String> = []
        let apps: [StoreCatalogApp] = feed.apps.compactMap { app in
            guard seen.insert(app.bundleIdentifier).inserted else { return nil }
            return StoreCatalogApp(
                id: app.bundleIdentifier,
                name: app.name,
                bundleID: app.bundleIdentifier,
                versionText: [app.version, app.versionDate].compactMap { $0 }.joined(separator: " · "),
                subtitle: app.subtitle,
                iconURL: app.iconURL.flatMap { URL(string: $0) },
                downloadURL: app.downloadURL.flatMap { URL(string: $0) },
                sourceID: sourceID
            )
        }
        return StoreSourceManifest(
            sourceID: sourceID,
            url: url,
            name: feed.name,
            apps: apps,
            fetchedAt: fetchedAt,
            entityTag: entityTag,
            lastModified: lastModified
        )
    }

    private struct AltSourceFeed: Codable {
        let apps: [AltApp]
        let name: String?
    }

    private struct AltApp: Codable {
        let name: String
        let bundleIdentifier: String
        let version: String?
        let versionDate: String?
        let subtitle: String?
        let iconURL: String?
        let downloadURL: String?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func fileURL(for sourceID: String) -> URL {
        let safe = sourceID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "_"
        }
        return directory.appendingPathComponent(String(safe), isDirectory: false).appendingPathExtension("manifest")
    }
}

/// The merged, searchable, pageable catalogue of every cached manifest.
///
/// Built once per refresh from the manifests, not per keystroke: the
/// search index folds each application's name and bundle identifier once,
/// and a query is a trigram lookup. Paging hands the list to the view a
/// page at a time so a repository of thousands of entries opens as fast
/// as one of ten.
struct StoreCatalog: Equatable, Sendable {

    enum Field: Hashable, Sendable {
        case name
        case bundleIdentifier
        case subtitle
    }

    private(set) var apps: [StoreCatalogApp] = []
    private var byID: [String: StoreCatalogApp] = [:]
    private var index = SearchIndex<String, Field>()

    init() {}

    init(manifests: [StoreSourceManifest]) {
        var merged: [String: StoreCatalogApp] = [:]
        for manifest in manifests {
            for app in manifest.apps where merged[app.id] == nil {
                merged[app.id] = app
            }
        }
        self.byID = merged
        self.apps = merged.values.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
        var documents: [String: SearchIndex<String, Field>.Document] = [:]
        for app in apps {
            documents[app.id] = SearchIndex<String, Field>.Document(fields: [
                .name: SearchIndex<String, Field>.fold(app.name),
                .bundleIdentifier: SearchIndex<String, Field>.fold(app.bundleID),
                .subtitle: SearchIndex<String, Field>.fold(app.subtitle ?? ""),
            ])
        }
        self.index = SearchIndex(documents: documents)
    }

    var count: Int { apps.count }

    var isEmpty: Bool { apps.isEmpty }

    /// The applications matching every word of `searchText`, in catalogue
    /// order. Empty text matches everything.
    func matching(_ searchText: String) -> [StoreCatalogApp] {
        let terms = searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map { SearchIndex<String, Field>.fold(String($0)) }
        guard !terms.isEmpty else { return apps }
        let ids = index.matches(allOf: terms)
        return apps.filter { ids.contains($0.id) }
    }

    /// The first `count` applications of `list`, and whether more remain.
    static func page(_ list: [StoreCatalogApp], limit: Int) -> (items: [StoreCatalogApp], hasMore: Bool) {
        let limit = max(0, limit)
        if list.count <= limit { return (list, false) }
        return (Array(list.prefix(limit)), true)
    }

    /// The first `count` applications, for the featured strip.
    func featured(_ count: Int) -> [StoreCatalogApp] {
        Array(apps.prefix(max(0, count)))
    }
}
