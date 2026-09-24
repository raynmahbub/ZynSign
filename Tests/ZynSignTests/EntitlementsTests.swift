import Foundation
import XCTest
@testable import ZynSign

/// Entitlement model, decoding, canonical serialization, blob framing, and
/// provisioning-policy integration.
///
/// The digest expectations in this suite were computed independently of the
/// Swift implementation (host-side Python over the documented canonical form)
/// and are recorded as literals, so a serializer regression cannot silently
/// redefine the digest boundary.
final class EntitlementsTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    // MARK: - Model

    func testUnknownKeysAndTypedValuesArePreserved() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TEAM123456.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAM123456"),
            "com.example.custom.unknown-entitlement": .array([
                .string("alpha"),
                .string("beta"),
            ]),
            "get-task-allow": .boolean(true),
            "com.example.count": .integer(42),
            "com.example.bytes": .data(Data([0x00, 0x01])),
        ])
        XCTAssertEqual(entitlements.count, 6)
        XCTAssertEqual(entitlements["get-task-allow"], .boolean(true))
        XCTAssertEqual(entitlements["com.example.count"], .integer(42))
        // Keys are reported in canonical byte order, not dictionary order.
        XCTAssertEqual(entitlements.keys.first, "application-identifier")
        XCTAssertNil(entitlements["not-present"])
    }

    func testDateValuesAreRejectedRatherThanCoerced() {
        XCTAssertThrowsError(
            try CodeSigningEntitlements(values: [
                "com.example.date": .date(Date(timeIntervalSince1970: 0)),
            ])
        ) { error in
            XCTAssertEqual(error as? EntitlementsError, .unsupportedValueType)
        }
    }

    func testInvalidKeysFailClosed() {
        for key in ["", "bad\nkey", String(repeating: "k", count: 17 * 1_024)] {
            XCTAssertThrowsError(
                try CodeSigningEntitlements(values: [key: .boolean(true)])
            ) { error in
                XCTAssertEqual(error as? EntitlementsError, .invalidKey)
            }
        }
    }

    func testNonFiniteRealIsRejected() {
        XCTAssertThrowsError(
            try CodeSigningEntitlements(values: ["com.example.real": .real(.infinity)])
        ) { error in
            XCTAssertEqual(error as? EntitlementsError, .nonFiniteNumber)
        }
    }

    func testExcessiveNestingIsBounded() {
        var value = ProvisioningProfileValue.boolean(true)
        for _ in 0..<64 {
            value = .dictionary(["d": value])
        }
        XCTAssertThrowsError(
            try CodeSigningEntitlements(values: ["deep": value])
        ) { error in
            XCTAssertEqual(error as? EntitlementsError, .resourceLimitExceeded)
        }
    }

    // MARK: - Decoding

    private func plistXML(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """.utf8)
    }

    func testDecodeValidXMLPlist() throws {
        let data = plistXML("""
        <dict>
        \t<key>get-task-allow</key>
        \t<true/>
        \t<key>com.example.list</key>
        \t<array>
        \t\t<string>a</string>
        \t</array>
        </dict>
        """)
        let entitlements = try EntitlementsPlistParser.parse(data)
        XCTAssertEqual(entitlements["get-task-allow"], .boolean(true))
        XCTAssertEqual(entitlements["com.example.list"], .array([.string("a")]))
    }

    func testDecodeBinaryPlistForm() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList(["get-task-allow": true],
                             format: .binary,
                             options: 0
        ))
        let entitlements = try EntitlementsPlistParser.parse(binary)
        XCTAssertEqual(entitlements["get-task-allow"], .boolean(true))
    }

    func testDecodeMalformedAndWrongRootFailWithTypedErrors() {
        XCTAssertThrowsError(try EntitlementsPlistParser.parse(Data())) {
            XCTAssertEqual($0 as? EntitlementsError, .emptyPayload)
        }
        XCTAssertThrowsError(try EntitlementsPlistParser.parse(Data("not a plist".utf8))) {
            XCTAssertEqual($0 as? EntitlementsError, .malformedPlist)
        }
        XCTAssertThrowsError(try EntitlementsPlistParser.parse(plistXML("<array>\n<string>x</string>\n</array>"))) {
            XCTAssertEqual($0 as? EntitlementsError, .malformedPlist)
        }
        // A date value decodes as a plist but is excluded by the model.
        XCTAssertThrowsError(try EntitlementsPlistParser.parse(plistXML("""
        <dict>
        \t<key>com.example.date</key>
        \t<date>2026-01-01T00:00:00Z</date>
        </dict>
        """))) {
            XCTAssertEqual($0 as? EntitlementsError, .unsupportedValueType)
        }
    }

    // MARK: - Canonical serialization (independently computed vectors)

    func testCanonicalXMLMatchesIndependentVector() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TEAM123456.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAM123456"),
            "com.example.custom.unknown-entitlement": .array([.string("alpha"), .string("beta")]),
            "get-task-allow": .boolean(true),
        ])
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>application-identifier</key>
        \t<string>TEAM123456.com.example.app</string>
        \t<key>com.apple.developer.team-identifier</key>
        \t<string>TEAM123456</string>
        \t<key>com.example.custom.unknown-entitlement</key>
        \t<array>
        \t\t<string>alpha</string>
        \t\t<string>beta</string>
        \t</array>
        \t<key>get-task-allow</key>
        \t<true/>
        </dict>
        </plist>

        """
        let bytes = try EntitlementsCanonicalSerializer().serialize(entitlements)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected)
        XCTAssertEqual(bytes, Data(expected.utf8))
    }

    func testEntitlementsBlobDigestMatchesIndependentVector() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TEAM123456.com.example.app"),
            "com.apple.developer.team-identifier": .string("TEAM123456"),
            "com.example.custom.unknown-entitlement": .array([.string("alpha"), .string("beta")]),
            "get-task-allow": .boolean(true),
        ])
        let blob = try EntitlementsCanonicalSerializer().blob(entitlements)
        XCTAssertEqual(blob.bytes.prefix(4), Data([0xFA, 0xDE, 0x71, 0x71]))
        XCTAssertEqual(blob.serializedLength, 8 + blob.payload.count)
        // Digest expected value computed independently on a host.
        XCTAssertEqual(try digest.digest(blob.bytes, algorithm: .sha256).hexString,
                       "d66960e41d0c3b02c6c445a78d8e0c7957d749f29a7c5e156ee86f5811dcebb2")
    }

    func testEmptyEntitlementsBlobDigestMatchesIndependentVector() throws {
        let entitlements = try CodeSigningEntitlements(values: [:])
        let blob = try EntitlementsCanonicalSerializer().blob(entitlements)
        XCTAssertEqual(try digest.digest(blob.bytes, algorithm: .sha256).hexString,
                       "2a452e000a25dc8b3413f675dabe8e8a84bf29205604ad69d94afa48502683cd")
    }

    func testNestedDictionaryRealIntegerAndDataForms() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "com.example.nested": .dictionary([
                "flag": .boolean(false),
                "inner": .array([.string("a"), .integer(7)]),
            ]),
            "com.example.real": .real(1.5),
        ])
        let blob = try EntitlementsCanonicalSerializer().blob(entitlements)
        XCTAssertEqual(try digest.digest(blob.bytes, algorithm: .sha256).hexString,
                       "d21a6b49cf7c1567601caa4210cd74b8b060b8589f91388413a745cccb9eeaa4")
        // Round-trip: embedded bytes decode back to the same typed value.
        let decoded = try blob.parseEntitlements()
        XCTAssertEqual(decoded, entitlements)
    }

    func testEscapingDataAndIntegerVector() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "com.example.bytes": .data(Data((0..<90).map(UInt8.init))),
            "com.example.count": .integer(42),
            "com.example.markup<>&": .string("a&b<c>d"),
        ])
        let blob = try EntitlementsCanonicalSerializer().blob(entitlements)
        XCTAssertEqual(try digest.digest(blob.bytes, algorithm: .sha256).hexString,
                       "8fe6c7228c3ea4eae3258108a81ec57ffd611bc346bf43e8fc2fba2ece8c6959")
    }

    func testDeterministicAcrossInsertionOrderAndRepeats() throws {
        let first = try CodeSigningEntitlements(values: [
            "b": .boolean(true),
            "a": .string("x"),
            "c": .array([.integer(1), .integer(2)]),
        ])
        let second = try CodeSigningEntitlements(values: [
            "c": .array([.integer(1), .integer(2)]),
            "a": .string("x"),
            "b": .boolean(true),
        ])
        let serializer = EntitlementsCanonicalSerializer()
        let firstBytes = try serializer.serialize(first)
        let secondBytes = try serializer.serialize(second)
        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertEqual(try serializer.serialize(first), firstBytes)
    }

    func testChangingOneValueChangesTheDigest() throws {
        let trueBlob = try EntitlementsCanonicalSerializer()
            .blob(try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)]))
        let falseBlob = try EntitlementsCanonicalSerializer()
            .blob(try CodeSigningEntitlements(values: ["get-task-allow": .boolean(false)]))
        XCTAssertEqual(try digest.digest(trueBlob.bytes, algorithm: .sha256).hexString,
                       "5e0d951237bedfee269217a268ac00ccd46c6994b48387b0ccf43f5ab6e73be2")
        XCTAssertEqual(try digest.digest(falseBlob.bytes, algorithm: .sha256).hexString,
                       "f3f0d1e7c67831b2d478b6d789dc46e6381562a409b68bf24b98cc1a2ea2c65e")
    }

    // MARK: - Blob framing

    func testExistingBlobFramingIsValidated() throws {
        let blob = try EntitlementsCanonicalSerializer()
            .blob(try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)]))
        let reparsed = try EntitlementsBlob(existingBlob: blob.bytes)
        XCTAssertEqual(reparsed.bytes, blob.bytes)
        XCTAssertEqual(try reparsed.parseEntitlements()["get-task-allow"], .boolean(true))

        var wrongMagic = blob.bytes
        wrongMagic[0] ^= 0xFF
        XCTAssertThrowsError(try EntitlementsBlob(existingBlob: wrongMagic)) {
            XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming)
        }
        var wrongLength = blob.bytes
        wrongLength[5] ^= 0x01
        XCTAssertThrowsError(try EntitlementsBlob(existingBlob: wrongLength)) {
            XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming)
        }
        XCTAssertThrowsError(try EntitlementsBlob(existingBlob: Data([0xFA, 0xDE, 0x71]))) {
            XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming)
        }
    }

    // MARK: - Provisioning-policy integration (ZS-020 bridge)

    func testProvisioningCompatibleEntitlementSetEvaluatesCompatible() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            ProvisioningProfileEntitlementKeys.applicationIdentifier:
                .string(ProvisioningPolicyFixtures.teamIdentifier + "." + ProvisioningPolicyFixtures.bundleIdentifier),
            ProvisioningProfileEntitlementKeys.teamIdentifier:
                .string(ProvisioningPolicyFixtures.teamIdentifier),
        ])
        let result = EntitlementsProvisioningValidation.evaluate(
            entitlements: entitlements,
            context: ProvisioningPolicyFixtures.context(),
            clock: FixedEvaluationClock(instant: ProvisioningPolicyFixtures.evaluationDate)
        )
        XCTAssertEqual(result.entitlementsStatus, .satisfied)
        XCTAssertEqual(result.overall, .compatible)
    }

    func testProvisioningMismatchIsReportedAsIncompatible() throws {
        // The application-identifier claim lies outside the profile's scope.
        let entitlements = try CodeSigningEntitlements(values: [
            ProvisioningProfileEntitlementKeys.applicationIdentifier:
                .string("TEAM123456.com.example.other"),
        ])
        let result = EntitlementsProvisioningValidation.evaluate(
            entitlements: entitlements,
            context: ProvisioningPolicyFixtures.context(),
            clock: FixedEvaluationClock(instant: ProvisioningPolicyFixtures.evaluationDate)
        )
        XCTAssertEqual(result.entitlementsStatus, .violated)
        XCTAssertEqual(result.overall, .incompatible)
    }

    func testUnauthorizedClaimIsReportedAsIncompatible() throws {
        // The profile's allowlist does not carry this key.
        let entitlements = try CodeSigningEntitlements(values: [
            "com.example.not-authorized": .string("value"),
        ])
        let result = EntitlementsProvisioningValidation.evaluate(
            entitlements: entitlements,
            context: ProvisioningPolicyFixtures.context(),
            clock: FixedEvaluationClock(instant: ProvisioningPolicyFixtures.evaluationDate)
        )
        XCTAssertEqual(result.entitlementsStatus, .violated)
        XCTAssertEqual(result.overall, .incompatible)
    }

    func testIndeterminateOutcomeIsPreservedNotUpgraded() throws {
        // A claim whose value form has no established comparison rule stays
        // indeterminate; the bridge does not upgrade it to a pass.
        let entitlements = try CodeSigningEntitlements(values: [
            "com.example.data-claim": .data(Data([0x01])),
        ])
        let result = EntitlementsProvisioningValidation.evaluate(
            entitlements: entitlements,
            context: ProvisioningPolicyFixtures.context(
                profile: ProvisioningPolicyFixtures.profile(
                    entitlements: ProvisioningPolicyFixtures.entitlements(
                        applicationIdentifierValue: nil,
                        teamValue: nil,
                        getTaskAllow: nil,
                        additional: ["com.example.data-claim": .data(Data([0x01]))]
                    )
                )
            ),
            clock: FixedEvaluationClock(instant: ProvisioningPolicyFixtures.evaluationDate)
        )
        XCTAssertEqual(result.entitlementsStatus, .indeterminate)
        XCTAssertEqual(result.overall, .indeterminate)
    }

    func testProfileEntitlementsBridgeRejectsExcludedTypes() throws {
        let profileEntitlements = ProvisioningProfileEntitlements(values: [
            "com.example.date": .date(Date(timeIntervalSince1970: 0)),
        ])
        XCTAssertThrowsError(try CodeSigningEntitlements(profileEntitlements: profileEntitlements)) {
            XCTAssertEqual($0 as? EntitlementsError, .unsupportedValueType)
        }
    }
}

extension ProvisioningPolicyValidationResult {
    /// Test conveniences over the existing staged result.
    var entitlementsStatus: ProvisioningPolicyStatus {
        status(for: .entitlements)
    }
}
