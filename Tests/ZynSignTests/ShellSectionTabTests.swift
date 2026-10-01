import XCTest
@testable import ZynSign

/// Pins the native tab-shell contract. SwiftUI/UIKit's overflow controller
/// owns its own navigation container, so a sixth visible candidate can become
/// a runtime crash when a tab view embeds another NavigationStack.
final class ShellSectionTabTests: XCTestCase {

    private let visibleCoreTabs: [ShellSection] = [
        .files, .library, .home, .features, .settings,
    ]

    func testCandidateTabsAreUniqueAndInProductOrder() {
        XCTAssertEqual(ShellSection.allTabs, [
            .files, .library, .home, .features, .appStore, .downloads, .settings,
        ])
        XCTAssertEqual(Set(ShellSection.allTabs).count, ShellSection.allTabs.count)
    }

    func testNativeTabBarNeverExceedsFiveAndKeepsTheCoreDestinations() {
        XCTAssertEqual(ShellSection.tabBarItemLimit, 5)
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }, visibleCoreTabs)
        XCTAssertEqual(ShellSection.primaryTabs { _ in false }, visibleCoreTabs)
        XCTAssertEqual(ShellSection.primaryTabs.count, 5)

        for feature in ReleaseFeature.allCases {
            XCTAssertEqual(
                ShellSection.primaryTabs { $0 == feature },
                visibleCoreTabs,
                "The \(feature) gate must not create UIKit's overflow tab"
            )
        }
    }

    func testEveryCandidateHasCompleteNavigationMetadata() {
        for section in ShellSection.allTabs {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.symbolName.isEmpty)
            XCTAssertFalse(section.symbolNameUnselected.isEmpty)
        }
    }

    func testStoreAndDownloadsAreHostedByFeaturesInsteadOfTheTabBar() {
        XCTAssertFalse(ShellSection.primaryTabs.contains(.appStore))
        XCTAssertFalse(ShellSection.primaryTabs.contains(.downloads))
        XCTAssertEqual(ShellSection.tab(toOpen: .appStore), .features)
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .appStore), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .downloads), .features)
    }

    func testSettingsOwnsNonTabSettingsAreas() {
        for section in [ShellSection.certificates, .profiles, .presets, .install] {
            XCTAssertEqual(ShellSection.tab(toOpen: section), .settings)
        }
        XCTAssertFalse(ShellSection.allTabs.contains(.certificates))
        XCTAssertFalse(ShellSection.allTabs.contains(.profiles))
    }

    func testCandidateSectionsDeclareTheirReleaseGate() {
        XCTAssertEqual(ShellSection.certificates.requiredFeature, .certificateStudio)
        XCTAssertEqual(ShellSection.profiles.requiredFeature, .provisioningProfileManager)
        XCTAssertEqual(ShellSection.appStore.requiredFeature, .appStore)
        XCTAssertEqual(ShellSection.downloads.requiredFeature, .downloads)
        XCTAssertEqual(ShellSection.presets.requiredFeature, .signingPresets)
        XCTAssertEqual(ShellSection.install.requiredFeature, .installationWorkspace)
        for section in [ShellSection.files, .library, .home, .features, .settings] {
            XCTAssertNil(section.requiredFeature)
        }
    }

    func testStoreAndDownloadsAreAvailableFromTheFirstPublishedSurface() {
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.appStore))
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.downloads))
        XCTAssertEqual(ReleaseFeature.appStore.prerequisites, [.downloads])
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .features)
    }

    func testLandingPickerOffersExactlyTheFiveVisibleTabs() {
        XCTAssertEqual(LandingTab.tabCases, [
            .files, .library, .home, .features, .settings,
        ])
        XCTAssertEqual(ShellSection.offerableLandingTabs, LandingTab.tabCases)
        for tab in LandingTab.tabCases {
            XCTAssertTrue(ShellSection.primaryTabs.contains(tab.shellSection))
            XCTAssertEqual(tab.selectable, tab)
        }
    }

    func testLegacyLandingPreferencesMigrateToLiveTabs() {
        XCTAssertEqual(LandingTab.appStore.selectable, .features)
        XCTAssertEqual(LandingTab.downloads.selectable, .features)
        XCTAssertEqual(LandingTab.certificates.selectable, .library)
        XCTAssertEqual(LandingTab.profiles.selectable, .library)

        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .appStore), .features)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .downloads), .features)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .certificates), .library)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .profiles), .library)
    }

    func testAllRetiredLandingIdentifiersStillDecode() throws {
        let decoder = JSONDecoder()
        for raw in ["appStore", "downloads", "certificates", "profiles"] {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try decoder.decode(LandingTab.self, from: data).rawValue, raw)
        }
    }

    func testSavedPreferencesCannotSelectAnUnrenderedNativeTab() {
        let core: [ShellSection] = [.files, .library, .home, .features, .settings]
        XCTAssertEqual(RootView.visibleSelection(for: .appStore, in: core), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .downloads, in: core), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .certificates, in: core), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .profiles, in: core), .settings)
        for tab in core {
            XCTAssertEqual(RootView.visibleSelection(for: tab, in: core), tab)
        }
    }
}
