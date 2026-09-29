import XCTest
@testable import ZynSign

/// Tests for the release train: stages ship in order, features only ever
/// accumulate, no stage exposes a feature without its prerequisites, and the
/// version metadata matches docs/releases/version-strategy.md.
final class ReleaseTrainTests: XCTestCase {

    // MARK: - Sequence

    func testStagesFollowTheVersionStrategy() {
        XCTAssertEqual(ReleaseStage.allCases.map(\.version), [
            "0.1.0-dev.1", "0.1.0-dev.2", "0.1.0-dev.3",
            "0.1.0",
            "0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.3",
            "0.9.0-beta.1", "0.9.0-beta.2", "0.9.0-beta.3", "0.9.0-beta.4",
            "1.0.0-rc.1", "1.0.0-rc.2", "1.0.0-rc.3",
            "1.0.0",
            "2.0.0",
            "3.0.0-nova.1", "3.0.0",
        ])
    }

    func testMarketingVersionsAreNumericForApple() {
        for stage in ReleaseStage.allCases {
            let parts = stage.marketingVersion.split(separator: ".")
            XCTAssertEqual(parts.count, 3, "\(stage) → \(stage.marketingVersion)")
            XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "\(stage) → \(stage.marketingVersion)")
        }
        XCTAssertEqual(ReleaseStage.dev1.marketingVersion, "0.1.0")
        XCTAssertEqual(ReleaseStage.alpha2.marketingVersion, "0.1.0")
        XCTAssertEqual(ReleaseStage.beta3.marketingVersion, "0.9.0")
        XCTAssertEqual(ReleaseStage.rc1.marketingVersion, "1.0.0")
    }

    func testTagsCarryTheLeadingV() {
        XCTAssertEqual(ReleaseStage.dev1.tag, "v0.1.0-dev.1")
        XCTAssertEqual(ReleaseStage.horizon.tag, "v0.1.0")
        XCTAssertEqual(ReleaseStage.alpha1.tag, "v0.1.0-alpha.1")
        XCTAssertEqual(ReleaseStage.stable.tag, "v1.0.0")
        XCTAssertEqual(ReleaseStage.nova.tag, "v3.0.0")
        XCTAssertEqual(ReleaseStage.nova1.marketingVersion, "3.0.0")
    }

    func testNextWalksTheTrainAndStopsAtStable() {
        XCTAssertEqual(ReleaseStage.dev1.next, .dev2)
        XCTAssertEqual(ReleaseStage.dev3.next, .horizon)
        XCTAssertEqual(ReleaseStage.horizon.next, .alpha1)
        XCTAssertEqual(ReleaseStage.alpha3.next, .beta1)
        XCTAssertEqual(ReleaseStage.rc3.next, .stable)
        XCTAssertEqual(ReleaseStage.stable.next, .professional)
        XCTAssertEqual(ReleaseStage.professional.next, .nova1)
        XCTAssertNil(ReleaseStage.nova.next)
    }

    func testStagesCanBeFoundByNameOrVersion() {
        XCTAssertEqual(ReleaseStage(identifier: "alpha2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: "0.1.0-alpha.2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: "v0.1.0-alpha.2"), .alpha2)
        XCTAssertEqual(ReleaseStage(identifier: " v1.0.0 "), .stable)
        XCTAssertEqual(ReleaseStage(identifier: "3.0.0-nova.1"), .nova1)
        XCTAssertEqual(ReleaseStage(identifier: "dev1"), .dev1)
        XCTAssertEqual(ReleaseStage(identifier: "0.1.0-dev.1"), .dev1)
        XCTAssertEqual(ReleaseStage(identifier: "v0.1.0-dev.3"), .dev3)
        XCTAssertNil(ReleaseStage(identifier: "0.2.0-dev"))
        XCTAssertNil(ReleaseStage(identifier: "0.1.0-dev"), "a legacy pre-train tag is not a stage")
    }

    // MARK: - Features

    func testFirstReleaseShipsOnlyTheCore() {
        XCTAssertTrue(ReleaseStage.horizon.features.isEmpty)
    }

    /// The train restarted at `0.1.0-dev.1` (docs/releases/ReleaseResetGuide.md).
    /// A development stop proves the pipeline — build, quality gate, assets,
    /// publish — without exposing a staged feature, so its gate must be empty
    /// while Debug builds keep exposing everything.
    func testDevelopmentStagesProveThePipelineWithoutExposingFeatures() {
        let development: [ReleaseStage] = [.dev1, .dev2, .dev3]
        for stage in development {
            XCTAssertTrue(stage.introducedFeatures.isEmpty, "\(stage) switches on a feature")
            XCTAssertTrue(stage.features.isEmpty, "\(stage) exposes a staged feature")
            let gate = ReleaseGate(stage: stage, exposesEverything: false)
            for feature in ReleaseFeature.allCases {
                XCTAssertFalse(gate.isAvailable(feature), "\(stage) exposes \(feature)")
            }
            XCTAssertTrue(ReleaseGate(stage: stage, exposesEverything: true).isAvailable(.smartSign),
                          "\(stage) must not block Debug work")
            XCTAssertTrue(gate.summary.contains(stage.tag))
        }
        XCTAssertEqual(ReleaseStage.dev3.next, .horizon, "Development runs into Horizon, not into Alpha")
    }

    /// The reset moved the *pointer*, never the *plan*: every feature still has
    /// exactly one introducing stage, and the stages after Development are
    /// unchanged. Nothing built was given up to restart the version numbers.
    func testTheResetKeptTheWholeFeaturePlanIntact() {
        XCTAssertEqual(ReleaseStage.horizon.next, .alpha1)
        XCTAssertEqual(ReleaseStage.alpha1.features, [.certificateStudio, .libraryPowerFeatures])
        XCTAssertEqual(ReleaseStage.stable.features, Set(ReleaseFeature.allCases).subtracting(ReleaseFeature.nova))
        XCTAssertEqual(ReleaseStage.nova.features, Set(ReleaseFeature.allCases))
        for feature in ReleaseFeature.allCases {
            let introducing = ReleaseStage.allCases.filter { $0.introducedFeatures.contains(feature) }
            XCTAssertEqual(introducing.count, 1, "\(feature) must still be introduced exactly once")
            XCTAssertFalse(introducing.contains(.dev1) || introducing.contains(.dev2) || introducing.contains(.dev3),
                           "\(feature) must not be introduced by a development stop")
        }
    }

    func testFeatureRolloutMatchesThePlan() {
        XCTAssertEqual(ReleaseStage.alpha1.features, [.certificateStudio, .libraryPowerFeatures])
        XCTAssertEqual(ReleaseStage.alpha2.features, [
            .certificateStudio, .libraryPowerFeatures,
            .smartSign, .provisioningProfileManager, .signingQueue, .signingPresets,
        ])
        XCTAssertEqual(ReleaseStage.alpha3.features, [
            .certificateStudio, .libraryPowerFeatures,
            .smartSign, .provisioningProfileManager, .signingQueue, .signingPresets,
            .appStore, .downloads, .entitlementsStudio, .identityCenter,
        ])
        XCTAssertEqual(
            ReleaseStage.alpha2.introducedFeatures,
            [.smartSign, .provisioningProfileManager, .signingQueue, .signingPresets]
        )
        XCTAssertEqual(
            ReleaseStage.alpha3.introducedFeatures,
            [.appStore, .downloads, .entitlementsStudio, .identityCenter]
        )
        XCTAssertEqual(
            ReleaseStage.beta1.introducedFeatures,
            [.missionControl, .deliveryHandoff, .activityJournal]
        )
        XCTAssertFalse(ReleaseStage.beta1.introducedFeatures.contains(.signingPresets))
        XCTAssertFalse(ReleaseStage.beta1.features.contains(.batchSigning), "Batch signing ships in beta 3")
        XCTAssertEqual(
            ReleaseStage.beta3.features,
            Set(ReleaseFeature.allCases).subtracting([.signingHealthScore, .smartWorkspace, .novaAssistant])
        )
        XCTAssertEqual(ReleaseStage.stable.features, Set(ReleaseFeature.allCases).subtracting(ReleaseFeature.nova))
        XCTAssertEqual(ReleaseStage.professional.features, ReleaseStage.stable.features, "2.0 adds depth, not gates")
        XCTAssertEqual(ReleaseStage.nova.features, Set(ReleaseFeature.allCases))
    }

    func testTheSigningQueueShipsWithSmartSignInAlpha2() {
        XCTAssertTrue(ReleaseStage.alpha2.introducedFeatures.contains(.signingQueue))
        XCTAssertFalse(ReleaseStage.alpha1.features.contains(.signingQueue))
        XCTAssertEqual(ReleaseFeature.signingQueue.prerequisites, [.smartSign])
        XCTAssertEqual(ReleaseFeature.signingQueue.displayName, "Professional Signing Queue")
    }

    func testSigningPresetsShipWithSmartSignInAlpha2() {
        XCTAssertTrue(ReleaseStage.alpha2.introducedFeatures.contains(.signingPresets))
        XCTAssertTrue(ReleaseStage.alpha2.features.contains(.signingPresets))
        XCTAssertFalse(ReleaseStage.alpha1.features.contains(.signingPresets))
        XCTAssertFalse(ReleaseStage.beta1.introducedFeatures.contains(.signingPresets))
        XCTAssertEqual(ReleaseFeature.signingPresets.displayName, "Intelligent Signing Presets")
    }

    func testEntitlementsStudioShipsAtAlphaThree() {
        XCTAssertFalse(ReleaseGate(stage: .alpha2, exposesEverything: false).isAvailable(.entitlementsStudio))
        XCTAssertTrue(ReleaseGate(stage: .alpha3, exposesEverything: false).isAvailable(.entitlementsStudio))
        XCTAssertTrue(ReleaseGate(stage: .horizon, exposesEverything: true).isAvailable(.entitlementsStudio))
        XCTAssertEqual(ReleaseFeature.entitlementsStudio.prerequisites, [.smartSign])
        XCTAssertEqual(ReleaseFeature.entitlementsStudio.displayName, "Entitlements Studio")
    }

    func testInstallationWorkspaceShipsAtBetaTwo() {
        XCTAssertFalse(ReleaseStage.beta1.features.contains(.installationWorkspace))
        XCTAssertTrue(ReleaseStage.beta2.introducedFeatures.contains(.installationWorkspace))
        XCTAssertTrue(ReleaseGate(stage: .beta2, exposesEverything: false).isAvailable(.installationWorkspace))
        XCTAssertEqual(ReleaseFeature.installationWorkspace.prerequisites, [.deliveryHandoff])
        XCTAssertEqual(ReleaseFeature.installationWorkspace.displayName, "Installation Workspace")
    }

    func testMissionControlHomeShipsInReleaseCandidateTwo() {
        XCTAssertTrue(ReleaseStage.rc2.introducedFeatures.contains(.smartWorkspace))
        XCTAssertFalse(ReleaseStage.rc1.features.contains(.smartWorkspace))
        XCTAssertTrue(ReleaseStage.stable.features.contains(.smartWorkspace))
        XCTAssertEqual(ReleaseFeature.smartWorkspace.prerequisites, [.missionControl, .identityCenter])
        XCTAssertEqual(ReleaseFeature.smartWorkspace.displayName, "Smart Workspace")
    }

    func testNovaShipsAfterOnePointZero() {
        XCTAssertFalse(ReleaseStage.stable.features.contains(.novaAssistant))
        XCTAssertTrue(ReleaseStage.nova1.introducedFeatures.contains(.novaAssistant))
        XCTAssertTrue(ReleaseStage.nova.features.contains(.novaAssistant))
        XCTAssertEqual(ReleaseFeature.novaAssistant.prerequisites, [.smartWorkspace])
    }

    func testFeatureCompleteFromTheFinalRelease() {
        for stage in ReleaseStage.allCases where stage >= .nova1 {
            XCTAssertEqual(stage.features, Set(ReleaseFeature.allCases), "\(stage) must be feature complete")
        }
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
        XCTAssertTrue(ReleaseTrain.isAvailable(.signingPresets))
        XCTAssertFalse(ReleaseTrain.isAvailable(.downloads))
        #else
        XCTAssertEqual(ReleaseTrain.gate.stage, ReleaseTrain.current)
        #endif
    }
}
