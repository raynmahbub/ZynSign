import XCTest
@testable import ZynSign

final class StoreUpdatePolicyTests: XCTestCase {
    func testUpdatesRequireExplicitPreferenceEvenWithOnlyOneSource() throws {
        var state = StoreSnapshot()
        let source = try StoreFixtures.source(), app = source.apps[0]
        state.sources = [source]
        let installed = [app.bundleID: "2.2"]
        XCTAssertTrue(CatalogUpdatePolicy.updates(in: state, installed: installed).isEmpty)
        state.preferredSources[app.bundleID] = source.id
        XCTAssertEqual(CatalogUpdatePolicy.updates(in: state, installed: installed).first?.app.id, app.id)
    }
    func testDisabledRemovedAndOtherSourcesNeverBecomeUpdateFallbacks() throws {
        var state = StoreSnapshot()
        let source = try StoreFixtures.source(), other = try StoreFixtures.source()
        let app = source.apps[0]
        state.sources = [source, other]; state.preferredSources[app.bundleID] = source.id
        state.sources[0].enabled = false
        XCTAssertTrue(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.2"]).isEmpty)
        state.sources.removeFirst()
        XCTAssertTrue(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.2"]).isEmpty)
    }
    func testIgnoreIsVersionAndSourceScoped() throws {
        var state = StoreSnapshot()
        let first = try StoreFixtures.source(), second = try StoreFixtures.source()
        let app = first.apps[0]
        state.sources = [first, second]; state.preferredSources[app.bundleID] = first.id
        state.ignoredVersions[app.id] = "2.3"
        XCTAssertTrue(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.2"]).isEmpty)
        state.preferredSources[app.bundleID] = second.id
        XCTAssertEqual(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.2"]).count, 1)
        state.preferredSources[app.bundleID] = first.id
        state.ignoredVersions[app.id] = "2.2"
        XCTAssertEqual(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.2"]).count, 1)
        XCTAssertTrue(CatalogUpdatePolicy.updates(in: state, installed: [app.bundleID: "2.3"]).isEmpty)
    }
}
