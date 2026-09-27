import XCTest
@testable import ZynSign

final class StoreManifestValidatorTests: XCTestCase {
    func testModernFeedHasSourceScopedIdentityHistoryAndArtwork() throws {
        let source = try StoreFixtures.source()
        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.sourceID, source.id)
        XCTAssertTrue(app.id.contains(source.id.uuidString))
        XCTAssertEqual(app.latest.version, "2.3")
        XCTAssertEqual(app.releases.count, 2)
        XCTAssertNotNil(app.latest.date)
        XCTAssertEqual(app.screenshots.count, 2)
        XCTAssertTrue(app.featured)
    }
    func testLegacySingleVersionFieldsAreAdapted() throws {
        let data = Data(#"{"name":"Legacy","apps":[{"name":"App","bundleIdentifier":"org.example.app","developerName":"Dev","version":"1.0","versionDate":"2026-09-01","downloadURL":"https://example.org/app.ipa","versionDescription":"First release"}]}"#.utf8)
        let source = try StoreManifestValidator().parse(data, sourceID: UUID(), url: StoreFixtures.url)
        XCTAssertEqual(source.apps[0].latest.notes, "First release")
        XCTAssertEqual(source.apps[0].releases.count, 1)
    }
    func testURLPolicyRejectsUnsafeOrAmbiguousAddresses() {
        for value in ["example.org", "http://example.org", "file:///tmp/app", "javascript:alert(1)", "https://user:pass@example.org/a", "https://example.org/a#fragment", "https://example.org:8443/a", "https://example.org/a b", "https://"] {
            XCTAssertThrowsError(try StoreURLPolicy.validate(value), value)
        }
    }
    func testURLCanonicalizationDetectsEquivalentHostsAndDefaultPorts() throws {
        XCTAssertEqual(try StoreURLPolicy.validate(" HTTPS://EXAMPLE.ORG:443 "), try StoreURLPolicy.validate("https://example.org/"))
    }
    func testRequiredFieldsAreNotSilentlyDefaulted() throws {
        for field in ["name", "bundleIdentifier", "developerName"] {
            let missing = try StoreFixtures.changedApp { $0.removeValue(forKey: field) }
            XCTAssertThrowsError(try parse(missing), field)
            let empty = try StoreFixtures.changedApp { $0[field] = " " }
            XCTAssertThrowsError(try parse(empty), field)
        }
        XCTAssertThrowsError(try parse(Data(#"{"apps":[]}"#.utf8)))
    }
    func testMalformedOneAppRejectsWholeSource() throws {
        let data = try StoreFixtures.changed { object in
            var apps = object["apps"] as! [[String: Any]]
            apps.append(["name": "Broken"]); object["apps"] = apps
        }
        XCTAssertThrowsError(try parse(data))
    }
    func testDuplicateBundleAndVersionAreRejected() throws {
        let bundles = try StoreFixtures.changed { $0["apps"] = ($0["apps"] as! [[String: Any]]) + ($0["apps"] as! [[String: Any]]) }
        XCTAssertThrowsError(try parse(bundles))
        let releases = try StoreFixtures.changedApp { app in
            let versions = app["versions"] as! [[String: Any]]; app["versions"] = [versions[0], versions[0]]
        }
        XCTAssertThrowsError(try parse(releases))
    }
    func testEmptyReleasesAndInvalidDatesSizesAndDownloadURLsAreRejected() throws {
        XCTAssertThrowsError(try parse(StoreFixtures.changedApp { $0["versions"] = [] }))
        for (key, value) in [("date", "2026-02-30" as Any), ("size", -1), ("size", 5_000_000_000 as Int64), ("downloadURL", "http://example.org/a.ipa"), ("minOSVersion", "seventeen")] {
            let data = try StoreFixtures.changedApp { app in
                var versions = app["versions"] as! [[String: Any]]; versions[0][key] = value; app["versions"] = versions
            }
            XCTAssertThrowsError(try parse(data), key)
        }
    }
    func testUnsafeArtworkAndMalformedKnownOptionalFieldsAreRejected() throws {
        for (field, value) in [("iconURL", "file:///etc/hosts" as Any), ("screenshotURLs", ["javascript:bad"]), ("category", 42)] {
            XCTAssertThrowsError(try parse(StoreFixtures.changedApp { $0[field] = value }))
        }
    }
    func testManifestByteLimitIsEnforcedBeforeDecoding() {
        XCTAssertThrowsError(try parse(Data(repeating: 32, count: StoreManifestValidator.maximumBytes + 1)))
    }
    func testUnknownExtensionsDoNotRequireReplacingTheAdapter() throws {
        let source = try parse(StoreFixtures.changed { $0["communityRating"] = ["score": 4.8] })
        XCTAssertEqual(source.apps.count, 1)
    }
    private func parse(_ data: Data) throws -> CatalogSource {
        try StoreManifestValidator().parse(data, sourceID: UUID(), url: StoreFixtures.url)
    }
}
