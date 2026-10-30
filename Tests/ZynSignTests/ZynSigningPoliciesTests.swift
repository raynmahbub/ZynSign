import Foundation
import XCTest
@testable import ZynSign

final class ZynSigningPoliciesTests: XCTestCase {

    func testPPQStealthModeScrubsKeywordsAndPrependsZynPrefix() {
        let token = "A1B2C3D4"
        let rewritten = PPQProtectionPolicy.resolveBundleIdentifier(
            original: "com.google.ios.youtube",
            explicitReplacement: nil,
            ppqMode: .stealth,
            ppqToken: token
        )
        XCTAssertTrue(rewritten.hasPrefix("zyn."))
        XCTAssertFalse(rewritten.localizedCaseInsensitiveContains("youtube"))
        XCTAssertFalse(rewritten.localizedCaseInsensitiveContains("google"))
        XCTAssertTrue(rewritten.contains(token.lowercased()))
    }

    func testPPQSuffixTokenAppendsCleanIdentifierSegment() {
        let result = PPQProtectionPolicy.resolveBundleIdentifier(
            original: "io.zynsign.sample",
            explicitReplacement: nil,
            ppqMode: .suffixToken,
            ppqToken: "9F8E7D"
        )
        XCTAssertEqual(result, "io.zynsign.sample.9f8e7d")
    }

    func testMachOPatcherRewritesInstallNameArm64eAndSDKVersion() throws {
        let initial = Self.makeSyntheticArm64MachO(
            fileType: 0x2,
            installName: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        )
        let (arm64ePatched, arm64eChanged) = MachOBinaryPatcher.fixLegacyArm64eSlices(in: initial)
        XCTAssertTrue(arm64eChanged)

        let (sdkPatched, sdkChanged) = MachOBinaryPatcher.patchMinimumSDKVersion(in: arm64ePatched)
        XCTAssertTrue(sdkChanged)

        let (dylibPatched, rewrittenCount) = try MachOBinaryPatcher.rewriteInstallNames(
            in: sdkPatched,
            replacements: [
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate":
                    "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
            ]
        )
        XCTAssertEqual(rewrittenCount, 1)
        XCTAssertTrue(MachOBinaryPatcher.listLinkedDylibs(in: dylibPatched).contains("@rpath/CydiaSubstrate.framework/CydiaSubstrate"))
    }

    func testBinaryEntitlementMergerFiltersUnauthorizedAndIsolatesKeychain() throws {
        let profileValues: [String: ProvisioningProfileValue] = [
            "application-identifier": .string("TEAM123456.*"),
            "com.apple.developer.team-identifier": .string("TEAM123456"),
            "keychain-access-groups": .array([.string("TEAM123456.*")])
        ]
        let baseEntitlements = try CodeSigningEntitlements(values: profileValues)

        let binaryPlist: [String: Any] = [
            "application-identifier": "OLDTEAM999.io.zynsign.client",
            "keychain-access-groups": ["OLDTEAM999.shared"],
            "com.apple.private.security.no-sandbox": true
        ]
        let binaryXML = try PropertyListSerialization.data(fromPropertyList: binaryPlist, format: .xml, options: 0)

        let merged = try BinaryEntitlementMerger.resolve(
            profileEntitlements: baseEntitlements,
            binaryEntitlementsXML: binaryXML,
            resolvedBundleIdentifier: "io.zynsign.client",
            teamIdentifier: "TEAM123456",
            mergesBinaryEntitlements: true,
            isolatesKeychainGroup: true,
            overrides: [:],
            removedKeys: [],
            rawXMLOverride: nil
        )
        XCTAssertNil(merged.entitlements.values["com.apple.private.security.no-sandbox"])
        XCTAssertEqual(
            merged.entitlements.values["keychain-access-groups"],
            .array([.string("TEAM123456.io.zynsign.client")])
        )
    }

