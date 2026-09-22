import XCTest
@testable import ZynSign

final class BundleIdentifierTests: XCTestCase {

    func testAcceptsTypicalIdentifier() {
        let identifier = BundleIdentifier(rawValue: "com.example.application")
        XCTAssertEqual(identifier?.rawValue, "com.example.application")
    }

    func testAcceptsSingleComponentIdentifier() {
        XCTAssertNotNil(BundleIdentifier(rawValue: "application"))
    }

    func testAcceptsHyphensMixedCaseAndDigits() {
        let identifier = BundleIdentifier(rawValue: "Com.Example9.My-App")
        XCTAssertEqual(identifier?.rawValue, "Com.Example9.My-App")
    }

    func testRejectsEmptyIdentifier() {
        XCTAssertNil(BundleIdentifier(rawValue: ""))
    }

    func testRejectsEmptyComponents() {
        XCTAssertNil(BundleIdentifier(rawValue: ".com.example"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.example."))
        XCTAssertNil(BundleIdentifier(rawValue: "com..example"))
    }

    func testRejectsDisallowedCharacters() {
        XCTAssertNil(BundleIdentifier(rawValue: "com example.app"))
        XCTAssertNil(BundleIdentifier(rawValue: "com/example"))
        XCTAssertNil(BundleIdentifier(rawValue: "com_example.app"))
        XCTAssertNil(BundleIdentifier(rawValue: "com:example"))
    }

    func testRejectsNonASCIILettersAndDigits() {
        XCTAssertNil(BundleIdentifier(rawValue: "com.exämple.app"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.example.应用"))
    }

    func testRejectsIdentifierOverMaximumLength() {
        let overLimit = String(repeating: "a", count: BundleIdentifier.maximumLength + 1)
        XCTAssertNil(BundleIdentifier(rawValue: overLimit))
    }

    func testAcceptsIdentifierAtMaximumLength() {
        let atLimit = String(repeating: "a", count: BundleIdentifier.maximumLength)
        XCTAssertNotNil(BundleIdentifier(rawValue: atLimit))
    }

    func testDescriptionIsTheRawValue() {
        let identifier = BundleIdentifier(rawValue: "com.example.application")
        XCTAssertEqual(identifier?.description, "com.example.application")
    }
}
