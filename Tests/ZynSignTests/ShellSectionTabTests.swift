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

    /// Six sections want a slot and the platform draws five. The bar is capped
    /// at `tabBarItemLimit` because past it UIKit stops *drawing* tabs and
    /// starts *pushing* them into a "More" list of its own — and a folded tab
    /// here is a crash, not an inconvenience: every tab view carries its own
    /// `NavigationStack` (`RootView.tabContent`), and a stack inside a pushed
    /// destination is the nested-stack fault the navigation audit exists to
    /// stop. The audit cannot see this one, because the push is UIKit's.
    ///
    /// So `allTabs` may grow and `primaryTabs` may not.
    func testTabBarNeverExceedsThePlatformCeiling() {
        XCTAssertEqual(ShellSection.tabBarItemLimit, 5)
        XCTAssertGreaterThan(ShellSection.allTabs.count, ShellSection.tabBarItemLimit,
                             "the cap is guarding nothing if every section fits")
        XCTAssertEqual(ShellSection.primaryTabs { _ in true }.count, ShellSection.tabBarItemLimit)
        XCTAssertEqual(ShellSection.primaryTabs { _ in false }.count, ShellSection.tabBarItemLimit)
        for feature in ReleaseFeature.allCases {
            XCTAssertEqual(ShellSection.primaryTabs { $0 == feature }.count,
                           ShellSection.tabBarItemLimit,
                           "\(feature) produced a bar over the ceiling")
        }
    }

    /// The cap must drop the least-wanted section and leave the survivors in
    /// their declared order — silently renumbering Files and Library because a
    /// fifth tab appeared is not an acceptable way to stay inside five.
    func testTheCapDropsOnlyTheLeastWantedSectionAndKeepsTheRestInOrder() {
        XCTAssertEqual(ShellSection.primaryTabs { _ in true },
                       [.files, .library, .home, .appStore, .settings])
        XCTAssertFalse(ShellSection.primaryTabs { _ in true }.contains(.downloads),
                       "Downloads is the section that yields a slot")
        for kept in [ShellSection.files, .library, .home, .appStore, .settings] {
            XCTAssertTrue(ShellSection.primaryTabs { _ in false }.contains(kept),
                          "\(kept) lost its tab; it is core navigation")
        }
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
    /// release gate closes staged workflow capabilities — so a development
    /// build never shows a Store tab for one stop and hides it for the next.
    /// Downloads keeps its place in the *set*; it is the first to yield its
    /// slot to the five-item ceiling, and Settings → Updates is where it
    /// lives when it does.
    func testDevelopmentStopKeepsStoreAndDownloadsDiscoverable() {
        let tabs = ShellSection.primaryTabs { _ in false }
        XCTAssertTrue(tabs.contains(.appStore), "a gated build hid the Store tab")
        XCTAssertTrue(ShellSection.allTabs.contains(.downloads))
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .settings,
                       "a folded Downloads must land on the surface that hosts it")
    }

    /// With every feature available, the bar is the first five sections in
    /// order. A Debug build has every gate open, which is precisely why the
    /// ceiling is enforced here rather than assumed: this is the one build a
    /// developer actually runs, and it used to be the one that crashed.
    func testEveryFeatureAvailableShowsTheCappedBarInDeclaredOrder() {
        XCTAssertEqual(ShellSection.primaryTabs { _ in true },
                       Array(ShellSection.allTabs.filter { $0 != .downloads }))
    }

    /// Sections without a slot are hosted by another surface, and asking for
    /// one must not hand `TabView` a selection value it cannot match. That is
    /// not a no-op — the bar loses its selection and the content area goes
    /// empty, which is how "tapping Add a certificate does nothing" behaves.
    func testASectionWithoutASlotResolvesToItsHost() {
        XCTAssertEqual(ShellSection.tab(toOpen: .certificates), .settings)
        XCTAssertEqual(ShellSection.tab(toOpen: .profiles), .settings)
        XCTAssertEqual(ShellSection.tab(toOpen: .presets), .settings)
        XCTAssertEqual(ShellSection.tab(toOpen: .install), .settings)
        XCTAssertEqual(ShellSection.tab(toOpen: .downloads), .settings)
    }

    /// A section that does have a slot is never rerouted through Settings.
    func testASectionWithASlotOpensItself() {
        for tab in ShellSection.primaryTabs {
            XCTAssertEqual(ShellSection.tab(toOpen: tab), tab)
        }
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

    // MARK: - What the landing picker may offer

    /// The picker offers what the bar can select — not every tab-capable
    /// section.
    ///
    /// It used to offer `LandingTab.tabCases`, which names all six sections
    /// including Downloads, the one the five-item ceiling drops. So a user
    /// could choose Downloads, watch it save, and land on Library at every
    /// launch afterwards: the preference was honoured by the same clamp that
    /// made the choice meaningless. Offering a destination the bar cannot
    /// render is the preference-file version of the dead tab this file's
    /// other tests guard against.
    func testTheLandingPickerOffersOnlyTabsTheBarCanSelect() {
        let offered = ShellSection.offerableLandingTabs

        XCTAssertFalse(offered.isEmpty, "the picker would have nothing to offer")
        XCTAssertLessThanOrEqual(offered.count, ShellSection.tabBarItemLimit)
        XCTAssertEqual(Set(offered).count, offered.count)
        for tab in offered {
            XCTAssertTrue(
                ShellSection.primaryTabs.contains(tab.shellSection),
                "\(tab) is offered as a landing tab but has no slot in the bar"
            )
        }
    }

    /// The section that yields its slot is the one the picker must stop
    /// offering while the cap holds.
    func testAFoldedSectionIsNotOfferedAsALandingTab() {
        XCTAssertFalse(ShellSection.primaryTabs.contains(.downloads))
        XCTAssertFalse(ShellSection.offerableLandingTabs.contains(.downloads))
        XCTAssertTrue(LandingTab.tabCases.contains(.downloads),
                      "Downloads is still a real tab section; it has no slot, not no existence")
    }

    /// A stored destination the bar cannot select reads as the tab launch
    /// really opens, and the two clamps have to agree — a picker showing one
    /// tab while the next cold start lands on another is a control that lies.
    func testAStoredLandingTabWithNoSlotReadsAsTheTabLaunchOpens() {
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .downloads), .library)
        XCTAssertEqual(
            RootView.visibleSelection(for: LandingTab.downloads.shellSection).title,
            ShellSection.effectiveLandingTab(for: .downloads).shellSection.title
        )
        for tab in ShellSection.offerableLandingTabs {
            XCTAssertEqual(ShellSection.effectiveLandingTab(for: tab), tab,
                           "\(tab) is offered, so it must not be rewritten")
        }
    }

    /// A retired section saved by an earlier build reads as Library too, which
    /// is what `LandingTab.selectable` already decided for it.
    func testARetiredLandingTabReadsAsLibrary() {
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .certificates), .library)
        XCTAssertEqual(ShellSection.effectiveLandingTab(for: .profiles), .library)
    }
}
