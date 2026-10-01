import XCTest
@testable import ZynSign

/// Tests for the in-app version history catalog.
final class VersionHistoryCatalogTests: XCTestCase {

    func testEntriesAreNewestFirst() {
        let entries = VersionHistoryCatalog.entries
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.tag, "v0.0.1")
        XCTAssertEqual(entries.last?.tag, "v0.0.1-dev.1")
    }

    func testEveryEntryCarriesReadableContent() {
        for entry in VersionHistoryCatalog.entries {
            XCTAssertFalse(entry.headline.isEmpty, entry.tag)
            XCTAssertFalse(entry.highlights.isEmpty, entry.tag)
            XCTAssertFalse(entry.marketingVersion.isEmpty, entry.tag)
            XCTAssertGreaterThan(entry.buildNumber, 0, entry.tag)
        }
    }

    func testCurrentTagMarksExactlyOneEntry() {
        let marked = VersionHistoryCatalog.entries(currentTag: ReleaseTrain.current.tag)
        XCTAssertEqual(marked.filter(\.isCurrent).count, 1)
        XCTAssertEqual(marked.first(where: \.isCurrent)?.tag, ReleaseTrain.current.tag)
    }

    func testUnknownTagMarksNothing() {
        let marked = VersionHistoryCatalog.entries(currentTag: "v9.9.9")
        XCTAssertTrue(marked.allSatisfy { !$0.isCurrent })
    }
}
