import XCTest
@testable import ZynSign

final class StoreCatalogTests: XCTestCase {
    func testSearchCombinesCategoryAndAllDeclaredSearchFields() throws {
        let source = try StoreFixtures.source()
        XCTAssertEqual(source.apps[0].keywords, ["navigation", "stellar planner"])
        XCTAssertEqual(source.apps[0].developerIconURL?.absoluteString, "https://source.example/mira.png")
        let index = CatalogSearchIndex(sources: [source])
        for query in ["orbit", "mira", "org.example.orbit", "development", "independent shelf", "ORBIT Mira", "useful tool", "stellar planner", "source.example/catalog.json"] {
            XCTAssertEqual(index.search(query, category: "Development").count, 1, query)
            XCTAssertTrue(index.search(query, category: "Games").isEmpty)
        }
    }
    func testBoundedTypoTolerance() throws {
        let index = CatalogSearchIndex(sources: [try StoreFixtures.source()])
        XCTAssertEqual(index.search("orbt").count, 1)
        XCTAssertEqual(index.search("orbitt").count, 1)
        XCTAssertTrue(index.search("oxtt").isEmpty)
    }
    func testDuplicateAppsRemainDistinctAndDisabledSourcesAreExcluded() throws {
        let one = try StoreFixtures.source()
        var two = try StoreFixtures.source()
        XCTAssertNotEqual(one.apps[0].id, two.apps[0].id)
        let index = CatalogSearchIndex(sources: [one, two])
        XCTAssertEqual(index.search("orbit").count, 2)
        XCTAssertEqual(index.search("orbit", sourceID: one.id).map(\.sourceID), [one.id])
        two.enabled = false
        XCTAssertEqual(CatalogSearchIndex(sources: [one, two]).search("").count, 1)
    }
    func testVersionComparisonDoesNotInventOrderingForMarketingStrings() {
        XCTAssertTrue(CatalogVersion.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(CatalogVersion.isNewer("1.0.0", than: "1"))
        XCTAssertFalse(CatalogVersion.isNewer("2-beta", than: "1.9"))
        XCTAssertFalse(CatalogVersion.isNewer("2.0", than: "preview"))
        XCTAssertFalse(CatalogVersion.isNewer("1..0", than: "1"))
    }
    func testSourceHealthTracksFreshnessAndEmptyCatalogsNotLatency() throws {
        var source = try StoreFixtures.source()
        let now = Date()
        source.refreshedAt = now
        XCTAssertEqual(source.status(at: now), .healthy)
        XCTAssertEqual(source.status(at: now.addingTimeInterval(8 * 86400)), .warning)
        source.apps = []
        XCTAssertEqual(source.status(at: now), .warning)
        source.health = .offline
        XCTAssertEqual(source.status(at: now), .offline)
    }
    func testSharedQueueCapacityNeverExceedsBound() {
        XCTAssertTrue(JobQueueCapacity.hasCapacity(running: 0, limit: 1))
        XCTAssertFalse(JobQueueCapacity.hasCapacity(running: 1, limit: 1))
        XCTAssertFalse(JobQueueCapacity.hasCapacity(running: 0, limit: 0))
    }
}
