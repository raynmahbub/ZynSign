import Foundation

struct FileStoreCache: StorePersisting {
    let directory: URL
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Store", isDirectory: true)
    }
    private var file: URL { directory.appendingPathComponent("catalog-v1.json") }
    func load() throws -> StoreSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return StoreSnapshot() }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw StoreFailure.invalid("The Store cache exceeds its size limit.") }
        let data = try Data(contentsOf: file)
        let state = try JSONDecoder().decode(StoreSnapshot.self, from: data)
        guard state.schema == 1, state.sources.count <= 64,
              (state.savedAppIDs?.count ?? 0) <= 30_000,
              Set(state.savedAppIDs ?? []).count == (state.savedAppIDs?.count ?? 0),
              Set(state.sources.map(\.id)).count == state.sources.count,
              Set(state.sources.map(\.url)).count == state.sources.count else {
            throw StoreFailure.invalid("The Store cache is invalid or from a newer version. It has not been overwritten.")
        }
        // Cached metadata is untrusted too; validate safety-critical invariants before use.
        for source in state.sources {
            _ = try StoreURLPolicy.validate(source.url.absoluteString)
            if let icon = source.iconURL { _ = try StoreURLPolicy.validate(icon.absoluteString) }
            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.name.count <= 200,
                  source.apps.count <= StoreManifestValidator.maximumApps,
                  Set(source.apps.map(\.id)).count == source.apps.count else { throw StoreFailure.invalid("Invalid cached app list.") }
            for app in source.apps {
                guard app.sourceID == source.id, !app.name.isEmpty, app.name.count <= 200,
                      !app.bundleID.isEmpty, app.bundleID.count <= 255,
                      !app.developer.isEmpty, app.developer.count <= 200,
                      (app.keywords?.count ?? 0) <= 64,
                      (app.keywords?.allSatisfy { !$0.isEmpty && $0.count <= 100 } ?? true),
                      !app.category.isEmpty, app.category.count <= 100, app.description.count <= 100_000,
                      !app.releases.isEmpty, app.releases.count <= 200,
                      Set(app.releases.map(\.version)).count == app.releases.count, app.screenshots.count <= 30 else { throw StoreFailure.invalid("Invalid cached app metadata.") }
                for release in app.releases {
                    guard !release.version.isEmpty, release.version.count <= 100,
                          (release.notes?.count ?? 0) <= 100_000,
                          (release.size.map { $0 > 0 && $0 <= 4 * 1024 * 1024 * 1024 } ?? true),
                          (release.minOSVersion.map { CatalogVersion.components($0) != nil } ?? true),
                          (release.maxOSVersion.map { CatalogVersion.components($0) != nil } ?? true) else {
                        throw StoreFailure.invalid("Invalid cached release metadata.")
                    }
                }
                for url in app.screenshots + [app.iconURL, app.developerIconURL].compactMap({ $0 }) + app.releases.map(\.downloadURL) {
                    _ = try StoreURLPolicy.validate(url.absoluteString)
                }
            }
        }
        return state
    }
    func save(_ snapshot: StoreSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 128 * 1024 * 1024 else { throw StoreFailure.invalid("The Store cache is full. Remove a source before adding more.") }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Prototype sources were saved before validation. Offer their URLs for explicit
/// validation; do not silently promote them to accepted repositories or delete them.
struct LegacyStoreSource: Decodable, Identifiable {
    let id: String
    let name: String
    let url: String
}
extension FileStoreCache {
    static func legacyCandidates() throws -> [LegacyStoreSource] {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ZynSignSources.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 else { throw StoreFailure.invalid("The previous source list is too large to migrate. It has been left untouched.") }
        let sources = try JSONDecoder().decode([LegacyStoreSource].self, from: Data(contentsOf: file))
        guard sources.count <= 64 else { throw StoreFailure.invalid("The previous source list has more than 64 sources. It has been left untouched.") }
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }
}
