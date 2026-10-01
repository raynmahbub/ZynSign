import XCTest
@testable import ZynSign

/// The Settings Control Center's registry: that every section is registered
/// exactly once, describes itself, and is placed where the user expects.
@MainActor
final class SettingsSectionCatalogTests: XCTestCase {

    // MARK: - Registration

    func testEverySectionIsRegisteredExactlyOnce() {
        let identifiers = SettingsSectionCatalog.all.map(\.descriptor.identifier)

        XCTAssertEqual(identifiers.count, SettingsSectionIdentifier.allCases.count)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in SettingsSectionIdentifier.allCases {
            XCTAssertTrue(identifiers.contains(identifier), identifier.rawValue)
        }
    }

    func testEverySectionCanBeFoundByItsIdentifier() {
        for identifier in SettingsSectionIdentifier.allCases {
            XCTAssertNotNil(SettingsSectionCatalog.screen(for: identifier), identifier.rawValue)
        }
    }

    func testEverySectionBuildsAPage() {
        for section in SettingsSectionCatalog.all {
            XCTAssertNotNil(section.destination(), section.descriptor.title)
        }
    }

    // MARK: - Description

    func testEverySectionNamesItselfForTheHub() {
        for section in SettingsSectionCatalog.all {
            let descriptor = section.descriptor
            XCTAssertFalse(descriptor.title.isEmpty, descriptor.identifier.rawValue)
            XCTAssertFalse(descriptor.summary.isEmpty, descriptor.title)
            XCTAssertFalse(descriptor.footer.isEmpty, "\(descriptor.title) must explain itself on its page")
            XCTAssertFalse(descriptor.symbolName.isEmpty, descriptor.title)
        }
    }

    func testTheEverydaySectionsAreTheEverydayOnes() {
        let everyday = SettingsSectionCatalog.everyday.map(\.descriptor.identifier)

        XCTAssertTrue(everyday.contains(.general))
        XCTAssertTrue(everyday.contains(.signing))
        XCTAssertTrue(everyday.contains(.security))
        XCTAssertTrue(everyday.contains(.storage))
        XCTAssertTrue(everyday.contains(.diagnostics))
        XCTAssertTrue(everyday.contains(.appearance))
        // Advanced, Recovery, and About are deliberately not everyday.
        XCTAssertFalse(everyday.contains(.advanced))
        XCTAssertFalse(everyday.contains(.recovery))
        XCTAssertFalse(everyday.contains(.about))
    }

    func testAdvancedSettingsAreListedApartFromEverydayOnes() {
        let separated = SettingsSectionCatalog.separated.map(\.descriptor.identifier)

        XCTAssertTrue(separated.contains(.advanced))
        XCTAssertTrue(separated.contains(.recovery))
        for section in SettingsSectionCatalog.separated {
            XCTAssertFalse(
                SettingsSectionCatalog.everyday.contains { $0.id == section.id },
                section.descriptor.title
            )
        }
    }

    func testAboutIsListedOnItsOwn() {
        XCTAssertEqual(SettingsSectionCatalog.about.map(\.descriptor.identifier), [.about])
    }

    func testEverySectionAppearsInExactlyOneGroup() {
        let grouped = SettingsSectionCatalog.everyday
            + SettingsSectionCatalog.separated
            + SettingsSectionCatalog.about

        XCTAssertEqual(grouped.count, SettingsSectionCatalog.all.count)
        XCTAssertEqual(Set(grouped.map(\.id)).count, SettingsSectionCatalog.all.count)
    }

    // MARK: - Safety of the separation

    func testOnlyRecoveryIsMarkedDestructive() {
        let destructive = SettingsSectionCatalog.all.filter(\.descriptor.isDestructive)

        XCTAssertEqual(destructive.map(\.descriptor.identifier), [.recovery])
    }

    func testOnlyAdvancedIsMarkedForExperiencedUsers() {
        let advanced = SettingsSectionCatalog.all.filter(\.descriptor.isAdvanced)

        // Advanced and the Compatibility Lab: both are kept apart from
        // everyday settings, the Lab because it validates a release rather
        // than configures the app.
        XCTAssertEqual(Set(advanced.map(\.descriptor.identifier)), [.advanced, .compatibilityLab])
    }

    func testTheValidationSectionIsTheOnlyOneMarkedValidationOnly() {
        let validationOnly = SettingsSectionCatalog.all.filter(\.descriptor.isValidationOnly)

        XCTAssertEqual(validationOnly.map(\.descriptor.identifier), [.compatibilityLab])
    }

    func testDescriptorsAreUniqueAndHashable() {
        let descriptors = SettingsSectionCatalog.descriptors

        XCTAssertEqual(Set(descriptors).count, descriptors.count)
    }

    // MARK: - Reachability

    /// Registration is not reachability. The Settings index is the only
    /// navigation into these sections, and its `destination(for:)` is a
    /// `@ViewBuilder` — nothing can ask it what it presents. So each category
    /// records the sections it opens, and the union has to cover the catalog.
    ///
    /// This is the gap that hid a missing screen: the Security Center stayed
    /// registered, so every test above kept passing, while no row in Settings
    /// opened it. The application lock, its session timeout, its
    /// sensitive-action rule, and its sensitive-data visibility were all
    /// unreachable — a settings area compiled in, tested, and impossible to
    /// open.
    func testEveryRegisteredSectionIsReachableFromTheSettingsIndex() {
        let reachable = Set(SettingsCategory.allCases.flatMap(\.openedSections))
        for identifier in SettingsSectionIdentifier.allCases {
            XCTAssertTrue(
                reachable.contains(identifier),
                "\(identifier.rawValue) is registered but no Settings category opens it"
            )
        }
    }

    /// The record must not drift the other way either: a category claiming a
    /// section that is not registered would pass the test above while pointing
    /// at nothing.
    func testTheIndexOpensNothingThatIsNotRegistered() {
        let registered = Set(SettingsSectionCatalog.all.map(\.descriptor.identifier))
        for category in SettingsCategory.allCases {
            for identifier in category.openedSections {
                XCTAssertTrue(
                    registered.contains(identifier),
                    "\(category.rawValue) opens \(identifier.rawValue), which the catalog does not register"
                )
            }
        }
    }

    /// Every category the index lists has a title, a summary, and a symbol, or
    /// it renders as a blank row — and its raw value is what the persisted
    /// order is keyed by, so a case with no raw value could not be reordered.
    func testEveryCategoryDescribesItself() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, "\(category.rawValue) has no title")
            XCTAssertFalse(category.summary.isEmpty, "\(category.rawValue) has no summary")
            XCTAssertFalse(category.symbol.isEmpty, "\(category.rawValue) has no symbol")
            XCTAssertFalse(category.rawValue.isEmpty)
        }
    }
}
