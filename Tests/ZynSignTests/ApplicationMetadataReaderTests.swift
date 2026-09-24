import Foundation
import XCTest
@testable import ZynSign

/// Tests for the pure domain reader that extracts application metadata from
/// the content of a bundle's information file.
///
/// Every fixture is one of three kinds: a property list generated in memory
/// from a literal root value, a hand-written XML property list (used where
/// the root shape itself is the subject), or raw bytes that are not a
/// property list at all. No real package, signing material, or binary
/// fixture appears here.
final class ApplicationMetadataReaderTests: XCTestCase {

    private let validIdentifier = "com.example.synthetic"

    // MARK: - Fixture construction

    /// Builds property list bytes for a literal root value in the requested
    /// format. Failing to build a fixture is a defect in the test, so it
    /// fails loudly.
    private func makePlist(
        _ root: Any,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) -> Data {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: format,
            options: []
        ) else {
            XCTFail("Could not build a \(format) property list fixture")
            return Data()
        }
        return data
    }

    /// Builds XML property list bytes around a literal root element, for
    /// cases where the root shape itself is the subject of the test.
    private func rawXMLPlist(_ rootElement: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            \(rootElement)
            </plist>
            """.utf8
        )
    }

    /// A hand-written OpenStep property list, in the format ZynSign refuses.
    private func openStepPlist() -> Data {
        Data(
            """
            {
                CFBundleIdentifier = "com.example.synthetic";
            }
            """.utf8
        )
    }

    private func root(excludingIdentifier: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
        var values: [String: Any] = extra
        if !excludingIdentifier {
            values[BundleInformationKeys.bundleIdentifier] = validIdentifier
        }
        return values
    }

    // MARK: - Valid metadata

    func testReadsCompleteMetadata() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.displayName: "Synthetic App",
            BundleInformationKeys.bundleName: "Synthetic",
            BundleInformationKeys.shortVersion: "1.4.2",
            BundleInformationKeys.buildVersion: "87",
            BundleInformationKeys.executable: "SyntheticApp",
            BundleInformationKeys.minimumOSVersion: "17.0",
            BundleInformationKeys.deviceFamily: [1, 2],
            BundleInformationKeys.iconName: "AppIcon",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)

        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertEqual(metadata.identity.declaredDisplayName, "Synthetic App")
        XCTAssertEqual(metadata.identity.declaredBundleName, "Synthetic")
        XCTAssertEqual(metadata.identity.displayName, "Synthetic App")
        XCTAssertEqual(metadata.identity.shortVersionString, "1.4.2")
        XCTAssertEqual(metadata.identity.buildVersion, "87")
        XCTAssertEqual(metadata.executableName, "SyntheticApp")
        XCTAssertEqual(metadata.minimumOSVersion, "17.0")
        XCTAssertEqual(metadata.deviceFamily, [.phone, .pad])
        XCTAssertEqual(metadata.iconName, "AppIcon")
    }

    func testReadsMetadataFromBinaryPropertyList() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.displayName: "Synthetic App",
            BundleInformationKeys.executable: "SyntheticApp",
            BundleInformationKeys.deviceFamily: [1],
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values, format: .binary))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertEqual(metadata.identity.displayName, "Synthetic App")
        XCTAssertEqual(metadata.executableName, "SyntheticApp")
        XCTAssertEqual(metadata.deviceFamily, [.phone])
    }

    func testUnknownKeysDoNotAffectExtraction() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            "CFBundleURLTypes": [[ "CFBundleURLSchemes": ["synthetic", "synsign"] ]],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "UnknownNested": ["deeply": ["nested": [1, 2, 3]]],
            "UnknownData": Data([0x00, 0x01, 0x02]),
            "UnknownDate": Date(timeIntervalSince1970: 0),
            "UnknownBoolean": true,
            "UnknownNumber": 42,
            "UnknownLongString": String(repeating: "x", count: 10_000),
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(
            metadata,
            ApplicationMetadata(identity: try ApplicationIdentity(bundleIdentifier: validIdentifier))
        )
    }

    func testLargeButReasonableMetadataIsExtracted() throws {
        var values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.shortVersion: String(repeating: "1.0.", count: 100) + "final",
            BundleInformationKeys.buildVersion: String(repeating: "9", count: 255),
        ]
        for index in 0..<100 {
            values["UnmodelledKey\(index)"] = "value \(index)"
        }
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.shortVersionString, String(repeating: "1.0.", count: 100) + "final")
        XCTAssertEqual(metadata.identity.buildVersion, String(repeating: "9", count: 255))
    }

    func testUnusualVersionValuesArePreservedVerbatim() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.shortVersion: "v1.4.2-beta.3+build.7",
            BundleInformationKeys.buildVersion: "87-rc2",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.shortVersionString, "v1.4.2-beta.3+build.7")
        XCTAssertEqual(metadata.identity.buildVersion, "87-rc2")
    }

    func testEmptyVersionStringsArePreserved() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.shortVersion: "",
            BundleInformationKeys.buildVersion: "",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertTrue(examination.isValid)
        XCTAssertEqual(metadata.identity.shortVersionString, "")
        XCTAssertEqual(metadata.identity.buildVersion, "")
    }

    func testUnicodeNamesArePreservedVerbatim() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.displayName: "Müllers Kaffee ☕",
            BundleInformationKeys.bundleName: "Bäckerei",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.declaredDisplayName, "Müllers Kaffee ☕")
        XCTAssertEqual(metadata.identity.declaredBundleName, "Bäckerei")
        XCTAssertEqual(metadata.identity.displayName, "Müllers Kaffee ☕")
    }

    func testDeviceFamilyPreservesUnknownValues() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.deviceFamily: [1, 99],
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.deviceFamily, [.phone, .unknown(99)])
    }

    func testEmptyDeviceFamilyArrayIsPreserved() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.deviceFamily: [Any](),
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.deviceFamily, [])
    }

    func testEmptyExecutableNameIsTreatedAsAbsent() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.executable: "",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertTrue(examination.isValid)
        XCTAssertNil(try XCTUnwrap(examination.metadata).executableName)
    }

    func testEmptyDictionaryDeclaresNoRequiredMetadata() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([String: Any]()))
        XCTAssertFalse(examination.isValid)
        XCTAssertNil(examination.metadata)
        XCTAssertEqual(examination.findings.first?.code, .missingRequiredMetadata)
    }

    func testFirstFailureInFixedOrderWins() throws {
        // Both problems are present; the required identifier is examined
        // first, so its absence is the reported failure.
        let values: [String: Any] = [
            BundleInformationKeys.bundleName: 42,
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(examination.findings.count, 1)
        XCTAssertEqual(examination.findings.first?.code, .missingRequiredMetadata)
    }

    // MARK: - Missing values

    func testMissingBundleIdentifierIsMissingRequired() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist(root(excludingIdentifier: true)))
        XCTAssertFalse(examination.isValid)
        XCTAssertNil(examination.metadata)
        XCTAssertEqual(examination.findings.count, 1)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.code, .missingRequiredMetadata)
        XCTAssertTrue(finding.detail.contains(BundleInformationKeys.bundleIdentifier))
    }

    func testMissingOptionalFieldsYieldNilValues() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist(root()))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertNil(metadata.identity.declaredDisplayName)
        XCTAssertNil(metadata.identity.declaredBundleName)
        XCTAssertNil(metadata.identity.displayName)
        XCTAssertNil(metadata.identity.shortVersionString)
        XCTAssertNil(metadata.identity.buildVersion)
        XCTAssertNil(metadata.executableName)
        XCTAssertNil(metadata.minimumOSVersion)
        XCTAssertNil(metadata.deviceFamily)
        XCTAssertNil(metadata.iconName)
    }

    // MARK: - Incorrect types

    func testIntegerWhereStringExpected() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: 1234,
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("integer"))
    }

    func testArrayWhereStringExpected() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.displayName: ["First", "Second"],
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("array"))
    }

    func testDictionaryWhereStringExpected() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.shortVersion: ["part": "1.0"],
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("dictionary"))
    }

    func testBooleanWhereStringExpected() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.buildVersion: true,
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("boolean"))
    }

    func testDataWhereStringExpected() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.executable: Data([0x90, 0x00, 0x00, 0x00]),
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("data"))
    }

    func testOptionalKeyWithUnexpectedTypeFailsExamination() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.iconName: 7,
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains(BundleInformationKeys.iconName))
    }

    func testMalformedNestedStructureFailsExamination() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.deviceFamily: [1, "two"],
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("index 1"))
    }

    func testInvalidRootArray() throws {
        let examination = ApplicationMetadataReader.read(
            from: rawXMLPlist("<array><string>not-a-dictionary</string></array>")
        )
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .unreadableInfoPlist)
        XCTAssertTrue(finding.detail.contains("array"))
    }

    func testInvalidRootString() throws {
        let examination = ApplicationMetadataReader.read(
            from: rawXMLPlist("<string>not-a-dictionary</string>")
        )
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(try XCTUnwrap(examination.findings.first).code, .unreadableInfoPlist)
    }

    func testInvalidRootInteger() throws {
        let examination = ApplicationMetadataReader.read(
            from: rawXMLPlist("<integer>42</integer>")
        )
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(try XCTUnwrap(examination.findings.first).code, .unreadableInfoPlist)
    }

    // MARK: - Unreadable and unsupported input

    func testMalformedPlistBytesAreUnreadable() throws {
        let examination = ApplicationMetadataReader.read(from: Data("this is not a property list".utf8))
        XCTAssertFalse(examination.isValid)
        XCTAssertNil(examination.metadata)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .unreadableInfoPlist)
        XCTAssertTrue(finding.detail.contains("cause:"))
        XCTAssertFalse(finding.detail.contains("this is not a property list"))
    }

    func testEmptyFileIsUnreadable() throws {
        let examination = ApplicationMetadataReader.read(from: Data())
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(try XCTUnwrap(examination.findings.first).code, .unreadableInfoPlist)
    }

    func testTruncatedPlistIsUnreadable() throws {
        let complete = makePlist(root())
        let truncated = Data(complete.prefix(complete.count - 8))
        let examination = ApplicationMetadataReader.read(from: truncated)
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(try XCTUnwrap(examination.findings.first).code, .unreadableInfoPlist)
    }

    func testOpenStepPropertyListIsUnsupported() throws {
        let examination = ApplicationMetadataReader.read(from: openStepPlist())
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .unsupportedMetadataFormat)
        XCTAssertEqual(finding.category, .unsupportedInput)
    }

    // MARK: - Invalid values

    func testEmptyBundleIdentifierIsInvalid() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: "",
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
    }

    func testSyntacticallyInvalidBundleIdentifier() throws {
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: "com..bad",
        ]))
        XCTAssertFalse(examination.isValid)
        let finding = try XCTUnwrap(examination.findings.first)
        XCTAssertEqual(finding.code, .malformedMetadata)
        XCTAssertTrue(finding.detail.contains("com..bad"))
    }

    func testOversizedBundleIdentifier() throws {
        let oversized = String(repeating: "a", count: BundleIdentifier.maximumLength + 1)
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: oversized,
        ]))
        XCTAssertFalse(examination.isValid)
        XCTAssertEqual(try XCTUnwrap(examination.findings.first).code, .malformedMetadata)
    }

    // MARK: - Hostile declarations

    func testHostileExecutableNamesAreRejectedAsUnsafe() throws {
        for name in ["/etc/passwd", "../Escape", ".", "..", "C:Evil"] {
            let examination = ApplicationMetadataReader.read(from: makePlist([
                BundleInformationKeys.bundleIdentifier: validIdentifier,
                BundleInformationKeys.executable: name,
            ]))
            XCTAssertFalse(examination.isValid, "executable name '\(name)' must be rejected")
            XCTAssertEqual(examination.findings.first?.code, .malformedMetadata, "executable name '\(name)'")
        }
    }

    func testHostileIdentifierValueIsTruncatedInDiagnostics() throws {
        // Long, with a disallowed character: the identifier must fail, and
        // the diagnostic must truncate the value.
        let hostile = "com" + String(repeating: "x", count: 200) + "!"
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: hostile,
        ]))
        XCTAssertFalse(examination.isValid)
        let detail = try XCTUnwrap(try XCTUnwrap(examination.findings.first).detail)
        XCTAssertTrue(detail.count < 200, "the diagnostic must truncate hostile values")
    }

    func testControlCharacterInValueDoesNotReachDiagnostics() throws {
        // Carriage-return is legal in a binary property list and illegal in
        // an XML one, so this fixture uses the binary format.
        let hostile = "Bad\u{13}Name"
        let examination = ApplicationMetadataReader.read(from: makePlist([
            BundleInformationKeys.bundleIdentifier: hostile,
        ], format: .binary))
        XCTAssertFalse(examination.isValid)
        let detail = try XCTUnwrap(try XCTUnwrap(examination.findings.first).detail)
        XCTAssertFalse(detail.contains("\u{13}"), "control characters must not reach diagnostics")
        XCTAssertTrue(detail.contains("\u{FFFD}"))
    }

    func testUnmodelledURLSchemesContributeNothing() throws {
        let values: [String: Any] = [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            "CFBundleURLTypes": [[ "CFBundleURLSchemes": ["synthetic", "https"] ]],
            "UnknownLaunchURL": "https://example.com",
        ]
        let examination = ApplicationMetadataReader.read(from: makePlist(values))
        XCTAssertTrue(examination.isValid)
        let metadata = try XCTUnwrap(examination.metadata)
        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertNil(metadata.executableName)
    }
}