    func testBinaryMergeDoesNotExpandFalseOrOtherWildcardScopes() throws {
        let profile = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TEAM123456.com.allowed.*"),
            "com.apple.developer.team-identifier": .string("TEAM123456"),
            "keychain-access-groups": .array([.string("OTHERTEAM.*")]),
            "get-task-allow": .boolean(false),
            "example.groups": .array([.string("TEAM123456.allowed.*")])
        ])
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "get-task-allow": true,
            "keychain-access-groups": ["OLDTEAM.secret"],
            "example.groups": ["TEAM123456.allowed.one", "TEAM123456.other.two"]
        ], format: .xml, options: 0)
        let result = try BinaryEntitlementMerger.resolve(profileEntitlements: profile,
            binaryEntitlementsXML: data, resolvedBundleIdentifier: "com.outside.app",
            teamIdentifier: "TEAM123456", mergesBinaryEntitlements: true, isolatesKeychainGroup: false)
        XCTAssertEqual(result.entitlements.values["get-task-allow"], .boolean(false))
        XCTAssertEqual(result.entitlements.values["application-identifier"], .string("TEAM123456.com.allowed.*"))
        XCTAssertEqual(result.entitlements.values["keychain-access-groups"], .array([.string("OTHERTEAM.*")]))
        XCTAssertEqual(result.entitlements.values["example.groups"], .array([.string("TEAM123456.allowed.one")]))
    }

    func testIsolationRequiresProfileAuthorization() throws {
        let profile = try CodeSigningEntitlements(values: [
            "keychain-access-groups": .array([.string("OTHERTEAM.*")])
        ])
        XCTAssertThrowsError(try BinaryEntitlementMerger.resolve(profileEntitlements: profile,
            binaryEntitlementsXML: nil, resolvedBundleIdentifier: "com.example.app",
            teamIdentifier: "TEAM123456", mergesBinaryEntitlements: false, isolatesKeychainGroup: true)) {
            XCTAssertEqual($0 as? BinaryEntitlementMerger.MergeError, .keychainIsolationNotAuthorized)
        }
    }

    func testBinaryMergeRejectsMalformedEntitlements() throws {
        let profile = try CodeSigningEntitlements(values: [:])
        XCTAssertThrowsError(try BinaryEntitlementMerger.resolve(profileEntitlements: profile,
            binaryEntitlementsXML: Data("not a plist".utf8), resolvedBundleIdentifier: "com.example.app",
            teamIdentifier: "TEAM123456", mergesBinaryEntitlements: true, isolatesKeychainGroup: false))
    }

    private static func makeSyntheticArm64MachO(fileType: UInt32, installName: String) -> Data {
        var bytes = Data(count: 4096)
        func put32(_ o: Int, _ v: UInt32) {
            bytes[o] = UInt8(v & 0xFF)
            bytes[o + 1] = UInt8((v >> 8) & 0xFF)
            bytes[o + 2] = UInt8((v >> 16) & 0xFF)
            bytes[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        put32(0, 0xFEED_FACF)
        put32(4, 0x0100_000C)
        put32(8, 0x0000_0002) // legacy arm64e subtype without high capability bit
        put32(12, fileType)

        // Command 1: LC_BUILD_VERSION (24 bytes) at offset 32
        put32(32, 0x32)
        put32(36, 24)
        put32(40, 2) // iOS
        put32(44, 0x0010_0000) // minos 16.0
        put32(48, 0x0011_0000) // sdk 17.0
        put32(52, 0)

        // Command 2: LC_LOAD_DYLIB at offset 56
        let nameBytes = Array(installName.utf8) + [0]
        let dylibCmdSize = (24 + nameBytes.count + 7) & ~7
        put32(56, 0x0C)
        put32(60, UInt32(dylibCmdSize))
        put32(64, 24)
        put32(68, 2)
        put32(72, 0x0001_0000)
        put32(76, 0x0001_0000)
        for (idx, b) in nameBytes.enumerated() {
            bytes[80 + idx] = b
        }

        put32(16, 2)
        put32(20, UInt32(24 + dylibCmdSize))
        return bytes
    }
}
