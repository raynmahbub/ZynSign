import XCTest
@testable import ZynSign

final class FileStoreCacheTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StoreTests-\(UUID())")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func testColdOfflineLaunchRetainsMetadataPreferencesAndHistory() throws {
        let cache = FileStoreCache(directory: directory)
        var state = StoreSnapshot(); let source = try StoreFixtures.source()
        state.sources = [source]; state.preferredSources[source.apps[0].bundleID] = source.id
        state.recentSearches = ["orbit"]; state.browsing = [source.apps[0].id]
        try cache.save(state)
        let restored = try FileStoreCache(directory: directory).load()
        XCTAssertEqual(restored.sources, state.sources)
        XCTAssertEqual(restored.preferredSources, state.preferredSources)
        XCTAssertEqual(restored.browsing, state.browsing)
        XCTAssertEqual(restored.recentSearches, state.recentSearches)
    }
    func testCorruptCacheIsReportedAndNeverSilentlyReset() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("catalog-v1.json")
        let bytes = Data("not JSON".utf8); try bytes.write(to: file)
        XCTAssertThrowsError(try FileStoreCache(directory: directory).load())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testUnsupportedSchemaIsRefused() throws {
        var state = StoreSnapshot(); state.schema = 999
        let cache = FileStoreCache(directory: directory); try cache.save(state)
        XCTAssertThrowsError(try cache.load())
    }
    func testEmptyReleaseInCacheCannotReachLatestAccessor() throws {
        var state = StoreSnapshot(); var source = try StoreFixtures.source(); let app = source.apps[0]
        source.apps = [CatalogApp(sourceID: source.id, bundleID: app.bundleID, name: app.name, developer: app.developer,
            subtitle: nil, description: "", iconURL: nil, screenshots: [], category: "Utilities", releases: [], featured: false)]
        state.sources = [source]
        let cache = FileStoreCache(directory: directory); try cache.save(state)
        XCTAssertThrowsError(try cache.load())
    }
}
