import XCTest
@testable import ZynSign

final class ApplicationBundleDiscoveryTests: XCTestCase {

    func testDiscoversSingleBundleUnderPayload() {
        let discovery = ApplicationBundleDiscovery.discover(in: validPackageEntryTable())
        XCTAssertTrue(discovery.payloadPresent)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Example.app")])
        XCTAssertEqual(discovery.outcome, .exactlyOne(makePath("Payload/Example.app")))
    }

    func testDoesNotAssumeAParticularApplicationName() {
        let table = validPackageEntryTable(bundleName: "Another Name.app")
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Another Name.app")])
    }

    func testMatchesApplicationSuffixCaseInsensitively() {
        let table = validPackageEntryTable(bundleName: "Example.APP")
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Example.APP")])
    }

    func testDiscoveryIsIndependentOfContainerEntryOrder() {
        let forward = validPackageEntryTable()
        let reversed = Array(forward.reversed())
        let shuffled = [forward[2], forward[0], forward[3], forward[1]]
        XCTAssertEqual(
            ApplicationBundleDiscovery.discover(in: forward).bundleCandidates,
            ApplicationBundleDiscovery.discover(in: reversed).bundleCandidates
        )
        XCTAssertEqual(
            ApplicationBundleDiscovery.discover(in: forward).bundleCandidates,
            ApplicationBundleDiscovery.discover(in: shuffled).bundleCandidates
        )
    }

    func testReportsMissingPayloadDirectory() {
        let table = [
            makeEntry("Unpacked", kind: .directory),
            makeEntry("Unpacked/Example.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertFalse(discovery.payloadPresent)
        XCTAssertEqual(discovery.outcome, .missingPayloadDirectory)
        XCTAssertEqual(discovery.misplacedBundleDirectories, [makePath("Unpacked/Example.app")])
    }

    func testReportsEmptyPayloadDirectory() {
        let table = [makeEntry("Payload", kind: .directory)]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.payloadPresent)
        XCTAssertTrue(discovery.bundleCandidates.isEmpty)
        XCTAssertEqual(discovery.outcome, .none)
    }

    func testReportsAmbiguousCandidatesWithoutChoosing() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/Second.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertEqual(
            discovery.bundleCandidates,
            [makePath("Payload/First.app"), makePath("Payload/Second.app")]
        )
        XCTAssertEqual(
            discovery.outcome,
            .ambiguous([makePath("Payload/First.app"), makePath("Payload/Second.app")])
        )
    }

    func testInfersBundleDirectoryWhenContainerOmitsDirectoryEntries() {
        let table = [
            makeEntry("Payload/Example.app/Info.plist"),
            makeEntry("Payload/Example.app/Example"),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.payloadPresent)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Example.app")])
    }

    func testBareApplicationSuffixIsNotABundleName() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.bundleCandidates.isEmpty)
        XCTAssertEqual(discovery.outcome, .none)
    }

    func testNestedBundleIsNotAPrimaryCandidate() {
        let table = validPackageEntryTable() + [
            makeEntry("Payload/Example.app/PlugIns", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Widget.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Example.app")])
        XCTAssertEqual(discovery.misplacedBundleDirectories, [makePath("Payload/Example.app/PlugIns/Widget.app")])
    }

    func testApplicationNameThatIsNotADirectoryIsReportedSeparately() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .regularFile),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.bundleCandidates.isEmpty)
        XCTAssertEqual(discovery.nonDirectoryApplicationNames, [makePath("Payload/Example.app")])
    }

    func testBundleDirectoryTooDeeplyNestedIsNotAPrimaryCandidate() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Nested/Example.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.bundleCandidates.isEmpty)
        XCTAssertEqual(discovery.misplacedBundleDirectories, [makePath("Payload/Nested/Example.app")])
        XCTAssertEqual(discovery.outcome, .none)
    }

    func testEntriesWithUnsafeNamesAreIgnoredByDiscovery() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeRejectedEntry("Payload/Escape.app", kind: .directory),
            makeRejectedEntry("../Payload/Outside.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertTrue(discovery.bundleCandidates.isEmpty)
        XCTAssertEqual(discovery.outcome, .none)
    }

    func testDuplicateDirectoryEntriesProduceOneCandidate() {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
        ]
        let discovery = ApplicationBundleDiscovery.discover(in: table)
        XCTAssertEqual(discovery.bundleCandidates, [makePath("Payload/Example.app")])
    }
}
