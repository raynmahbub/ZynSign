import XCTest
import SwiftUI
@testable import ZynSign

/// Tests for the RC 2 design system tokens, haptics, empty state presets,
/// error views, and onboarding structure.
final class DesignSystemAndUXTests: XCTestCase {

    // MARK: - Design Tokens

    func testSpacingScaleIsStrictlyAscending() {
        XCTAssertLessThan(ZSpacing.xxs, ZSpacing.xs)
        XCTAssertLessThan(ZSpacing.xs, ZSpacing.sm)
        XCTAssertLessThan(ZSpacing.sm, ZSpacing.md)
        XCTAssertLessThan(ZSpacing.md, ZSpacing.lg)
        XCTAssertLessThan(ZSpacing.lg, ZSpacing.xl)
        XCTAssertLessThan(ZSpacing.xl, ZSpacing.xxl)
        XCTAssertLessThan(ZSpacing.xxl, ZSpacing.xxxl)
    }

    func testRadiusScaleIsConsistent() {
        XCTAssertEqual(ZRadius.xs, 4)
        XCTAssertEqual(ZRadius.sm, 8)
        XCTAssertEqual(ZRadius.card, 12)
        XCTAssertEqual(ZRadius.lg, 16)
        XCTAssertEqual(ZRadius.icon, 14)
        XCTAssertEqual(ZRadius.xl, 24)
        XCTAssertGreaterThan(ZRadius.pill, 100)
    }

    func testShadowTokensHaveValidParameters() {
        XCTAssertGreaterThan(ZShadow.subtle.radius, 0)
        XCTAssertGreaterThan(ZShadow.soft.radius, 0)
        XCTAssertGreaterThan(ZShadow.card.radius, 0)
        XCTAssertGreaterThan(ZShadow.elevated.radius, 0)
    }

    // MARK: - Haptics

    func testHapticsCanBeToggled() {
        let original = ZHaptics.isEnabled
        defer { ZHaptics.isEnabled = original }

        ZHaptics.isEnabled = false
        XCTAssertFalse(ZHaptics.isEnabled)

        ZHaptics.isEnabled = true
        XCTAssertTrue(ZHaptics.isEnabled)
    }

    // MARK: - Empty State Presets

    func testEmptyStatePresetsContainMeaningfulCopy() {
        var called = false
        let noApps = ZEmptyState.noApps { called = true }
        XCTAssertEqual(noApps.title, "Your Library is Empty")
        XCTAssertFalse(noApps.message.isEmpty)
        XCTAssertEqual(noApps.primaryActionTitle, "Import Package…")
        noApps.primaryAction?()
        XCTAssertTrue(called)

        let noCertificates = ZEmptyState.noCertificates {}
        XCTAssertEqual(noCertificates.title, "No Certificates Yet")
        XCTAssertFalse(noCertificates.message.isEmpty)
        XCTAssertEqual(noCertificates.primaryActionTitle, "Import Certificate")

        let noProfiles = ZEmptyState.noProfiles {}
        XCTAssertEqual(noProfiles.title, "No Profiles Yet")
        XCTAssertFalse(noProfiles.message.isEmpty)
        XCTAssertEqual(noProfiles.primaryActionTitle, "Import Profile")

        let noDownloads = ZEmptyState.noDownloads {}
        XCTAssertEqual(noDownloads.title, "No Active Downloads")
        XCTAssertFalse(noDownloads.message.isEmpty)

        let noCollections = ZEmptyState.noCollections {}
        XCTAssertEqual(noCollections.title, "No Custom Collections")

        let noHistory = ZEmptyState.noHistory()
        XCTAssertEqual(noHistory.title, "No History Recorded")

        let noPresets = ZEmptyState.noPresets {}
        XCTAssertEqual(noPresets.title, "No Signing Presets")

        let noQueue = ZEmptyState.noQueueJobs {}
        XCTAssertEqual(noQueue.title, "Signing Queue is Idle")

        let noSearch = ZEmptyState.noSearchResults(query: "MyApp") {}
        XCTAssertTrue(noSearch.title.contains("MyApp"))
    }

    // MARK: - Onboarding

    func testOnboardingStepsFollowPrescribedSequence() {
        let steps = ZOnboardingView.OnboardingStep.allCases
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps[0], .welcome)
        XCTAssertEqual(steps[1], .importApps)
        XCTAssertEqual(steps[2], .addCertificate)
        XCTAssertEqual(steps[3], .addProfile)
        XCTAssertEqual(steps[4], .exploreLibrary)
        XCTAssertEqual(steps[5], .ready)

        for step in steps {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.subtitle.isEmpty)
            XCTAssertFalse(step.symbol.isEmpty)
            XCTAssertFalse(step.highlights.isEmpty)
        }
    }

    // MARK: - Error View Presentation

    func testErrorViewStoresActionableGuidance() {
        var retried = false
        let errorView = ZErrorView(
            title: "Signing Blocked",
            explanation: "This provisioning profile has expired. Choose another profile before signing.",
            suggestedAction: "Select an active profile in Profiles tab.",
            technicalDetails: "code: profileExpired | expired: 2026-09-01",
            onRetry: { retried = true }
        )

        XCTAssertEqual(errorView.title, "Signing Blocked")
        XCTAssertTrue(errorView.explanation.contains("expired"))
        XCTAssertEqual(errorView.suggestedAction, "Select an active profile in Profiles tab.")
        XCTAssertEqual(errorView.technicalDetails, "code: profileExpired | expired: 2026-09-01")

        errorView.onRetry?()
        XCTAssertTrue(retried)
    }

    // MARK: - Release Train Stage RC 2

    func testRC2StageCharacteristics() {
        XCTAssertEqual(ReleaseStage.rc2.version, "1.0.0-rc.2")
        XCTAssertEqual(ReleaseStage.rc2.tag, "v1.0.0-rc.2")
        XCTAssertEqual(ReleaseStage.rc2.marketingVersion, "1.0.0")

        // RC2 includes all beta3 features
        XCTAssertTrue(ReleaseStage.rc2.features.contains(.certificateStudio))
        XCTAssertTrue(ReleaseStage.rc2.features.contains(.smartSign))
        XCTAssertTrue(ReleaseStage.rc2.features.contains(.signingQueue))
        XCTAssertTrue(ReleaseStage.rc2.features.contains(.signingPresets))
        XCTAssertTrue(ReleaseStage.rc2.features.contains(.batchSigning))
    }
}
