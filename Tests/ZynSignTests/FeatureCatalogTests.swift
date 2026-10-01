import XCTest
@testable import ZynSign

final class FeatureCatalogTests: XCTestCase {

    func testEveryReleaseFeatureAppearsExactlyOnceWithoutASecondManualList() {
        let releaseEntries = FeatureCatalog.allEntries.filter {
            $0.availability.releaseFeature != nil
        }
        let listed = releaseEntries.compactMap { $0.availability.releaseFeature }

        XCTAssertEqual(Set(listed), Set(ReleaseFeature.allCases))
        XCTAssertEqual(listed.count, ReleaseFeature.allCases.count)
        XCTAssertEqual(
            Set(releaseEntries.map(\.id)).count,
            releaseEntries.count,
            "Release feature identifiers must be unique"
        )
    }

    func testCoreAndUnsupportedFeatureRegistriesFeedTheCatalogueAutomatically() {
        let coreEntries = FeatureCatalog.allEntries.filter {
            $0.availability == .alwaysAvailable
        }
        let unsupportedEntries = FeatureCatalog.allEntries.filter {
            $0.availability == .notSupported
        }

        XCTAssertEqual(coreEntries.count, CoreFeature.allCases.count)
        XCTAssertEqual(Set(coreEntries.map(\.id)), Set(CoreFeature.allCases.map { $0.catalogEntry.id }))
        XCTAssertEqual(unsupportedEntries.count, UnsupportedFeature.allCases.count)
        XCTAssertEqual(Set(unsupportedEntries.map(\.id)), Set(UnsupportedFeature.allCases.map { $0.catalogEntry.id }))
        XCTAssertTrue(unsupportedEntries.contains { $0.id == "limit.in-app-installation" })
        XCTAssertTrue(unsupportedEntries.contains { $0.id == "limit.pairing-jit-mux" })
        XCTAssertTrue(unsupportedEntries.contains { $0.id == "limit.cloud-telemetry" })
        XCTAssertEqual(Set(FeatureCatalog.allEntries.map(\.id)).count, FeatureCatalog.allEntries.count)
    }

    func testEveryCatalogueEntryHasUsefulPresentationMetadata() {
        for entry in FeatureCatalog.allEntries {
            XCTAssertFalse(entry.id.isEmpty)
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(entry.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(entry.category.title.isEmpty)
        }
    }

    func testAvailabilityMatchesTheReleaseTrainAndNamesTheFirstUnlockStop() {
        let gate = ReleaseGate(stage: .horizon, exposesEverything: false)
        let entries = Dictionary(uniqueKeysWithValues: FeatureCatalog.allEntries.map { ($0.id, $0) })

        XCTAssertEqual(entries["release.certificateStudio"]?.status(in: gate), .available)
        XCTAssertEqual(entries["release.provisioningProfileManager"]?.status(in: gate), .available)
        XCTAssertEqual(entries["release.appStore"]?.status(in: gate), .available)
        XCTAssertEqual(entries["release.downloads"]?.status(in: gate), .available)
        XCTAssertEqual(entries["release.libraryPowerFeatures"]?.status(in: gate), .staged(tag: "v0.1.0-alpha.1"))
        XCTAssertEqual(entries["release.smartSign"]?.status(in: gate), .staged(tag: "v0.1.0-alpha.2"))
        XCTAssertEqual(entries["limit.in-app-installation"]?.status(in: gate), .notSupported)
    }

    func testDebugGateMarksStagedFeaturesAvailableWithoutChangingTheCatalogue() {
        let debugGate = ReleaseGate(stage: .patch1, exposesEverything: true)
        let releaseGate = ReleaseGate(stage: .patch1, exposesEverything: false)
        let entries = FeatureCatalog.allEntries.filter { $0.availability.releaseFeature != nil }

        XCTAssertTrue(entries.allSatisfy { $0.status(in: debugGate) == .available })
        XCTAssertTrue(entries.contains { if case .staged = $0.status(in: releaseGate) { return true }; return false })
    }
}
