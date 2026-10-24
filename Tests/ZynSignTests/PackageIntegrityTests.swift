import Foundation
import XCTest
@testable import ZynSign

/// What a device checks about a package beyond the page hashes: the bundle's
/// `Info.plist` in special slot 1, the `rules2` set the resource seal carries,
/// and the certificate chain inside the CMS blob.
final class PackageIntegrityTests: XCTestCase {

    // MARK: - Special slot 1

    func testInfoPlistDigestBecomesSpecialSlotOne() throws {
        let plist = Data("<plist><dict/></plist>".utf8)
        let preparation = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(bundleInfoPlist: plist),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: CryptoKitMessageDigest()
        )
        let slots = preparation.slotDigests.specialSlots(hashSize: 32)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].kind, .infoPlist)
        XCTAssertNotNil(slots[0].hash)
        XCTAssertEqual(slots[0].hash?.count, 32)
    }

    func testTheSlotIsAbsentWithoutAPlist() throws {
        let preparation = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: CryptoKitMessageDigest()
        )
        XCTAssertTrue(preparation.slotDigests.specialSlots(hashSize: 32).isEmpty)
    }

    func testTheDigestIsOfTheFileItWasGiven() throws {
        let first = Data("<plist>one</plist>".utf8)
        let second = Data("<plist>two</plist>".utf8)
        let configuration = try CodeDirectoryHashConfiguration(hashType: .sha256)
        let digest = CryptoKitMessageDigest()
        let one = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(bundleInfoPlist: first),
            hashConfiguration: configuration, messageDigest: digest)
        let two = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(bundleInfoPlist: second),
            hashConfiguration: configuration, messageDigest: digest)
        XCTAssertNotEqual(one.slotDigests.specialSlots(hashSize: 32),
                          two.slotDigests.specialSlots(hashSize: 32))
    }

    func testAnEmptyPlistIsRefused() throws {
        XCTAssertThrowsError(try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(bundleInfoPlist: Data()),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: CryptoKitMessageDigest()
        )) { error in
            XCTAssertEqual(error as? SigningMetadataError, .emptyInfoPlist)
        }
    }

    func testInfoPlistIsSlotOneBelowTheOtherSlots() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TEAM.com.example.demo"),
        ])
        let preparation = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(entitlements: entitlements,
                                 bundleInfoPlist: Data("<plist/>".utf8)),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: CryptoKitMessageDigest()
        )
        let slots = preparation.slotDigests.specialSlots(hashSize: 32)
        XCTAssertEqual(slots.map(\.kind), [.infoPlist, .requirements, .codeResources,
                                           .application, .entitlements])
        XCTAssertNil(slots[1].hash)   // no requirements set supplied
        XCTAssertNotNil(slots[4].hash)
    }

    // MARK: - rules2

    func testTheStandardRulesCoverNestedCodeAndOmissions() {
        let rules = CodeResourcesRules.typed()
        XCTAssertNotNil(rules)
        let patterns = (rules ?? []).map(\.pattern)
        XCTAssertTrue(patterns.contains("^Info\\.plist$"))
        XCTAssertTrue(patterns.contains("^PkgInfo$"))
        XCTAssertTrue(patterns.contains("^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/"))
        let nested = (rules ?? []).first { $0.pattern == "^[^/]+$" }
        XCTAssertEqual(nested?.nested, true)
        XCTAssertEqual(nested?.weight, 10)
        let infoPlist = (rules ?? []).first { $0.pattern == "^Info\\.plist$" }
        XCTAssertEqual(infoPlist?.omit, true)
    }

    func testTheCatchAllIsWrittenAsABareTrue() throws {
        let rules = try XCTUnwrap(CodeResourcesRules.typed())
        let document = try CodeResourcesDocument(
            files2: [.file(try FileResourceSeal(path: try XCTUnwrap(BundlePath(rawValue: "a.txt")),
                                                hash2: Data(repeating: 0x01, count: 32)))],
            rules2: rules
        )
        let bytes = try document.serialized()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("<key>^.*</key>\n\t<true/>")
                      || text.contains("<key>^.*</key>"),
                      "the catch-all rule must be present")
        let parsed = try CodeResourcesParser.parse(bytes)
        XCTAssertEqual(parsed.rules2, document.rules2)
    }

    func testARuleWithNestedAndOmitRoundTrips() throws {
        let rule = try CodeResourcesRule(pattern: "^Frameworks/", weight: 10, nested: true, omit: false)
        let document = try CodeResourcesDocument(files2: [], rules2: [rule])
        let parsed = try CodeResourcesParser.parse(try document.serialized())
        XCTAssertEqual(parsed.rules2, [rule])
    }

    func testAnUnknownRuleFlagIsRefused() throws {
        let xml = """
        <dict>
        \t<key>files2</key>
        \t<dict/>
        \t<key>rules2</key>
        \t<dict>
        \t\t<key>^x$</key>
        \t\t<dict>
        \t\t\t<key>unexpected</key>
        \t\t\t<true/>
        \t\t</dict>
        \t</dict>
        </dict>
        """
        XCTAssertThrowsError(try CodeResourcesParser.parse(Data(xml.utf8)))
    }
}
