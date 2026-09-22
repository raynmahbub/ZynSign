import XCTest
@testable import ZynSign

/// Tests for the application metadata domain model.
final class ApplicationMetadataTests: XCTestCase {

    private let validBundleIdentifier = "com.example.application"

    private func metadata(
        executableName: String? = nil,
        minimumOSVersion: String? = nil,
        deviceFamily: [ApplicationDeviceFamily]? = nil,
        iconName: String? = nil
    ) throws -> ApplicationMetadata {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example",
            shortVersionString: "1.0",
            buildVersion: "1"
        )
        return ApplicationMetadata(
            identity: identity,
            executableName: executableName,
            minimumOSVersion: minimumOSVersion,
            deviceFamily: deviceFamily,
            iconName: iconName
        )
    }

    // MARK: - Device families

    func testKnownDeviceFamiliesAreInterpreted() {
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 1), .phone)
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 2), .pad)
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 3), .tv)
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 4), .watch)
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 6), .visionOS)
    }

    func testUnknownDeviceFamiliesArePreserved() {
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 0), .unknown(0))
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 5), .unknown(5))
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 7), .unknown(7))
        XCTAssertEqual(ApplicationDeviceFamily.interpret(rawValue: 999), .unknown(999))
    }

    // MARK: - Value semantics

    func testMetadataWithSameValuesAreEqual() throws {
        let first = try metadata(executableName: "Example", deviceFamily: [.phone, .pad])
        let second = try metadata(executableName: "Example", deviceFamily: [.phone, .pad])
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testMetadataDiffersBySingleField() throws {
        let base = try metadata(executableName: "Example")
        XCTAssertNotEqual(base, try metadata(executableName: "Other"))
        XCTAssertNotEqual(base, try metadata(minimumOSVersion: "17.0"))
        XCTAssertNotEqual(base, try metadata(deviceFamily: [.pad]))
        XCTAssertNotEqual(base, try metadata(iconName: "AppIcon"))
    }

    func testMetadataEmbedsTheDeclaredIdentity() throws {
        let identity = try ApplicationIdentity(
            bundleIdentifier: validBundleIdentifier,
            displayName: "Example",
            shortVersionString: "1.4.2",
            buildVersion: "87"
        )
        let metadata = try ApplicationMetadata(identity: identity)
        XCTAssertEqual(metadata.identity, identity)
        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validBundleIdentifier)
    }
}
