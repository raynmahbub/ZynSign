import XCTest
@testable import ZynSign

final class StoreRepositoryTests: XCTestCase {
    func testAddValidatesBeforePersistingAndRejectsDuplicateURL() async throws {
        let client = StoreStubClient([.success(StoreHTTPResponse(data: Data("{}".utf8), status: 200, etag: nil, modified: nil)), StoreStubClient.ok()])
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: client)
        do { try await repository.add(StoreFixtures.url.absoluteString); XCTFail("Accepted malformed manifest") } catch {}
        let empty = try await repository.snapshot()
        XCTAssertTrue(empty.sources.isEmpty)
        try await repository.add(StoreFixtures.url.absoluteString)
        do { try await repository.add(StoreFixtures.url.absoluteString); XCTFail("Accepted duplicate") } catch {}
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.sources.count, 1)
    }
    func testManifestIdentifierPreventsDuplicateMirrors() async throws {
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: StoreStubClient([StoreStubClient.ok(), StoreStubClient.ok()]))
        try await repository.add(StoreFixtures.url.absoluteString)
        do { try await repository.add("https://mirror.example/catalog"); XCTFail("Duplicate identity accepted") } catch {}
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.sources.count, 1)
    }
    func testIncrementalRefreshUsesValidatorsAndSkipsFreshSources() async throws {
        let client = StoreStubClient([StoreStubClient.ok(), StoreStubClient.ok(Data(), status: 304)])
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: client)
        try await repository.add(StoreFixtures.url.absoluteString)
        let initial = try await repository.snapshot()
        let source = try XCTUnwrap(initial.sources.first)
        try await repository.refresh(source.id)
        var requests = await client.requests
        XCTAssertEqual(requests.count, 1)
        try await repository.refresh(source.id, force: true)
        requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.1, "test-tag")
        let refreshed = try await repository.snapshot()
        XCTAssertEqual(refreshed.sources[0].apps, source.apps)
    }
    func testFailedRefreshKeepsLastGoodSnapshotAndExplainsHealth() async throws {
        let client = StoreStubClient([StoreStubClient.ok(), .failure(URLError(.notConnectedToInternet)), StoreStubClient.ok(Data("bad".utf8))])
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: client)
        try await repository.add(StoreFixtures.url.absoluteString)
        let initial = try await repository.snapshot()
        let id = initial.sources[0].id
        do { try await repository.refresh(id, force: true); XCTFail("Expected network failure") } catch {}
        var cached = try await repository.snapshot()
        XCTAssertEqual(cached.sources[0].health, .offline)
        XCTAssertEqual(cached.sources[0].apps, initial.sources[0].apps)
        do { try await repository.refresh(id, force: true); XCTFail("Expected parse failure") } catch {}
        cached = try await repository.snapshot()
        XCTAssertEqual(cached.sources[0].health, .warning)
        XCTAssertNotNil(cached.sources[0].problem)
        XCTAssertEqual(cached.sources[0].apps, initial.sources[0].apps)
    }
    func testRemovingPreferredSourceDoesNotSwitchRepositories() async throws {
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: StoreStubClient([StoreStubClient.ok()]))
        try await repository.add(StoreFixtures.url.absoluteString)
        let state = try await repository.snapshot()
        let source = state.sources[0], app = source.apps[0]
        try await repository.prefer(app)
        try await repository.remove(source.id)
        let removed = try await repository.snapshot()
        XCTAssertTrue(removed.sources.isEmpty)
        XCTAssertEqual(removed.preferredSources[app.bundleID], source.id)
    }
    func testDiskFailureDoesNotCommitAnAddedSourceInMemory() async throws {
        let storage = StoreMemoryStorage(); storage.rejectSaves = true
        let repository = StoreRepository(storage: storage, client: StoreStubClient([StoreStubClient.ok()]))
        do { try await repository.add(StoreFixtures.url.absoluteString); XCTFail("Expected disk failure") } catch {}
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.sources.isEmpty)
    }
    func testSavedItemsPersistSourceScopedListingIDsAndCanBeRemoved() async throws {
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: StoreStubClient([StoreStubClient.ok()]))
        try await repository.add(StoreFixtures.url.absoluteString)
        let initial = try await repository.snapshot()
        let app = try XCTUnwrap(initial.sources.first?.apps.first)
        try await repository.setSaved(app, true)
        let saved = try await repository.snapshot()
        XCTAssertEqual(saved.savedAppIDs, [app.id])
        try await repository.setSaved(app, false)
        let removed = try await repository.snapshot()
        XCTAssertEqual(removed.savedAppIDs, [])
    }

    func testHistoryIsBoundedAndCanBeCleared() async throws {
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: StoreStubClient([]))
        for index in 0..<20 { try await repository.recordSearch("Query \(index)") }
        try await repository.recordSearch("Query 15")
        let state = try await repository.snapshot()
        XCTAssertEqual(state.recentSearches.count, 12)
        XCTAssertEqual(state.recentSearches.first, "Query 15")
        try await repository.clearHistory()
        let cleared = try await repository.snapshot()
        XCTAssertTrue(cleared.recentSearches.isEmpty)
    }
    func testInFlightRefreshCannotResurrectRemovedSource() async throws {
        let started = expectation(description: "Refresh started")
        let client = StoreGatedClient(started: started)
        let repository = StoreRepository(storage: StoreMemoryStorage(), client: client)
        try await repository.add(StoreFixtures.url.absoluteString)
        let state = try await repository.snapshot()
        let id = state.sources[0].id
        let task = Task { try await repository.refresh(id, force: true) }
        await fulfillment(of: [started], timeout: 2)
        try await repository.remove(id)
        await client.finish()
        try await task.value
        let removed = try await repository.snapshot()
        XCTAssertTrue(removed.sources.isEmpty)
    }
}
private actor StoreGatedClient: StoreFetching {
    private var first = true
    private var pending: CheckedContinuation<StoreHTTPResponse, Never>?
    let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }
    func fetch(_ url: URL, etag: String?, modified: String?, limit: Int) async throws -> StoreHTTPResponse {
        if first { first = false; return try StoreStubClient.ok().get() }
        return await withCheckedContinuation { continuation in
            pending = continuation; started.fulfill()
        }
    }
    func finish() {
        pending?.resume(returning: StoreHTTPResponse(data: StoreFixtures.manifest, status: 200, etag: nil, modified: nil))
        pending = nil
    }
}
