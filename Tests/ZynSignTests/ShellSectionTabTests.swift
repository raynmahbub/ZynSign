import XCTest
@testable import ZynSign

/// The tab bar is the one piece of navigation a user cannot work around, so
/// its composition is pinned here rather than left to drift.
///
/// These are cheap, pure tests. They exist because the failure they guard
/// against is silent: a tab that is listed but not renderable, or a landing
/// destination that names a section the tab bar does not show, produces a
/// screen that selects nothing and reads as a dead app rather than a bug.
final class ShellSectionTabTests: XCTestCase {

    /// The six tabs, in the order the user sees them.
    func testPrimaryTabsAreTheSixShippedSectionsInOrder() {
        XCTAssertEqual(ShellSection.allTabs, [
            .files, .library, .home, .appStore, .downloads, .settings,
        ])
    }

    /// A duplicate entry would render two tabs bound to the same selection
    /// tag, and `TabView` would highlight both.
    func testPrimaryTabsHaveNoDuplicates() {
        XCTAssertEqual(Set(ShellSection.allTabs).count, ShellSection.allTabs.count)
    }

    /// Every tab needs a title and both symbol states, or it renders as a
    /// blank item in the bar.
    func testEveryTabIsFullyTitled() {
        for section in ShellSection.allTabs {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.symbolName.isEmpty, "\(section) has no selected symbol")
            XCTAssertFalse(section.symbolNameUnselected.isEmpty, "\(section) has no unselected symbol")
        }
    }

    /// Six is the practical ceiling for a phone tab bar; this test fails
    /// before someone quietly adds a seventh.
    func testTabBarStaysWithinTheSixTabBudget() {
        XCTAssertLessThanOrEqual(ShellSection.allTabs.count, 6)
    }

    /// Certificates and Profiles moved out of the tab bar. They must stay
    /// reachable from Settings, which is where `SettingsView.browseSection`
    /// links them.
    func testRetiredSectionsAreNotTabs() {
        XCTAssertFalse(ShellSection.allTabs.contains(.certificates))
        XCTAssertFalse(ShellSection.allTabs.contains(.profiles))
    }

    /// Every `LandingTab` the user can choose must name a section the tab bar
    /// actually shows, or launch would select a tab that is not there.
    func testSelectableLandingTabsAllNameRealTabs() {
        for tab in LandingTab.tabCases {
            XCTAssertTrue(
                ShellSection.allTabs.contains(tab.shellSection),
                "\(tab) is offered as a landing tab but is not in the tab bar"
            )
        }
    }

    /// The picker offers exactly the tabs — not the retired cases, which
    /// exist only so an old preferences file still decodes.
    func testLandingPickerOffersTabsAndNotRetiredSections() {
        XCTAssertEqual(LandingTab.tabCases.count, ShellSection.allTabs.count)
        XCTAssertFalse(LandingTab.tabCases.contains(.certificates))
        XCTAssertFalse(LandingTab.tabCases.contains(.profiles))
    }

    /// A preference saved by an earlier build may name Certificates or
    /// Profiles. Launching on one must not select a tab that is not there,
    /// so it coalesces to Library.
    func testRetiredLandingTabCoalescesToATab() {
        XCTAssertEqual(LandingTab.certificates.selectable, .library)
        XCTAssertEqual(LandingTab.profiles.selectable, .library)
        XCTAssertTrue(ShellSection.allTabs.contains(LandingTab.certificates.selectable.shellSection))
    }

    /// A tab that is already selectable is never rewritten.
    func testSelectableLandingTabIsLeftAlone() {
        for tab in LandingTab.tabCases {
            XCTAssertEqual(tab.selectable, tab)
        }
    }

    /// The retired cases must still decode, or a previously-saved preferences
    /// file would fail to load and reset every setting.
    func testRetiredLandingTabsStillDecode() throws {
        let decoder = JSONDecoder()
        for raw in ["certificates", "profiles"] {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try decoder.decode(LandingTab.self, from: data).rawValue, raw)
        }
    }

    /// The six tab sections each render something. `ShellSection.install` and
    /// any other non-tab section is linked from Settings instead, so a tab
    /// that returned an empty view would show a blank screen.
    func testEveryTabSectionRendersADistinctView() {
        let rendered = Set(ShellSection.allTabs.map(\.id))
        XCTAssertEqual(rendered.count, ShellSection.allTabs.count)
    }

    // MARK: - Release gating

    /// Store and Downloads remain stable shell destinations even when a
    /// release gate closes staged workflow capabilities.
    func testDevelopmentStopKeepsStoreAndDownloadsDiscoverable() {
        XCTAssertEqual(ShellSection.primaryTabs { _ in false }, ShellSection.allTabs)
    }

    /// With every feature available the six shipped tabs are all present, in
    /// the order the user sees them.
    func testEveryFeatureAvailableShowsTheSixShippedTabs() {
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }, ShellSection.allTabs)
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }, [
            .files, .library, .home, .appStore, .downloads, .settings,
        ])
    }

    /// Every section that is not core must name the feature that unlocks it,
    /// or it could be shown before its stop by omission.
    func testNonCoreSectionsDeclareTheFeatureThatUnlocksThem() {
        XCTAssertEqual(ShellSection.certificates.requiredFeature, .certificateStudio)
        XCTAssertEqual(ShellSection.profiles.requiredFeature, .provisioningProfileManager)
        XCTAssertEqual(ShellSection.appStore.requiredFeature, .appStore)
        XCTAssertEqual(ShellSection.downloads.requiredFeature, .downloads)
        XCTAssertEqual(ShellSection.presets.requiredFeature, .signingPresets)
        XCTAssertEqual(ShellSection.install.requiredFeature, .installationWorkspace)
        for core in [ShellSection.files, .library, .home, .settings] {
            XCTAssertNil(core.requiredFeature, "\(core) is core and must always be reachable")
        }
    }

    /// The Store and Downloads are both alpha.3 features. Gating one and not
    /// the other would show a Downloads tab with no Store beside it.
    func testStoreAndDownloadsAreUnlockedByTheSameStop() {
        XCTAssertTrue(ReleaseStage.alpha3.features.contains(.appStore))
        XCTAssertTrue(ReleaseStage.alpha3.features.contains(.downloads))
        XCTAssertEqual(ReleaseFeature.appStore.prerequisites, [.downloads])
    }

    /// A landing preference saved by a later build must not select a tab this
    /// stop does not render — the bar would have no selection and the content
    /// area would be blank.
    func testASavedLandingTabClampsToAVisibleTab() {
        let core: [ShellSection] = [.files, .library, .home, .settings]
        XCTAssertEqual(RootView.visibleSelection(for: .appStore, in: core), .library)
        XCTAssertEqual(RootView.visibleSelection(for: .downloads, in: core), .library)
        XCTAssertEqual(RootView.visibleSelection(for: .library, in: core), .library)
        XCTAssertEqual(RootView.visibleSelection(for: .settings, in: core), .settings)
        XCTAssertEqual(RootView.visibleSelection(for: .files, in: core), .files)
    }

    /// A tab that is on screen is never rewritten.
    func testAVisibleLandingTabIsNotClamped() {
        let all = ShellSection.allTabs
        for tab in all {
            XCTAssertEqual(RootView.visibleSelection(for: tab, in: all), tab)
        }
    }
}
