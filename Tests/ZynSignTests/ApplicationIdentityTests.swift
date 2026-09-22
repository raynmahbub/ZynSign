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

    // MARK: - Name resolution

    func testDisplayNameResolvesToDeclaredDisplayName() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example App",
            bundleName: "ExampleKit"
        )
        XCTAssertEqual(identity.displayName, "Example App")
        XCTAssertEqual(identity.declaredDisplayName, "Example App")
        XCTAssertEqual(identity.declaredBundleName, "ExampleKit")
    }

    func testDisplayNameFallsBackToDeclaredBundleName() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            bundleName: "ExampleKit"
        )
        XCTAssertEqual(identity.displayName, "ExampleKit")
        XCTAssertNil(identity.declaredDisplayName)
    }

    func testDisplayNameIsNilWhenNoNameIsDeclared() throws {
        let identity = try ApplicationIdentity(bundleIdentifier: validBundleIdentifier)
        XCTAssertNil(identity.displayName)
    }

    func testEmptyDisplayNameFallsBackToBundleName() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "",
            bundleName: "ExampleKit"
        )
        XCTAssertEqual(identity.displayName, "ExampleKit")
        XCTAssertEqual(identity.declaredDisplayName, "")
    }

    func testBothEmptyNamesResolveToNil() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "",
            bundleName: ""
        )
        XCTAssertNil(identity.displayName)
    }

    func testDeclaredNamesArePreservedVerbatim() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "  Padded  ",
            bundleName: "Café ☕"
        )
        XCTAssertEqual(identity.declaredDisplayName, "  Padded  ")
        XCTAssertEqual(identity.declaredBundleName, "Café ☕")
        XCTAssertEqual(identity.displayName, "  Padded  ")
    }

    // MARK: - Optional values

    func testOptionalVersionFieldsMayBeOmitted() throws {
        let identity = try ApplicationIdentity(bundleIdentifier: validBundleIdentifier)
        XCTAssertNil(identity.shortVersionString)
        XCTAssertNil(identity.buildVersion)
    }

    func testIdentityFromValidatedBundleIdentifier() throws {
        let identifier = try XCTUnwrap(BundleIdentifier(rawValue: validBundleIdentifier))
        let identity = ApplicationIdentity(
            bundleIdentifier: identifier,
            declaredDisplayName: "Example"
        )
        XCTAssertEqual(identity.bundleIdentifier.rawValue, validBundleIdentifier)
        XCTAssertEqual(identity.displayName, "Example")
        XCTAssertNil(identity.declaredBundleName)
    }
}
