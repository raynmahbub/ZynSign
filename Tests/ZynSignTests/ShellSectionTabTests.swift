import XCTest
@testable import ZynSign

/// Pins the shell's tab contract.
///
/// The main screen draws **exactly five tabs** — Home, Library, Store,
/// Downloads, and Settings — in the Storefront shell order. Two facts are
/// worth a gate rather than a convention:
///
/// - The shell draws its own bar (`ShellTabBar`), not UIKit's, whose
///   five-item ceiling folds the rest of the product into a *More* list it
///   *pushes* — and a pushed destination that owns a `NavigationStack`, which
///   every ZynSign area does, crashes at runtime. The five-tab product choice
///   fits UIKit's ceiling; it is never *chosen* by it. A sixth destination is
///   only ever cut for the product's own reason.
/// - Files, Features, presets, and the signing materials are Settings
///   workflows, and a request for one still resolves to a tab that exists.
///   Removing a tab must never orphan the destination: Settings is the
///   fallback, and the Library is the fallback for the fallback.
final class ShellSectionTabTests: XCTestCase {

    /// The destinations no gate can remove.
    private let alwaysAvailableTabs: [ShellSection] = [
        .home, .library, .settings,
    ]

    func testTheBarDrawsExactlyFiveTabsInProductOrder() {
        XCTAssertEqual(ShellSection.allTabs, [
            .home, .library, .appStore, .downloads, .settings,
        ])
        XCTAssertEqual(ShellSection.allTabs.count, ShellSection.tabCount)
        XCTAssertEqual(Set(ShellSection.allTabs).count, ShellSection.allTabs.count)
    }

    func testFiveIsTheWholeBarAndNeverOverflowedByTheGate() {
        // The maximum the bar can ever carry is five: the contract is not
        // "≤ what UIKit could fold" but "exactly the roots the product keeps".
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }, ShellSection.allTabs)
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }.count, ShellSection.nativeTabBarItemLimit)
        XCTAssertLessThanOrEqual(ShellSection.primaryTabs.count, ShellSection.tabCount)
    }

    func testAStageThatHidesAGatedDestinationHidesExactlyThatTab() {
        let ungated = ShellSection.primaryTabs { _ in false }
        XCTAssertEqual(ungated, alwaysAvailableTabs)
        XCTAssertFalse(ungated.contains(.appStore))
        XCTAssertFalse(ungated.contains(.downloads))

        // A gate that opens one feature opens that feature's tab and no other.
        XCTAssertEqual(
            ShellSection.primaryTabs { $0 == .appStore },
            [.home, .library, .appStore, .settings]
        )
        for feature in ReleaseFeature.allCases {
            let tabs = ShellSection.primaryTabs { $0 == feature }
            XCTAssertEqual(tabs.contains(.appStore), feature == .appStore)
            XCTAssertEqual(tabs.contains(.downloads), feature == .downloads)
        }
    }

    func testFilesIsNoLongerATabAndResolvesIntoSettings() {
        // The tab the five-tab contract removed must stay reachable, not be
        // deleted from the product: Settings carries the Files browser.
        XCTAssertFalse(ShellSection.allTabs.contains(.files))
        XCTAssertEqual(ShellSection.tab(toOpen: .files), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .files), .settings)
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
        for section in [ShellSection.files, .certificates, .profiles, .presets, .install, .features] {
            XCTAssertEqual(ShellSection.tab(toOpen: section), .settings)
        }
        XCTAssertFalse(ShellSection.allTabs.contains(.certificates))
        XCTAssertFalse(ShellSection.allTabs.contains(.profiles))
        XCTAssertFalse(ShellSection.allTabs.contains(.presets))
        XCTAssertFalse(ShellSection.allTabs.contains(.install))
        XCTAssertFalse(ShellSection.allTabs.contains(.features))
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
        XCTAssertNil(ShellSection.files.requiredFeature)
    }

    func testStoreAndDownloadsAreAvailableFromTheFirstPublishedSurface() {
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.appStore))
        XCTAssertTrue(ReleaseStage.horizon.features.contains(.downloads))
        XCTAssertEqual(ReleaseFeature.appStore.prerequisites, [.downloads])
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .downloads)
    }

    func testLandingPickerOffersFiveInBarOrder() {
        XCTAssertEqual(LandingTab.tabCases, [
            .library, .home, .appStore, .downloads, .settings,
        ])
        XCTAssertEqual(ShellSection.offerableLandingTabs, LandingTab.tabCases)
        for tab in LandingTab.tabCases {
            XCTAssertTrue(ShellSection.primaryTabs.contains(tab.shellSection))
            XCTAssertEqual(tab.selectable, tab)
            XCTAssertEqual(ShellSection.effectiveLandingTab(for: tab), tab)
        }
    }

    func testSavedStoreSelectionIsHonouredAgain() {
        // A preferences file written when Store was hidden must not keep the
        // user somewhere else now that Store and Downloads have direct tabs.
        XCTAssertEqual(LandingTab.appStore.selectable, .appStore)
        XCTAssertEqual(LandingTab.downloads.selectable, .downloads)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .appStore), .appStore)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .downloads), .downloads)
    }

    func testSavedFilesLandingMigratesToTheLibrary() {
        // Files left the bar; a launch preference that named it lands on the
        // browse root instead of an unreachable tab. The browser itself is
        // one Settings row away.
        XCTAssertEqual(LandingTab.files.isSelectableTab, false)
        XCTAssertEqual(LandingTab.files.selectable, .library)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .files), .library)
        XCTAssertEqual(RootView.visibleSelection(for: .files), .settings)
    }

    func testSavedFeaturesLandingMigratesIntoSettings() {
        XCTAssertEqual(LandingTab.features.isSelectableTab, false)
        XCTAssertEqual(LandingTab.features.selectable, .settings)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .features), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .features), .settings)
    }

    func testSigningMaterialLandingPreferencesMigrateToSettings() {
        XCTAssertEqual(LandingTab.certificates.selectable, .settings)
        XCTAssertEqual(LandingTab.profiles.selectable, .settings)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .certificates), .settings)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .profiles), .settings)
    }

    func testAllRetiredLandingIdentifiersStillDecode() throws {
        let decoder = JSONDecoder()
        for raw in ["files", "appStore", "downloads", "features", "certificates", "profiles"] {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try decoder.decode(LandingTab.self, from: data).rawValue, raw)
        }
    }

    func testSavedPreferencesCannotSelectATabABuildDoesNotRender() {
        let core: [ShellSection] = [.home, .library, .settings]
        XCTAssertEqual(RootView.visibleSelection(for: .appStore, in: core), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .downloads, in: core), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .files, in: core), .settings)
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
