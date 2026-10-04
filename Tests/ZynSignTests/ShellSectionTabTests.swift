import XCTest
@testable import ZynSign

/// Pins the shell's tab contract.
///
/// The shell draws its own bar (`ShellTabBar`) instead of using UIKit's, whose
/// five-item ceiling folds the rest of the product into a *More* list it
/// *pushes* — and a pushed destination that owns a `NavigationStack`, which
/// every ZynSign area does, crashes at runtime. The previous way out of that
/// was to stop showing destinations: Store and Downloads lost their slots, and
/// a tester opened a build whose App Store tab was simply missing. These tests
/// pin the two halves of the fix: every destination the release exposes is a
/// tab, and the number UIKit's bar can draw no longer decides anything.
final class ShellSectionTabTests: XCTestCase {

    /// The destinations no gate can remove.
    private let alwaysAvailableTabs: [ShellSection] = [
        .files, .library, .home, .features, .settings,
    ]

    func testCandidateTabsAreUniqueAndInProductOrder() {
        XCTAssertEqual(ShellSection.allTabs, [
            .files, .library, .home, .appStore, .downloads, .features, .settings,
        ])
        XCTAssertEqual(Set(ShellSection.allTabs).count, ShellSection.allTabs.count)
    }

    func testEveryAvailableDestinationIsATab() {
        // The reported defect: the App Store tab was missing from a build whose
        // release stage exposes the Store. Both gated destinations are visible
        // at every stop that switches them on, and the shell shows more
        // destinations than UIKit's own bar can draw — which is the reason it
        // draws its own.
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }, ShellSection.allTabs)
        XCTAssertTrue(ShellSection.primaryTabs.contains(.appStore))
        XCTAssertTrue(ShellSection.primaryTabs.contains(.downloads))
        XCTAssertGreaterThan(ShellSection.primaryTabs.count, ShellSection.nativeTabBarItemLimit)
    }

    func testAStageThatHidesAGatedDestinationHidesExactlyThatTab() {
        let ungated = ShellSection.primaryTabs { _ in false }
        XCTAssertEqual(ungated, alwaysAvailableTabs)
        XCTAssertFalse(ungated.contains(.appStore))
        XCTAssertFalse(ungated.contains(.downloads))

        // A gate that opens one feature opens that feature's tab and no other.
        XCTAssertEqual(
            ShellSection.primaryTabs { $0 == .appStore },
            [.files, .library, .home, .appStore, .features, .settings]
        )
        for feature in ReleaseFeature.allCases {
            let tabs = ShellSection.primaryTabs { $0 == feature }
            XCTAssertEqual(tabs.contains(.appStore), feature == .appStore)
            XCTAssertEqual(tabs.contains(.downloads), feature == .downloads)
        }
    }

    func testEveryCandidateHasCompleteNavigationMetadata() {
        for section in ShellSection.allTabs {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.symbolName.isEmpty)
            XCTAssertFalse(section.symbolNameUnselected.isEmpty)
        }
    }

    func testEveryTabDestinationSelectsItself() {
        for section in ShellSection.primaryTabs {
            XCTAssertEqual(ShellSection.tab(toOpen: section), section)
            XCTAssertEqual(RootView.visibleSelection(for: section), section)
        }
        XCTAssertEqual(ShellSection.tab(toOpen: .appStore), .appStore)
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .downloads)
    }

    func testSettingsOwnsNonTabWorkflows() {
        for section in [ShellSection.certificates, .profiles, .presets, .install] {
            XCTAssertEqual(ShellSection.tab(toOpen: section), .settings)
        }
        XCTAssertFalse(ShellSection.allTabs.contains(.certificates))
        XCTAssertFalse(ShellSection.allTabs.contains(.profiles))
        XCTAssertFalse(ShellSection.allTabs.contains(.presets))
        XCTAssertFalse(ShellSection.allTabs.contains(.install))
    }

    func testCandidateSectionsDeclareTheirReleaseGate() {
        XCTAssertEqual(ShellSection.certificates.requiredFeature, .certificateStudio)
        XCTAssertEqual(ShellSection.profiles.requiredFeature, .provisioningProfileManager)
        XCTAssertEqual(ShellSection.appStore.requiredFeature, .appStore)
        XCTAssertEqual(ShellSection.downloads.requiredFeature, .downloads)
        XCTAssertEqual(ShellSection.presets.requiredFeature, .signingPresets)
        XCTAssertEqual(ShellSection.install.requiredFeature, .installationWorkspace)
        for section in alwaysAvailableTabs {
            XCTAssertNil(section.requiredFeature)
        }
    }

    func testStoreAndDownloadsAreAvailableFromTheFirstPublishedSurface() {
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.appStore))
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.downloads))
        XCTAssertEqual(ReleaseFeature.appStore.prerequisites, [.downloads])
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .downloads)
    }

    func testLandingPickerOffersEveryTabInBarOrder() {
        XCTAssertEqual(LandingTab.tabCases, [
            .files, .library, .home, .appStore, .downloads, .features, .settings,
        ])
        XCTAssertEqual(ShellSection.offerableLandingTabs, LandingTab.tabCases)
        for tab in LandingTab.tabCases {
            XCTAssertTrue(ShellSection.primaryTabs.contains(tab.shellSection))
            XCTAssertEqual(tab.selectable, tab)
            XCTAssertEqual(ShellSection.effectiveLandingTab(for: tab), tab)
        }
    }

    func testSavedStoreSelectionIsHonouredAgain() {
        // A preferences file written when Store was a tab names Store, and a
        // later build that folded it into Features must not keep the user
        // somewhere else now that it is a tab again.
        XCTAssertEqual(LandingTab.appStore.selectable, .appStore)
        XCTAssertEqual(LandingTab.downloads.selectable, .downloads)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .appStore), .appStore)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .downloads), .downloads)
    }

    func testNonTabLandingPreferencesMigrateToTheLibrary() {
        XCTAssertEqual(LandingTab.certificates.selectable, .library)
        XCTAssertEqual(LandingTab.profiles.selectable, .library)
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

    func testSavedPreferencesCannotSelectATabABuildDoesNotRender() {
        let core: [ShellSection] = [.files, .library, .home, .features, .settings]
        XCTAssertEqual(RootView.visibleSelection(for: .appStore, in: core), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .downloads, in: core), .features)
        XCTAssertEqual(RootView.visibleSelection(for: .certificates, in: core), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .profiles, in: core), .settings)
        for tab in core {
            XCTAssertEqual(RootView.visibleSelection(for: tab, in: core), tab)
        }
        // A build with neither the destination nor Settings falls back to its
        // first tab rather than selecting nothing.
        XCTAssertEqual(RootView.visibleSelection(for: .appStore, in: [.library]), .library)
    }
}
