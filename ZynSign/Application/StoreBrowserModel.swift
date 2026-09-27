import Foundation
import Combine

@MainActor
final class StoreBrowserModel: ObservableObject {
    @Published private(set) var snapshot = StoreSnapshot()
    @Published private(set) var apps: [CatalogApp] = []
    @Published private(set) var installed: [String: String] = [:]
    @Published private(set) var refreshing = Set<UUID>()
    @Published private(set) var liveSources = Set<UUID>()
    @Published private(set) var adding = false
    @Published private(set) var legacySources: [LegacyStoreSource] = []
    @Published var problem: String?
    let repository: StoreRepository
    let downloads: StoreDownloadQueue
    private var searchIndex = CatalogSearchIndex(sources: [])
    private var loaded = false
    private var loading = false
    let categories = ["Utilities", "Games", "Productivity", "Social", "Development", "Entertainment", "Education"]

    nonisolated init(repository: StoreRepository, downloads: StoreDownloadQueue) {
        self.repository = repository; self.downloads = downloads
    }
    func load(library: ApplicationLibrary) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        downloads.restore()
        do {
            try await reload()
            try await loadInstalled(library)
            if !loaded {
                loaded = true
                do { legacySources = try FileStoreCache.legacyCandidates() }
                catch { problem = error.localizedDescription }
                await refreshDue()
            }
        } catch { problem = error.localizedDescription }
    }
    func loadInstalled(_ library: ApplicationLibrary) async throws {
        let entries = try await library.entries()
        var versions: [String: String] = [:]
        for entry in entries where entry.isArtifactAvailable {
            guard let version = entry.record.identity.shortVersionString else { continue }
            let bundle = entry.record.bundleIdentifier.rawValue
            if let previous = versions[bundle] {
                if CatalogVersion.isNewer(version, than: previous) { versions[bundle] = version }
            } else { versions[bundle] = version }
        }
        installed = versions
    }
    private func reload() async throws {
        let updated = try await repository.snapshot()
        guard updated.revision >= snapshot.revision else { return }
        let catalogChanged = !snapshot.sources.elementsEqual(updated.sources) { before, after in
            before.id == after.id && before.enabled == after.enabled && before.name == after.name && before.apps == after.apps
        }
        snapshot = updated
        if catalogChanged {
            searchIndex = CatalogSearchIndex(sources: snapshot.sources)
            apps = searchIndex.search("")
        }
    }
    var migrationCandidates: [LegacyStoreSource] {
        legacySources.filter { old in
            !snapshot.sources.contains { $0.url == (try? StoreURLPolicy.validate(old.url)) }
        }
    }
    func search(_ query: String, category: String?) -> [CatalogApp] { searchIndex.search(query, category: category) }
    func source(_ app: CatalogApp) -> CatalogSource? { snapshot.sources.first { $0.id == app.sourceID } }
    func sourceName(_ app: CatalogApp) -> String { source(app)?.name ?? "Removed source" }
    func variants(_ app: CatalogApp) -> [CatalogApp] { apps.filter { $0.bundleID == app.bundleID } }
    var updates: [CatalogUpdate] {
        CatalogUpdatePolicy.updates(in: snapshot, installed: installed)
    }
    var needsSourceChoice: [CatalogApp] {
        var seen = Set<String>()
        return apps.filter { installed[$0.bundleID] != nil && snapshot.preferredSources[$0.bundleID] == nil && seen.insert($0.bundleID).inserted }
    }
    var continueBrowsing: [CatalogApp] {
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        return snapshot.browsing.compactMap { byID[$0] }
    }
    var trending: [CatalogApp] {
        apps.filter { snapshot.visits[$0.id, default: 0] > 0 }.sorted { snapshot.visits[$0.id, default: 0] > snapshot.visits[$1.id, default: 0] }
    }
    func add(_ raw: String) async -> Bool {
        guard !adding else { return false }
        adding = true; defer { adding = false }
        do {
            try await repository.add(raw); try await reload()
            if let url = try? StoreURLPolicy.validate(raw), let source = snapshot.sources.first(where: { $0.url == url }) { liveSources.insert(source.id) }
            return true
        } catch { problem = error.localizedDescription; return false }
    }
    func refresh(_ id: UUID, force: Bool = true) async {
        guard refreshing.insert(id).inserted else { return }
        defer { refreshing.remove(id) }
        do { try await repository.refresh(id, force: force); try await reload()
            if sourceIsFresh(id) { liveSources.insert(id) }
        } catch is CancellationError {
            return
        } catch {
            liveSources.remove(id)
            problem = error.localizedDescription
            do { try await reload() } catch { problem = error.localizedDescription }
        }
    }
    private func sourceIsFresh(_ id: UUID) -> Bool {
        snapshot.sources.contains { $0.id == id && $0.health == .healthy && Date().timeIntervalSince($0.refreshedAt ?? .distantPast) < 60 }
    }
    /// Mission Control uses the same incremental refresh path, not a second fetcher.
    func refreshForMaintenance() async -> Int {
        do { try await reload() } catch { problem = error.localizedDescription; return -1 }
        let due = snapshot.sources.filter { $0.enabled && Date().timeIntervalSince($0.attemptedAt ?? .distantPast) > 3600 }
        var count = 0
        for source in due {
            await refresh(source.id, force: false)
            guard snapshot.sources.first(where: { $0.id == source.id })?.health == .healthy else { return -1 }
            count += 1
        }
        return count
    }
    func refreshDue() async {
        // One bounded request at a time; unchanged sources use conditional requests.
        for source in snapshot.sources where source.enabled && Date().timeIntervalSince(source.attemptedAt ?? .distantPast) > 3600 {
            if Task.isCancelled { break }
            await refresh(source.id, force: false)
        }
    }
    func remove(_ id: UUID) async { await mutate { try await self.repository.remove(id) }; liveSources.remove(id) }
    func enable(_ id: UUID, _ enabled: Bool) async { await mutate { try await self.repository.setEnabled(id, enabled) } }
    func prefer(_ app: CatalogApp) async { await mutate { try await self.repository.prefer(app) } }
    func ignore(_ app: CatalogApp) async { await mutate { try await self.repository.ignore(app) } }
    func clearIgnored() async { await mutate { try await self.repository.clearIgnored() } }
    func visit(_ app: CatalogApp) async { await mutate { try await self.repository.visit(app) } }
    func recordSearch(_ query: String) async { await mutate { try await self.repository.recordSearch(query) } }
    func clearHistory() async { await mutate { try await self.repository.clearHistory() } }
    private func mutate(_ action: () async throws -> Void) async {
        do { try await action(); try await reload() } catch { problem = error.localizedDescription }
    }
    func download(_ app: CatalogApp) {
        guard source(app)?.enabled == true, apps.contains(where: { $0.id == app.id && $0.latest == app.latest }) else {
            problem = "This listing changed or its source is no longer enabled. Reopen the app details before downloading."; return
        }
        _ = downloads.enqueue(app, sourceName: sourceName(app))
    }
    func updateAll() { for update in updates { download(update.app) } }
}
