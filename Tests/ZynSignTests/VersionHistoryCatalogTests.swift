import XCTest
@testable import ZynSign

/// Tests for the in-app version history catalog.
final class VersionHistoryCatalogTests: XCTestCase {

    func testEntriesAreNewestFirst() {
        let entries = VersionHistoryCatalog.entries
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.tag, ReleaseTrain.current.tag)
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

    /// The catalog is a list of releases that happened. A stop the train has
    /// not reached must not appear in it — the version history once carried a
    /// `v0.1.0-alpha.3` row for a build that was never tagged, between `dev.2`
    /// and `dev.1`, and nothing failed.
    func testEntriesFollowTheTrainAndNeverRunAheadOfIt() throws {
        let stages = ReleaseStage.allCases
        let currentIndex = try XCTUnwrap(stages.firstIndex(of: ReleaseTrain.current))
        var previousIndex: Int?
        var previousBuild: Int?

        for entry in VersionHistoryCatalog.entries {
            let identifier = entry.tag.hasPrefix("v") ? String(entry.tag.dropFirst()) : entry.tag
            let stage = try XCTUnwrap(ReleaseStage(identifier: identifier),
                                      "\(entry.tag) is not a stop on the release train")
            let index = try XCTUnwrap(stages.firstIndex(of: stage))
            XCTAssertLessThanOrEqual(
                index, currentIndex,
                "\(entry.tag) is listed as shipped, but the train is at \(ReleaseTrain.current.tag)"
            )
            if let previousIndex {
                XCTAssertLessThan(index, previousIndex, "\(entry.tag) is out of order")
            }
            if let previousBuild {
                XCTAssertLessThan(
                    entry.buildNumber, previousBuild,
                    "\(entry.tag) carries build \(entry.buildNumber), which does not increase over the newer entry"
                )
            }
            previousIndex = index
            previousBuild = entry.buildNumber
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
