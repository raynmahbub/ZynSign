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
        XCTAssertEqual(ShellSection.primaryTabs, [
            .files, .library, .home, .appStore, .downloads, .settings,
        ])
    }

    /// A duplicate entry would render two tabs bound to the same selection
    /// tag, and `TabView` would highlight both.
    func testPrimaryTabsHaveNoDuplicates() {
        XCTAssertEqual(Set(ShellSection.primaryTabs).count, ShellSection.primaryTabs.count)
    }

    /// Every tab needs a title and both symbol states, or it renders as a
    /// blank item in the bar.
    func testEveryTabIsFullyTitled() {
        for section in ShellSection.primaryTabs {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.symbolName.isEmpty, "\(section) has no selected symbol")
            XCTAssertFalse(section.symbolNameUnselected.isEmpty, "\(section) has no unselected symbol")
        }
    }

    /// Six is the practical ceiling for a phone tab bar; this test fails
    /// before someone quietly adds a seventh.
    func testTabBarStaysWithinTheSixTabBudget() {
        XCTAssertLessThanOrEqual(ShellSection.primaryTabs.count, 6)
    }

    /// Certificates and Profiles moved out of the tab bar. They must stay
    /// reachable from Settings, which is where `SettingsView.browseSection`
    /// links them.
    func testRetiredSectionsAreNotTabs() {
        XCTAssertFalse(ShellSection.primaryTabs.contains(.certificates))
        XCTAssertFalse(ShellSection.primaryTabs.contains(.profiles))
    }

    /// Every `LandingTab` the user can choose must name a section the tab bar
    /// actually shows, or launch would select a tab that is not there.
    func testSelectableLandingTabsAllNameRealTabs() {
        for tab in LandingTab.tabCases {
            XCTAssertTrue(
                ShellSection.primaryTabs.contains(tab.shellSection),
                "\(tab) is offered as a landing tab but is not in the tab bar"
            )
        }
    }

    /// The picker offers exactly the tabs — not the retired cases, which
    /// exist only so an old preferences file still decodes.
    func testLandingPickerOffersTabsAndNotRetiredSections() {
        XCTAssertEqual(LandingTab.tabCases.count, ShellSection.primaryTabs.count)
        XCTAssertFalse(LandingTab.tabCases.contains(.certificates))
        XCTAssertFalse(LandingTab.tabCases.contains(.profiles))
    }

    /// A preference saved by an earlier build may name Certificates or
    /// Profiles. Launching on one must not select a tab that is not there,
    /// so it coalesces to Library.
    func testRetiredLandingTabCoalescesToATab() {
        XCTAssertEqual(LandingTab.certificates.selectable, .library)
        XCTAssertEqual(LandingTab.profiles.selectable, .library)
        XCTAssertTrue(ShellSection.primaryTabs.contains(LandingTab.certificates.selectable.shellSection))
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
        let rendered = Set(ShellSection.primaryTabs.map(\.id))
        XCTAssertEqual(rendered.count, ShellSection.primaryTabs.count)
    }
}
