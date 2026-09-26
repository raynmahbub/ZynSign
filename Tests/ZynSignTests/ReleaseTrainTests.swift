import XCTest
@testable import ZynSign

/// Tests for the release train: stages ship in order, features only ever
/// accumulate, no stage exposes a feature without its prerequisites, and the
/// version metadata matches docs/releases/version-strategy.md.
final class ReleaseTrainTests: XCTestCase {

    // MARK: - Sequence

    func testStagesFollowTheVersionStrategy() {
        XCTAssertEqual(ReleaseStage.allCases.map(\.version), [
            "0.1.0",
            "0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.3",
            "0.9.0-beta.1", "0.9.0-beta.2", "0.9.0-beta.3", "0.9.0-beta.4",
            "1.0.0-rc.1", "1.0.0-rc.2", "1.0.0-rc.3",
            "1.0.0",
        ])
    }

    func testMarketingVersionsAreNumericForApple() {
        for stage in ReleaseStage.allCases {
            let parts = stage.marketingVersion.split(separator: ".")
            XCTAssertEqual(parts.count, 3, "\(stage) → \(stage.marketingVersion)")
            XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "\(stage) → \(stage.marketingVersion)")
        }
        XCTAssertEqual(ReleaseStage.alpha2.marketingVersion, "0.1.0")
        XCTAssertEqual(ReleaseStage.beta3.marketingVersion, "0.9.0")
        XCTAssertEqual(ReleaseStage.rc1.marketingVersion, "1.0.0")
    }

    func testTagsCarryTheLeadingV() {
        XCTAssertEqual(ReleaseStage.horizon.tag, "v0.1.0")
        XCTAssertEqual(ReleaseStage.alpha1.tag, "v0.1.0-alpha.1")
        XCTAssertEqual(ReleaseStage.stable.tag, "v1.0.0")
    }

    func testNextWalksTheTrainAndStopsAtStable() {
        XCTAssertEqual(ReleaseStage.horizon.next, .alpha1)
        XCTAssertEqual(ReleaseStage.alpha3.next, .beta1)
        XCTAssertEqual(ReleaseStage.rc3.next, .stable)
        XCTAssertNil(ReleaseStage.stable.next)
    }

    func testStagesCanBeFoundByNameOrVersion() {
        XCTAssertEqual(ReleaseStage(identifier: "alpha2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: "0.1.0-alpha.2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: "v0.1.0-alpha.2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: " v1.0.0 "), .stable)
        XCTAssertNil(ReleaseStage(identifier: "0.2.0-dev"))
    }

    // MARK: - Features

    func testFirstReleaseShipsOnlyTheCore() {
        XCTAssertTrue(ReleaseStage.horizon.features.isEmpty)
    }

    func testFeatureRolloutMatchesThePlan() {
        XCTAssertEqual(ReleaseStage.alpha1.features, [.certificateStudio, .libraryPowerFeatures])
        XCTAssertEqual(ReleaseStage.alpha2.features, [.certificateStudio, .libraryPowerFeatures, .smartSign, .provisioningProfileManager])
        XCTAssertEqual(ReleaseStage.alpha3.introducedFeatures, [.appStore, .downloads, .entitlementsStudio])
        XCTAssertEqual(ReleaseStage.beta1.introducedFeatures, [.missionControl, .deliveryHandoff, .activityJournal, .signingPresets])
        XCTAssertEqual(ReleaseStage.stable.features, Set(ReleaseFeature.allCases))
    }

    func testLaterPlannedFeaturesRemainStaged() {
        XCTAssertFalse(ReleaseStage.beta1.features.contains(.batchSigning))
        XCTAssertTrue(ReleaseStage.beta3.features.contains(.batchSigning))
        XCTAssertFalse(ReleaseStage.rc3.features.contains(.signingHealthScore))
        XCTAssertTrue(ReleaseStage.stable.features.contains(.signingHealthScore))
    }

    func testEntitlementsStudioShipsAtAlphaThree() {
        XCTAssertFalse(ReleaseGate(stage: .alpha2, exposesEverything: false).isAvailable(.entitlementsStudio))
        XCTAssertTrue(ReleaseGate(stage: .alpha3, exposesEverything: false).isAvailable(.entitlementsStudio))
        XCTAssertTrue(ReleaseGate(stage: .horizon, exposesEverything: true).isAvailable(.entitlementsStudio))
    }

    func testFeaturesOnlyAccumulate() {
        var previous: Set<ReleaseFeature> = []
        for stage in ReleaseStage.allCases {
            XCTAssertTrue(previous.isSubset(of: stage.features), "\(stage) removes a feature users already had")
            previous = stage.features
        }
    }

    func testEveryFeatureIsIntroducedExactlyOnce() {
        for feature in ReleaseFeature.allCases {
            let introducing = ReleaseStage.allCases.filter { $0.introducedFeatures.contains(feature) }
            XCTAssertEqual(introducing.count, 1, "\(feature) introduced in \(introducing)")
        }
    }

    func testNoStageExposesAFeatureWithoutItsPrerequisites() {
        for stage in ReleaseStage.allCases {
            for feature in stage.features {
                XCTAssertTrue(
                    feature.prerequisites.isSubset(of: stage.features),
                    "\(stage) exposes \(feature) without \(feature.prerequisites.subtracting(stage.features))"
                )
            }
        }
    }

    func testEveryFeatureHasADisplayName() {
        for feature in ReleaseFeature.allCases {
            XCTAssertFalse(feature.displayName.isEmpty)
        }
    }

    // MARK: - Gate

    func testGateFollowsTheStage() {
        let gate = ReleaseGate(stage: .alpha1, exposesEverything: false)
        XCTAssertTrue(gate.isAvailable(.certificateStudio))
        XCTAssertFalse(gate.isAvailable(.smartSign))
        XCTAssertFalse(gate.isAvailable(.appStore))
        XCTAssertTrue(gate.summary.contains("v0.1.0-alpha.1"))
    }

    func testDebugGateExposesEverything() {
        let gate = ReleaseGate(stage: .horizon, exposesEverything: true)
        for feature in ReleaseFeature.allCases {
            XCTAssertTrue(gate.isAvailable(feature))
        }
        XCTAssertTrue(gate.summary.contains("Debug"))
    }

    func testPreviewOverrideSelectsAStageInDebug() {
        let key = ReleaseTrain.previewDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("alpha2", forKey: key)
        #if DEBUG
        XCTAssertEqual(ReleaseTrain.gate, ReleaseGate(stage: .alpha2, exposesEverything: false))
        XCTAssertTrue(ReleaseTrain.isAvailable(.smartSign))
        XCTAssertFalse(ReleaseTrain.isAvailable(.downloads))
        #else
        XCTAssertEqual(ReleaseTrain.gate.stage, ReleaseTrain.current)
        #endif
    }
}
