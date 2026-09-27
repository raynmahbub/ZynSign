import Foundation

/// The user's configured repositories, and the catalogs last validated from them.
///
/// The directory is the only place the App Store and the update engine read
/// source metadata. A source is not trusted because it is listed: a refresh
/// accepts a document only after `RepositoryCatalogParser` accepts it, and a
/// package address is offered only when it survived that parse.
@MainActor
final class RepositoryDirectory: ObservableObject {

    struct Source: Identifiable, Equatable, Hashable {
        let id: String
        var name: String
        let url: URL
        var health: RepositoryHealth
        var latencyMilliseconds: Int?
        var isRefreshing: Bool
        var lastRefreshedAt: Date?
        var lastError: String?
        var skippedAppCount: Int
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var catalogs: [RepositoryCatalog] = []

    private let storeURL: URL
    private let cacheDirectory: URL
    private let fetcher: any RepositoryCatalogFetching
    private let now: () -> Date
    private let fileManager = FileManager.default

    /// Called after a refresh changes the validated catalogs. The Download
    /// Center uses it to recompute updates. It is not a download.
    var onCatalogsChanged: (@MainActor () -> Void)?

    nonisolated init(
        storeURL: URL,
        cacheDirectory: URL,
        fetcher: any RepositoryCatalogFetching,
        now: @escaping () -> Date = { Date() }
    ) {
        self.storeURL = storeURL
        self.cacheDirectory = cacheDirectory
        self.fetcher = fetcher
        self.now = now
    }

    /// Apps across every validated catalog, stable by name.
    var apps: [RepositoryApp] {
        var seen = Set<String>()
        var result: [RepositoryApp] = []
        for catalog in catalogs {
            for app in catalog.apps where seen.insert(app.bundleIdentifier).inserted {
                result.append(app)
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func catalog(for sourceID: String) -> RepositoryCatalog? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        return catalogs.first { $0.sourceURL == source.url.absoluteString }
    }

    func load() {
        sources = Self.readSources(at: storeURL)
        catalogs = readCachedCatalogs()
    }

    @discardableResult
    func addSource(urlString: String) -> String? {
        switch DownloadURLPolicy.validateRepositoryAddress(normalized(urlString)) {
        case let .failure(rejection):
            return rejection.userMessage
        case let .success(url):
            if sources.contains(where: { $0.url.absoluteString == url.absoluteString }) {
                return "That source is already configured."
            }
            let source = Source(
                id: UUID().uuidString,
                name: url.host ?? "Source",
                url: url,
                health: .unknown,
                latencyMilliseconds: nil,
                isRefreshing: false,
                lastRefreshedAt: nil,
                lastError: nil,
                skippedAppCount: 0
            )
            sources.append(source)
            persistSources()
            return nil
        }
    }

    func removeSource(id: String) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        catalogs.removeAll { $0.sourceURL == source.url.absoluteString }
        let cache = cacheDirectory.appendingPathComponent(id + ".json")
        if Self.isInside(cache, root: cacheDirectory) {
            try? fileManager.removeItem(at: cache)
        }
        persistSources()
        onCatalogsChanged?()
    }

    /// Refreshes every configured source. A failed fetch keeps the last
    /// validated catalog and marks the source offline. It does not invent apps.
    func refresh() async {
        let ids = sources.map(\.id)
        for id in ids {
            guard let index = sources.firstIndex(where: { $0.id == id }) else { continue }
            let url = sources[index].url
            sources[index].isRefreshing = true
            let started = now()
            do {
                let data = try await fetcher.fetch(from: url)
                guard let index = sources.firstIndex(where: { $0.id == id }) else { continue }
                let milliseconds = Int(now().timeIntervalSince(started) * 1000)
                let examination = RepositoryCatalogParser.examine(data: data, sourceURL: url, fetchedAt: now())
                sources[index].latencyMilliseconds = milliseconds
                if let catalog = examination.catalog {
                    sources[index].health = milliseconds < 800 ? .fast : (milliseconds < 3_000 ? .slow : .offline)
                    sources[index].name = catalog.name
                    sources[index].lastError = examination.findings.first
                    sources[index].skippedAppCount = catalog.skippedAppCount
                    sources[index].lastRefreshedAt = catalog.fetchedAt
                    replaceCatalog(catalog, sourceID: id)
                } else {
                    sources[index].health = .offline
                    sources[index].lastError = examination.findings.first ?? "The source metadata was not accepted."
                }
            } catch {
                guard let index = sources.firstIndex(where: { $0.id == id }) else { continue }
                sources[index].health = .offline
                sources[index].latencyMilliseconds = nil
                sources[index].lastError = "The source could not be fetched."
            }
            if let index = sources.firstIndex(where: { $0.id == id }) {
                sources[index].isRefreshing = false
            }
        }
        persistSources()
        onCatalogsChanged?()
    }

    func probeHealth(id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let url = sources[index].url
        sources[index].isRefreshing = true
        let result = await RepositoryHealthProbe().probe(url: url)
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].health = result.health
        sources[index].latencyMilliseconds = result.latencyMilliseconds
        sources[index].isRefreshing = false
    }

    // MARK: - Persistence

    static func sourceCount(at url: URL) -> Int {
        readSources(at: url).count
    }

    private func replaceCatalog(_ catalog: RepositoryCatalog, sourceID: String) {
        catalogs.removeAll { $0.sourceURL == catalog.sourceURL }
        catalogs.append(catalog)
        writeCache(catalog, sourceID: sourceID)
    }

    private func persistSources() {
        let document = SourceDocument(
            schemaVersion: 1,
            sources: sources.map { PersistedSource(id: $0.id, name: $0.name, url: $0.url.absoluteString) }
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func readSources(at url: URL) -> [Source] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let persisted: [PersistedSource]
        if let document = try? JSONDecoder().decode(SourceDocument.self, from: data) {
            persisted = document.sources
        } else if let legacy = try? JSONDecoder().decode([PersistedSource].self, from: data) {
            persisted = legacy
        } else {
            return []
        }
        return persisted.compactMap { item in
            guard let url = URL(string: item.url), case .success = DownloadURLPolicy.validateHTTPS(url) else { return nil }
            return Source(
                id: item.id,
                name: item.name,
                url: url,
                health: .unknown,
                latencyMilliseconds: nil,
                isRefreshing: false,
                lastRefreshedAt: nil,
                lastError: nil,
                skippedAppCount: 0
            )
        }
    }

    private func readCachedCatalogs() -> [RepositoryCatalog] {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let allowed = Set(sources.map(\.url.absoluteString))
        return files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            guard let catalog = try? JSONDecoder().decode(RepositoryCatalog.self, from: data) else { return nil }
            guard allowed.contains(catalog.sourceURL) else { return nil }
            return catalog
        }
    }

    private func writeCache(_ catalog: RepositoryCatalog, sourceID: String) {
        guard sourceID == (sourceID as NSString).lastPathComponent, !sourceID.contains("..") else { return }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let url = cacheDirectory.appendingPathComponent(sourceID).appendingPathExtension("json")
        guard Self.isInside(url, root: cacheDirectory) else { return }
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("http://") {
            return trimmed
        }
        return "https://" + trimmed
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private struct SourceDocument: Codable {
        var schemaVersion: Int
        var sources: [PersistedSource]
    }

    private struct PersistedSource: Codable {
        var id: String
        var name: String
        var url: String
    }
}
