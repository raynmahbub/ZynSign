import XCTest
@testable import ZynSign

/// Tests for the shipped theme catalog and hex color parsing.
final class AppThemeCatalogTests: XCTestCase {

    func testFourThemesShip() {
        XCTAssertEqual(AppThemeCatalog.all.count, 4)
        XCTAssertEqual(AppThemeCatalog.all.map(\.displayName), ["ZynSign", "Ember", "Midnight", "Graphite"])
    }

    func testEveryThemeHasValidHexStops() {
        for theme in AppThemeCatalog.all {
            XCTAssertNotNil(ThemeColorStop(hex: theme.accentHex), theme.identifier)
            XCTAssertGreaterThanOrEqual(theme.gradientHex.count, 2, theme.identifier)
            for stop in theme.gradientHex {
                XCTAssertNotNil(ThemeColorStop(hex: stop), "\(theme.identifier):\(stop)")
            }
        }
    }

    func testUnknownIdentifierFallsBackToDefault() {
        XCTAssertEqual(AppThemeCatalog.theme(identifier: "does.not.exist").identifier, ZynSignTheme.defaultIdentifier)
        XCTAssertEqual(AppThemeCatalog.defaultTheme.identifier, ZynSignTheme.zynSign.rawValue)
    }

    func testThemeIdentifiersMatchThePreferenceEnum() {
        let shipped = Set(AppThemeCatalog.all.map(\.identifier))
        let declared = Set(ZynSignTheme.allCases.map(\.rawValue))
        XCTAssertEqual(shipped, declared)
    }

    func testHexParsing() {
        let red = ThemeColorStop(hex: "#FF0000")
        XCTAssertEqual(red?.red ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(red?.green ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(red?.blue ?? -1, 0.0, accuracy: 0.001)
        XCTAssertNotNil(ThemeColorStop(hex: "00FF00"))
        XCTAssertNil(ThemeColorStop(hex: "#GG0000"))
        XCTAssertNil(ThemeColorStop(hex: "#FFF"))
        XCTAssertNil(ThemeColorStop(hex: ""))
    }
}
