import XCTest
@testable import ZynSign

/// Tests for the release feed parser and reference handling.
final class ReleaseFeedParserTests: XCTestCase {

    private let feedJSON = """
    [
      {
        "tag_name": "v1.2.0",
        "name": "Release 1.2",
        "published_at": "2026-09-20T10:00:00Z",
        "prerelease": false,
        "draft": false,
        "assets": [
          { "name": "App-1.2.ipa", "size": 1234, "browser_download_url": "https://example.com/App-1.2.ipa", "content_type": "application/octet-stream" },
          { "name": "notes.txt", "size": 90, "browser_download_url": "https://example.com/notes.txt", "content_type": "text/plain" }
        ]
      },
      {
        "tag_name": "v1.3.0-beta",
        "name": "",
        "published_at": "2026-09-25T10:00:00.500Z",
        "prerelease": true,
        "draft": false,
        "assets": []
      },
      {
        "tag_name": "v1.4.0",
        "name": "Draft",
        "published_at": null,
        "prerelease": false,
        "draft": true,
        "assets": []
      },
      {
        "name": "untagged"
      }
    ]
    """

    func testParsesEntriesAndDropsDraftsAndUntagged() throws {
        guard case .success(let entries) = ReleaseFeedParser.parse(Data(feedJSON.utf8)) else {
            return XCTFail("The fixture must parse.")
        }
        XCTAssertEqual(entries.map(\.tag), ["v1.2.0", "v1.3.0-beta"])
        XCTAssertEqual(entries[0].title, "Release 1.2")
        XCTAssertEqual(entries[1].title, "v1.3.0-beta", "An empty release name falls back to the tag.")
        XCTAssertTrue(entries[1].isPrerelease)
        XCTAssertNotNil(entries[0].publishedAt)
        XCTAssertNotNil(entries[1].publishedAt, "Fractional-second dates must parse.")
    }

    func testDraftsSurviveWhenAsked() {
        guard case .success(let entries) = ReleaseFeedParser.parse(Data(feedJSON.utf8), includeDrafts: true) else {
            return XCTFail("The fixture must parse.")
        }
        XCTAssertTrue(entries.contains { $0.isDraft })
    }

    func testPackageAssetPrefersIPA() throws {
        guard case .success(let entries) = ReleaseFeedParser.parse(Data(feedJSON.utf8)) else {
            return XCTFail("The fixture must parse.")
        }
        XCTAssertEqual(entries[0].packageAsset?.name, "App-1.2.ipa")
        XCTAssertNil(entries[1].packageAsset)
    }

    func testBareVersionStripsTheLeadingV() {
        let entry = ReleaseFeedEntry(tag: "v2.1.0", title: "x", publishedAt: nil, isPrerelease: false, isDraft: false, assets: [])
        XCTAssertEqual(entry.bareVersion, "2.1.0")
    }

    func testInvalidJSONRefuses() {
        guard case .failure(let failure) = ReleaseFeedParser.parse(Data("not json".utf8)) else {
            return XCTFail("Invalid JSON must refuse.")
        }
        XCTAssertEqual(failure, .invalidJSON)
    }

    func testEmptyListingRefuses() {
        guard case .failure(let failure) = ReleaseFeedParser.parse(Data("[]".utf8)) else {
            return XCTFail("An empty listing must refuse.")
        }
        XCTAssertEqual(failure, .noEntries)
    }

    func testReferenceParsing() {
        XCTAssertNotNil(ReleaseFeedReference(ownerSlashName: "acme/launcher"))
        XCTAssertNil(ReleaseFeedReference(ownerSlashName: "acme"))
        XCTAssertNil(ReleaseFeedReference(ownerSlashName: "acme/launcher/extra"))
        XCTAssertNil(ReleaseFeedReference(ownerSlashName: " /launcher"))
        XCTAssertNil(ReleaseFeedReference(ownerSlashName: "acme/ "))
        let reference = ReleaseFeedReference(ownerSlashName: "acme/launcher")
        XCTAssertEqual(reference?.releasesAPIURL?.absoluteString, "https://api.github.com/repos/acme/launcher/releases?per_page=25")
        XCTAssertEqual(reference?.id, "acme/launcher")
    }

    func testOffersCarryTheTrackedBundleIdentifier() {
        var reference = ReleaseFeedReference(owner: "acme", repository: "launcher")
        reference.trackedBundleIdentifier = "com.acme.launcher"
        let snapshot = ReleaseFeedSnapshot(
            reference: reference,
            entries: [ReleaseFeedEntry(tag: "v1.1", title: "x", publishedAt: nil, isPrerelease: false, isDraft: false, assets: [])],
            fetchedAt: Date()
        )
        let offers = LibraryUpdateTracker.offers(from: snapshot)
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.bundleIdentifier, "com.acme.launcher")
        XCTAssertEqual(offers.first?.sourceName, "acme/launcher")
    }

    func testUpdateTrackerMatchesByBundleIdentifierOnly() {
        let installed = [
            LibraryUpdateTracker.InstalledApp(appName: "App", bundleIdentifier: "com.acme.app", version: "1.0"),
            LibraryUpdateTracker.InstalledApp(appName: "Other", bundleIdentifier: "com.other.app", version: "1.0"),
        ]
        let offers = [
            LibraryUpdateTracker.OfferedRelease(version: "1.1", sourceName: "feed", bundleIdentifier: "com.acme.app", downloadURL: nil),
            LibraryUpdateTracker.OfferedRelease(version: "9.9", sourceName: "feed", bundleIdentifier: nil, downloadURL: nil),
        ]
        let updates = LibraryUpdateTracker.availableUpdates(installed: installed, offers: offers)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.bundleIdentifier, "com.acme.app")
        XCTAssertEqual(updates.first?.availableVersion, "1.1")
    }

    func testUpdateTrackerNeverReportsDowngradesOrGuesses() {
        let installed = [
            LibraryUpdateTracker.InstalledApp(appName: "App", bundleIdentifier: "com.acme.app", version: "2.0"),
        ]
        let older = [
            LibraryUpdateTracker.OfferedRelease(version: "1.9", sourceName: "feed", bundleIdentifier: "com.acme.app", downloadURL: nil),
        ]
        XCTAssertTrue(LibraryUpdateTracker.availableUpdates(installed: installed, offers: older).isEmpty)
        let unparseable = [
            LibraryUpdateTracker.OfferedRelease(version: "nightly", sourceName: "feed", bundleIdentifier: "com.acme.app", downloadURL: nil),
        ]
        XCTAssertTrue(LibraryUpdateTracker.availableUpdates(installed: installed, offers: unparseable).isEmpty)
    }
}
