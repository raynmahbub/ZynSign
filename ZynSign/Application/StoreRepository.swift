import Foundation

protocol StorePersisting: Sendable {
    func load() throws -> StoreSnapshot
    func save(_ snapshot: StoreSnapshot) throws
}

/// Serializes commits, not network requests. In-flight refreshes may not resurrect a
/// removed source or overwrite a user's enabled/preferred-source decision.
actor StoreRepository {
    private let storage: any StorePersisting
    private let client: any StoreFetching
    private var state = StoreSnapshot()
    private var loaded = false
    private var refreshing = Set<UUID>()
    private var adding = Set<URL>()

    init(storage: any StorePersisting, client: any StoreFetching = StoreHTTPClient()) {
        self.storage = storage; self.client = client
    }
    func snapshot() throws -> StoreSnapshot {
        if !loaded { state = try storage.load(); loaded = true }
        return state
    }
    private func commit(_ proposed: StoreSnapshot) throws {
        guard state.revision < UInt64.max else { throw StoreFailure.invalid("The Store snapshot revision is invalid.") }
        var next = proposed
        next.revision = state.revision + 1
        try storage.save(next)
        state = next
    }
    func add(_ raw: String) async throws {
        _ = try snapshot()
        let url = try StoreURLPolicy.validate(raw)
        guard !state.sources.contains(where: { $0.url == url }), adding.insert(url).inserted else {
            throw StoreFailure.invalid("This source URL is already configured or being added.")
        }
        defer { adding.remove(url) }
        guard state.sources.count + adding.count <= 64 else { throw StoreFailure.invalid("Up to 64 sources can be configured.") }
        let result = try await client.fetch(url, etag: nil, modified: nil, limit: StoreManifestValidator.maximumBytes)
        guard result.status == 200 else { throw StoreFailure.invalid("A new source must return a complete manifest.") }
        var source = try StoreManifestValidator().parse(result.data, sourceID: UUID(), url: url)
        if let identifier = source.identifier, state.sources.contains(where: { $0.identifier == identifier }) {
            throw StoreFailure.invalid("A source with this manifest identifier is already configured.")
        }
        source.refreshedAt = Date(); source.attemptedAt = source.refreshedAt
        source.etag = result.etag; source.modified = result.modified
        var next = state; next.sources.append(source)
        try commit(next)
    }
    func remove(_ id: UUID) throws {
        var next = try snapshot()
        next.sources.removeAll { $0.id == id }
        // Retain preferred source IDs deliberately. A missing preference must not silently fail over.
        try commit(next)
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        var next = try snapshot()
        guard let i = next.sources.firstIndex(where: { $0.id == id }) else { return }
        next.sources[i].enabled = enabled
        try commit(next)
    }
    func prefer(_ app: CatalogApp) throws {
        var next = try snapshot()
        guard next.sources.contains(where: { $0.id == app.sourceID && $0.enabled && $0.apps.contains(where: { $0.id == app.id }) }) else {
            throw StoreFailure.invalid("Choose an app from an enabled source.")
        }
        next.preferredSources[app.bundleID] = app.sourceID
        try commit(next)
    }
    func ignore(_ app: CatalogApp) throws {
        var next = try snapshot(); next.ignoredVersions[app.id] = app.latest.version; try commit(next)
    }
    func clearIgnored() throws { var next = try snapshot(); next.ignoredVersions = [:]; try commit(next) }
    func recordSearch(_ query: String) throws {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !query.isEmpty else { return }
        var next = try snapshot()
        next.recentSearches.removeAll { $0 == query }; next.recentSearches.insert(query, at: 0)
        next.recentSearches = Array(next.recentSearches.prefix(12)); try commit(next)
    }
    func clearHistory() throws {
        var next = try snapshot(); next.recentSearches = []; next.browsing = []; next.visits = [:]; try commit(next)
    }
    func visit(_ app: CatalogApp) throws {
        var next = try snapshot()
        next.browsing.removeAll { $0 == app.id }; next.browsing.insert(app.id, at: 0)
        next.browsing = Array(next.browsing.prefix(30))
        next.visits[app.id] = min(1_000_000, next.visits[app.id, default: 0] + 1)
        try commit(next)
    }
    func refresh(_ id: UUID, force: Bool = false, now: Date = Date()) async throws {
        _ = try snapshot()
        guard let source = state.sources.first(where: { $0.id == id }),
              force || (source.enabled && now.timeIntervalSince(source.attemptedAt ?? .distantPast) > 3600),
              refreshing.insert(id).inserted else { return }
        defer { refreshing.remove(id) }
        do {
            let result = try await client.fetch(source.url, etag: source.etag, modified: source.modified, limit: StoreManifestValidator.maximumBytes)
            var updated: CatalogSource
            if result.status == 304 { updated = source }
            else {
                updated = try StoreManifestValidator().parse(result.data, sourceID: id, url: source.url)
                guard updated.identifier == source.identifier else {
                    throw StoreFailure.invalid("The source identifier changed. Remove and add the source again to accept the new identity.")
                }
            }
            guard let i = state.sources.firstIndex(where: { $0.id == id }) else { return }
            updated.enabled = state.sources[i].enabled
            updated.refreshedAt = now; updated.attemptedAt = now; updated.health = .healthy; updated.problem = nil
            updated.etag = result.etag ?? (result.status == 304 ? source.etag : nil)
            updated.modified = result.modified ?? (result.status == 304 ? source.modified : nil)
            var next = state; next.sources[i] = updated; try commit(next)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard let i = state.sources.firstIndex(where: { $0.id == id }) else { return }
            var next = state
            next.sources[i].attemptedAt = now
            next.sources[i].health = error is URLError ? .offline : .warning
            next.sources[i].problem = error.localizedDescription
            try commit(next) // last known good apps remain available
            throw error
        }
    }
}
