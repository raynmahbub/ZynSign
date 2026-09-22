import XCTest
@testable import ZynSign

final class ApplicationIdentityTests: XCTestCase {

    private let validBundleIdentifier = "com.example.application"

    func testCreatesIdentityWithDeclaredValues() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example",
            shortVersionString: "1.4.2",
            buildVersion: "87"
        )
        XCTAssertEqual(identity.bundleIdentifier.rawValue, validBundleIdentifier)
        XCTAssertEqual(identity.displayName, "Example")
        XCTAssertEqual(identity.shortVersionString, "1.4.2")
        XCTAssertEqual(identity.buildVersion, "87")
    }

    func testPreservesDeclaredStringsVerbatim() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "  Example  ",
            shortVersionString: "v1",
            buildVersion: "beta build"
        )
        XCTAssertEqual(identity.displayName, "  Example  ")
        XCTAssertEqual(identity.shortVersionString, "v1")
        XCTAssertEqual(identity.buildVersion, "beta build")
    }

    func testThrowsTypedErrorForInvalidBundleIdentifier() {
        XCTAssertThrowsError(
            try ApplicationIdentity(
                bundleIdentifier: "invalid..identifier",
                displayName: "Example",
                shortVersionString: "1.0",
                buildVersion: "1"
            )
        ) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError, got \(type(of: error))")
            }
            XCTAssertEqual(zynSignError.category, .invalidInput)
            XCTAssertFalse(zynSignError.userMessage.isEmpty)
        }
    }

    func testIdentitiesWithSameValuesAreEqual() throws {
        let first = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example",
            shortVersionString: "1.0",
            buildVersion: "1"
        )
        let second = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example",
            shortVersionString: "1.0",
            buildVersion: "1"
        )
        XCTAssertEqual(first, second)
    }
}
