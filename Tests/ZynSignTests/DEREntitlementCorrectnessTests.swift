import Foundation
import XCTest
@testable import ZynSign

/// Phase 1 DER correctness regression: the five audit findings as executable
/// expectations.
///
/// Each test names the finding it covers and the typed refusal it expects,
/// with redacted diagnostics. New entitlement string policy, bounded
/// decoding, node-budget and diagnostics tests live here so a future
/// change that reintroduces any finding fails immediately.
///
/// DER remains disabled by default; these tests exercise the single-image
/// path directly and do not widen the application pipeline (which still
/// refuses `emitDEREntitlements` before any allocation).
final class DEREntitlementCorrectnessTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    // MARK: - Finding 1: XML and DER semantic consistency

    func testXMLInvalidScalarAndControlCasesAreRejectedAtTheirBoundaries() throws {
        // Swift strings can represent these XML-invalid controls/noncharacters,
        // but cannot represent unpaired surrogate Unicode scalars. Exercise
        // model validation and the XML serializer directly without claiming an
        // unreachable DER-serializer path through CodeSigningEntitlements.
        let invalidStrings = [
            "a\u{0}b",           // NUL
            "a\u{01}b",          // SOH
            "a\u{02}b",
            "a\u{1F}b",          // Unit separator
            "a\u{0B}b",          // Vertical tab
            "a\u{0C}b",          // Form feed
            "a\u{FFFE}b",        // Noncharacter
            "a\u{FFFF}b",
        ]
        for text in invalidStrings {
            XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": .string(text)])) { error in
                XCTAssertEqual(error as? EntitlementsError, .invalidXMLString)
            }
            XCTAssertThrowsError(try CanonicalPropertyListXMLSerializer().serialize(
                root: .dictionary(["k": .string(text)])
            )) { error in
                XCTAssertEqual(error as? CanonicalPropertyListError, .invalidString)
            }
        }
    }

    func testMalformedUTF8DERStringIsRejectedAtDecoderBoundary() throws {
        // SET { SEQUENCE { UTF8String "k", UTF8String [invalid 0xC0] } }.
        let malformedUTF8 = Data([0x31, 0x08, 0x30, 0x06, 0x0C, 0x01, 0x6B, 0x0C, 0x01, 0xC0])
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(malformedUTF8)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    func testAllowedControlCharactersRoundTripIdentically() throws {
        // Tab, line-feed and carriage-return are allowed; CR is escaped as
        // &#xD; in XML but parses back to the same string, and DER carries
        // the raw byte. A claim with any of those must round-trip through
        // both encodings to the same normalized claim set.
        let cases: [String] = [
            "a\tb",
            "a\nb",
            "a\rb",              // CR
            "a\r\nb",
            "a\t\n\rb",
            "a\r\rb\n\n\tc",
        ]
        for text in cases {
            let entitlements = try CodeSigningEntitlements(values: ["key": .string(text)])
            // XML canonical round-trip
            let xmlBlob = try EntitlementsCanonicalSerializer().blob(entitlements)
            let xmlPayload = xmlBlob.payload
            XCTAssertTrue(String(decoding: xmlPayload, as: UTF8.self).contains(text.contains("\r") ? "&#xD;" : text))
            let xmlClaims = try EntitlementsPlistParser.parse(xmlPayload)
            XCTAssertTrue(xmlClaims.hasSameSerializedClaims(as: entitlements), "XML round-trip failed for \(text.debugDescription)")
            let xmlReserialized = try EntitlementsCanonicalSerializer().serialize(xmlClaims)
            XCTAssertEqual(xmlReserialized, xmlPayload, "XML re-serialization not canonical for \(text.debugDescription)")

            // DER canonical round-trip
            let derBlob = try DEREntitlementsSerializer().blob(entitlements)
            let derClaims = try DEREntitlementsDecoder().decode(blob: derBlob.bytes)
            XCTAssertTrue(derClaims.hasSameSerializedClaims(as: entitlements), "DER round-trip failed for \(text.debugDescription)")
            XCTAssertTrue(derClaims.hasSameSerializedClaims(as: xmlClaims), "XML/DER semantic mismatch for \(text.debugDescription)")
            let derReencoded = try DEREntitlementsSerializer().blob(derClaims)
            XCTAssertEqual(derReencoded.bytes, derBlob.bytes, "DER re-encode not canonical for \(text.debugDescription)")
        }
    }

    func testUnicodeStringsArePreservedInBothEncodings() throws {
        let unicodeCases: [String] = [
            "é — ✓",
            "日本語",
            "emoji 🚀 test",
            "𝄞 musical",
            "mixed a\tb\nc\rd é 日本語 🚀",
            String(repeating: "a", count: 100) + "✓",
        ]
        for text in unicodeCases {
            let e = try CodeSigningEntitlements(values: ["k": .string(text)])
            let xml = try EntitlementsCanonicalSerializer().blob(e)
            let xmlClaims = try EntitlementsPlistParser.parse(xml.payload)
            XCTAssertTrue(xmlClaims.hasSameSerializedClaims(as: e))
            let der = try DEREntitlementsSerializer().blob(e)
            let derClaims = try DEREntitlementsDecoder().decode(blob: der.bytes)
            XCTAssertTrue(derClaims.hasSameSerializedClaims(as: e))
            XCTAssertTrue(xmlClaims.hasSameSerializedClaims(as: derClaims))
        }
    }

    func testNestedDictionariesAndArraysRoundTrip() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "top": .dictionary([
                "array": .array([.string("a\rb"), .boolean(true), .integer(42), .data(Data([0, 255]))]),
                "nested": .dictionary([
                    "inner": .string("inner\tvalue"),
                    "deeper": .dictionary(["leaf": .integer(-129)]),
                ]),
                "emptyArray": .array([]),
                "emptyDict": .dictionary([:]),
            ]),
            "simple": .boolean(false),
        ])
        let xmlBlob = try EntitlementsCanonicalSerializer().blob(entitlements)
        let xmlClaims = try EntitlementsPlistParser.parse(xmlBlob.payload)
        XCTAssertTrue(xmlClaims.hasSameSerializedClaims(as: entitlements))
        let derBlob = try DEREntitlementsSerializer().blob(entitlements)
        let derClaims = try DEREntitlementsDecoder().decode(blob: derBlob.bytes)
        XCTAssertTrue(derClaims.hasSameSerializedClaims(as: entitlements))
        XCTAssertTrue(derClaims.hasSameSerializedClaims(as: xmlClaims))
    }

    func testAllSupportedValueTypesRoundTrip() throws {
        let entitlements = try CodeSigningEntitlements(values: [
            "string": .string("hello\tnested\ré"),
            "boolTrue": .boolean(true),
            "boolFalse": .boolean(false),
            "intZero": .integer(0),
            "intPositive": .integer(128),
            "intNegative": .integer(-1),
            "intBig": .integer(300),
            "intMin": .integer(-128),
            "data": .data(Data([0x00, 0xFF, 0x10])),
            "array": .array([.string("A"), .integer(2), .boolean(true)]),
            "dict": .dictionary(["leaf": .integer(9)]),
            "unicode": .string("é — ✓ 日本語"),
        ])
        let xmlBlob = try EntitlementsCanonicalSerializer().blob(entitlements)
        XCTAssertTrue(try EntitlementsPlistParser.parse(xmlBlob.payload).hasSameSerializedClaims(as: entitlements))
        let derBlob = try DEREntitlementsSerializer().blob(entitlements)
        XCTAssertTrue(try DEREntitlementsDecoder().decode(blob: derBlob.bytes).hasSameSerializedClaims(as: entitlements))
    }

    func testDERRejectsRealAndDERAndXMLStayConsistent() throws {
        // Real has no DER type; the canonical model allows it for XML but
        // the DER path must refuse it as notRepresentable before key use.
        let real = try CodeSigningEntitlements(values: ["ratio": .real(1.5)])
        let xmlBlob = try EntitlementsCanonicalSerializer().blob(real)
        XCTAssertNoThrow(try EntitlementsPlistParser.parse(xmlBlob.payload))
        XCTAssertThrowsError(try DEREntitlementsSerializer().blob(real)) { error in
            XCTAssertEqual(error as? EntitlementsError, .notRepresentable)
        }
        // SigningMetadataPreparation also refuses.
        let metadata = MachOSigningMetadata(entitlements: real, emitDEREntitlements: true)
        XCTAssertThrowsError(try SigningMetadataPreparation.prepare(metadata,
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256), messageDigest: digest)) { error in
            XCTAssertEqual((error as? SigningMetadataError), .entitlements(.notRepresentable))
        }
    }

    // MARK: - Finding 2: Safe DER decoding — bounds before allocation

    func testFramedBlobLengthValidationBeforeAllocation() throws {
        // Empty and short blobs are framing, not payload length.
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: Data())) { XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming) }
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: Data(repeating: 0, count: 7))) { XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming) }
        // Precedence: any declared total length above the supported maximum is
        // payloadTooLarge, even when only the eight-byte header is available.
        let oversizedDeclared = Data([0xFA, 0xDE, 0x71, 0x72, 0x00, 0x10, 0x00, 0x09])
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: oversizedDeclared)) {
            XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge)
        }
        let hugeDeclared = Data([0xFA, 0xDE, 0x71, 0x72, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: hugeDeclared)) { XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge) }
        // An ordinary, in-range declared/actual mismatch is framing.
        let valid = try DEREntitlementsSerializer().blob(try CodeSigningEntitlements(values: ["k": .boolean(true)]))
        var truncatedDeclared = valid.bytes
        truncatedDeclared[7] += 1 // increase declared by 1, now bytes.count != declared
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: truncatedDeclared)) { XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming) }
        // Wrong magic is invalidDERMagic, not generic framing.
        var wrongMagic = valid.bytes
        wrongMagic[0] ^= 0xFF
        XCTAssertThrowsError(try DEREntitlementsBlob(existingBlob: wrongMagic)) { XCTAssertEqual($0 as? EntitlementsError, .invalidDERMagic) }
        // Oversized framed blob (> maxFramedLength) is payloadTooLarge before any copy.
        let max = DEREntitlementsBlob.maximumFramedLength
        let oversized = Data(repeating: 0, count: max + 1)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(blob: oversized)) { XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge) }
    }

    func testPayloadBoundsBeforeAllocation() throws {
        // Payload count > 1MiB is rejected before reader allocation.
        let oversizedPayload = Data(repeating: 0x31, count: DEREntitlementsBlob.maximumPayloadLength + 1)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(oversizedPayload)) { XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge) }
        // The decoder also refuses an empty payload without allocating value structures.
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data())) { XCTAssertEqual($0 as? EntitlementsError, .emptyPayload) }
    }

    func testMalformedHeadersAreRefused() throws {
        // Indefinite length
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x80, 0x00, 0x00]))) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
        // Non-minimal length (short form should be used)
        for bytes in [[UInt8]([0x31, 0x81, 0x00]), [UInt8]([0x31, 0x82, 0x00, 0x02, 0x30, 0x00])] {
            XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data(bytes))) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
        }
        // Leading zero in long form
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x82, 0x00, 0x05, 0x30, 0x00]))) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
        // Truncated element (declared past buffer)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x05, 0x30, 0x03]))) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
        // Trailing data after outer SET
        let valid = try DEREntitlementsSerializer().serialize(try CodeSigningEntitlements(values: ["k": .string("v")]))
        var trailing = valid
        trailing.append(0x00)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(trailing)) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
        // Incorrect declared length inside (truncated value)
        let payload = Data([0x31, 0x05, 0x30, 0x03, 0x0C, 0x01, 0x41]) // claims 5 bytes, only 4 present
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(payload)) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
    }

    func testIntegerOverflowAndTruncation() throws {
        // Length overflow (byteCount > 4, or declared length that would overflow Int)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            let e = error as? EntitlementsError
            XCTAssertTrue(e == .malformedDEREncoding || e == .resourceLimitExceeded)
        }
        // Oversized declared payload (0x01 00 00 01 = 16 MiB) is resourceLimitExceeded
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x84, 0x01, 0x00, 0x00, 0x01]))) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
        // Integer overflow in header declared length: 0xFF FF FF FF is 4 GiB, past maxFramedLength
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x84, 0xFF, 0xFF, 0xFF, 0xFF] + Array(repeating: 0, count: 10)))) { error in
            XCTAssertTrue(error is EntitlementsError)
        }
    }

    // MARK: - Finding 3: Node budget — one policy

    func testNodeBudgetExactLimitAndOverLimit() throws {
        let limits = ProvisioningProfileParsingLimits(maximumNestingDepth: 5, maximumValueNodeCount: 10,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 10)
        let decoder = DEREntitlementsDecoder(limits: limits)

        // Exact limit: 10 nodes — outer array (1) + 9 leaves.
        let atLimit = try CodeSigningEntitlements(values: ["k": .array(Array(repeating: .boolean(true), count: 9))], limits: limits)
        XCTAssertEqual(atLimit.count, 1)
        let derAtLimit = try DEREntitlementsSerializer(limits: limits).serialize(atLimit)
        XCTAssertNoThrow(try decoder.decode(derAtLimit))
        let xmlAtLimit = try EntitlementsCanonicalSerializer().serialize(atLimit)
        XCTAssertNoThrow(try EntitlementsPlistParser.parse(xmlAtLimit, limits: limits))
        XCTAssertNoThrow(try CodeSigningEntitlements(values: ["k": .array(Array(repeating: .boolean(true), count: 9))], limits: limits))

        // Over limit by one leaf (11 nodes: outer array + 10 leaves = 11 > 10)
        let overByOne = ProvisioningProfileValue.array(Array(repeating: .boolean(true), count: 10))
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": overByOne], limits: limits)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
        // Also via DER raw construction (bypassing model) should be rejected by decoder
        // Build a manual DER payload with 10 leaves to test decoder's own counting.
        // We use the serializer with higher limits then decode with tighter limits.
        let higherLimits = ProvisioningProfileParsingLimits(maximumNestingDepth: 10, maximumValueNodeCount: 1000,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 100)
        let big = try CodeSigningEntitlements(values: ["k": overByOne], limits: higherLimits)
        let bigDER = try DEREntitlementsSerializer(limits: higherLimits).serialize(big)
        XCTAssertThrowsError(try decoder.decode(bigDER)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
    }

    func testCollectionCountExactAndOverLimit() throws {
        let limits = ProvisioningProfileParsingLimits(maximumNestingDepth: 10, maximumValueNodeCount: 100,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 4)
        let decoder = DEREntitlementsDecoder(limits: limits)

        // Exactly 4 entries — at limit
        let atLimit = try CodeSigningEntitlements(values: ["k": .dictionary(["a": .integer(1), "b": .integer(2), "c": .integer(3), "d": .integer(4)])], limits: limits)
        XCTAssertNoThrow(try DEREntitlementsSerializer(limits: limits).serialize(atLimit))
        XCTAssertNoThrow(try EntitlementsCanonicalSerializer(limits: CanonicalPropertyListLimits(
            maximumNestingDepth: 10, maximumNodeCount: 100, maximumStringByteCount: 100, maximumDocumentByteCount: 1024*1024)).serialize(atLimit))

        // 5 entries — over limit on construction
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": .dictionary(["a": .integer(1), "b": .integer(2), "c": .integer(3), "d": .integer(4), "e": .integer(5)])], limits: limits)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }

        // DER decoder must also refuse a manually built payload with 5 pairs at outer level
        let higher = ProvisioningProfileParsingLimits(maximumNestingDepth: 10, maximumValueNodeCount: 100,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 10)
        let big = try CodeSigningEntitlements(values: ["k": .dictionary(["a": .integer(1), "b": .integer(2), "c": .integer(3), "d": .integer(4), "e": .integer(5)])], limits: higher)
        let bigDER = try DEREntitlementsSerializer(limits: higher).serialize(big)
        XCTAssertThrowsError(try decoder.decode(bigDER)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }

        // Array collection count
        let arrAtLimit = try CodeSigningEntitlements(values: ["k": .array([.integer(1), .integer(2), .integer(3), .integer(4)])], limits: limits)
        XCTAssertNoThrow(try DEREntitlementsSerializer(limits: limits).serialize(arrAtLimit))
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": .array([.integer(1), .integer(2), .integer(3), .integer(4), .integer(5)])], limits: limits)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
    }

    func testNestingDepthExactAndOverLimit() throws {
        let limits = ProvisioningProfileParsingLimits(maximumNestingDepth: 2, maximumValueNodeCount: 100,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 10)
        let decoder = DEREntitlementsDecoder(limits: limits)
        // Depth 2 allowed: k -> dict(a -> array(true))
        let allowed = try CodeSigningEntitlements(values: ["k": .dictionary(["a": .array([.boolean(true)])])], limits: limits)
        XCTAssertNoThrow(try decoder.decode(DEREntitlementsSerializer(limits: limits).serialize(allowed)))

        // Depth 3 not allowed: k -> array(array(array(true)))
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": .array([.array([.array([.boolean(true)])])])], limits: limits)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
        let higher = ProvisioningProfileParsingLimits(maximumNestingDepth: 10, maximumValueNodeCount: 100,
            maximumStringByteCount: 100, maximumDataByteCount: 100, maximumCollectionCount: 10)
        let deep = try CodeSigningEntitlements(values: ["k": .array([.array([.array([.boolean(true)])])])], limits: higher)
        let deepDER = try DEREntitlementsSerializer(limits: higher).serialize(deep)
        XCTAssertThrowsError(try decoder.decode(deepDER)) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
    }

    func testNestedModelValidationPreservesSuppliedLimits() throws {
        let value: ProvisioningProfileValue = .array([
            .dictionary(["d": .array([.string("ok")])])
        ])
        let accepted = ProvisioningProfileParsingLimits(
            maximumNestingDepth: 4, maximumValueNodeCount: 4,
            maximumStringByteCount: 2, maximumDataByteCount: 8, maximumCollectionCount: 4
        )
        XCTAssertNoThrow(try CodeSigningEntitlements(values: ["k": value], limits: accepted))

        let tighterStringBound = ProvisioningProfileParsingLimits(
            maximumNestingDepth: 4, maximumValueNodeCount: 4,
            maximumStringByteCount: 1, maximumDataByteCount: 8, maximumCollectionCount: 4
        )
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": value], limits: tighterStringBound)) {
            XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded)
        }
    }

    func testNodeLimitExcludesDictionaryKeysAndImplicitRootAcrossDecoders() throws {
        let parsingLimits = ProvisioningProfileParsingLimits(
            maximumNestingDepth: 4, maximumValueNodeCount: 3,
            maximumStringByteCount: 32, maximumDataByteCount: 32, maximumCollectionCount: 4
        )
        let values: [String: ProvisioningProfileValue] = [
            "first-key": .boolean(true),
            "second-key": .integer(2),
            "third-key": .string("v"),
        ]
        // Three scalar values exactly meet the limit. Counting either three
        // dictionary keys or the implicit root dictionary would exceed it.
        let model = try CodeSigningEntitlements(values: values, limits: parsingLimits)
        XCTAssertEqual(try ProvisioningProfileValue.decodeEntitlementDictionary(
            ["first-key": true, "second-key": 2, "third-key": "v"], limits: parsingLimits
        ).count, 3)
        let der = try DEREntitlementsSerializer(limits: parsingLimits).serialize(model)
        XCTAssertEqual(try DEREntitlementsDecoder(limits: parsingLimits).decode(der), model)
        let xmlLimits = CanonicalPropertyListLimits(
            maximumNestingDepth: 4, maximumNodeCount: 3,
            maximumStringByteCount: 32, maximumDocumentByteCount: 1024
        )
        let xml = try EntitlementsCanonicalSerializer(limits: xmlLimits).serialize(model)
        XCTAssertEqual(try EntitlementsPlistParser.parse(xml, limits: parsingLimits), model)
    }

    func testCanonicalXMLOutputLimitIsEnforcedIncrementally() throws {
        let entitlements = try CodeSigningEntitlements(values: ["key": .string("value")])
        let full = try EntitlementsCanonicalSerializer().serialize(entitlements)
        let exactLimit = CanonicalPropertyListLimits(
            maximumNestingDepth: 32, maximumNodeCount: 50_000,
            maximumStringByteCount: 16 * 1_024, maximumDocumentByteCount: full.count
        )
        XCTAssertNoThrow(try EntitlementsCanonicalSerializer(limits: exactLimit).serialize(entitlements))
        let tooSmall = CanonicalPropertyListLimits(
            maximumNestingDepth: 32, maximumNodeCount: 50_000,
            maximumStringByteCount: 16 * 1_024, maximumDocumentByteCount: full.count - 1
        )
        XCTAssertThrowsError(try EntitlementsCanonicalSerializer(limits: tooSmall).serialize(entitlements)) {
            XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge)
        }

        let dataClaims = try CodeSigningEntitlements(values: ["payload": .data(Data(repeating: 0xAB, count: 114))])
        let dataXML = try EntitlementsCanonicalSerializer().serialize(dataClaims)
        let lines = String(decoding: dataXML, as: UTF8.self).components(separatedBy: "\n")
        let dataStart = try XCTUnwrap(lines.firstIndex(of: "\t<data>"))
        let dataEnd = try XCTUnwrap(lines[(dataStart + 1)...].firstIndex(of: "\t</data>"))
        let base64Lines = Array(lines[(dataStart + 1)..<dataEnd])
        XCTAssertEqual(base64Lines.map { $0.utf8.count - 2 }, [76, 76])
        XCTAssertEqual(try EntitlementsPlistParser.parse(dataXML), dataClaims)

        let oversizedData = try CodeSigningEntitlements(values: ["payload": .data(Data(repeating: 0xAB, count: 1_025))])
        let smallDocument = CanonicalPropertyListLimits(
            maximumNestingDepth: 32, maximumNodeCount: 50_000,
            maximumStringByteCount: 16 * 1_024, maximumDocumentByteCount: 1_024
        )
        XCTAssertThrowsError(try EntitlementsCanonicalSerializer(limits: smallDocument).serialize(oversizedData)) {
            XCTAssertEqual($0 as? EntitlementsError, .payloadTooLarge)
        }
    }

    func testDefaultNodeBoundaryIsSharedBetweenXMLAndDER() throws {
        // 50k node limit is shared: one outer array + 5 inner arrays + 49994 leaves = 50000
        let leaf = ProvisioningProfileValue.boolean(true)
        var groups = (0..<4).map { _ in ProvisioningProfileValue.array(Array(repeating: leaf, count: 9_999)) }
        groups.append(.array(Array(repeating: leaf, count: 9_998)))
        let atLimit = try CodeSigningEntitlements(values: ["k": .array(groups)])
        let der = try DEREntitlementsSerializer().serialize(atLimit)
        XCTAssertEqual(try DEREntitlementsDecoder().decode(der), atLimit)
        let xml = try EntitlementsCanonicalSerializer().serialize(atLimit)
        XCTAssertEqual(try EntitlementsPlistParser.parse(xml), atLimit)
        // One more leaf pushes over 50k
        groups[4] = .array(Array(repeating: leaf, count: 9_999))
        XCTAssertThrowsError(try CodeSigningEntitlements(values: ["k": .array(groups)])) { XCTAssertEqual($0 as? EntitlementsError, .resourceLimitExceeded) }
    }

    // MARK: - Finding 4: Diagnostics — typed and redacted

    func testDiagnosticsAreTypedAndRedacted() throws {
        // Missing DER blob
        let missing = MachOSigningMetadata(emitDEREntitlements: true)
        XCTAssertThrowsError(try SigningMetadataPreparation.prepare(missing,
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256), messageDigest: digest)) { error in
            XCTAssertEqual((error as? SigningMetadataError), .entitlements(.missingDEREntitlements))
            // Diagnostics must not contain value bytes
            XCTAssertFalse("\(error)".contains("secret"))
        }
        // Unsupported CodeDirectory version for DER
        let claims = try CodeSigningEntitlements(values: ["k": .boolean(true)])
        let badVersion = try MachOSigningRequest(artifact: MachOSigningFixtures.unsignedMachO, identityID: SigningIdentityIdentifier(),
            codeDirectory: CodeDirectoryConstructionRequest(version: .v20200, flags: [], identifier: try CodeDirectoryIdentifier(rawValue: "com.example.single"),
                teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256), pageSize: .exponent(12), codeLimit: 4144, specialSlots: []),
            algorithm: .rsaPKCS1SHA256Digest, existingSignaturePolicy: .rejectExistingSignature,
            policy: .singleImageCryptographicExperiment, metadata: MachOSigningMetadata(entitlements: claims, emitDEREntitlements: true))
        XCTAssertThrowsError(try badVersion.validate()) { error in
            XCTAssertEqual(error as? MachOSigningError, .entitlements(.unsupportedDERCodeDirectoryVersion))
        }
        // Invalid DER magic via blob
        let validBlob = try DEREntitlementsSerializer().blob(claims)
        var wrongMagic = validBlob.bytes
        wrongMagic[0] ^= 1
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(blob: wrongMagic)) { XCTAssertEqual($0 as? EntitlementsError, .invalidDERMagic) }
        // Invalid framing (declared != actual)
        var wrongLength = validBlob.bytes
        wrongLength[4] ^= 1
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(blob: wrongLength)) { XCTAssertEqual($0 as? EntitlementsError, .invalidBlobFraming) }
        // Unsupported value (REAL tag 0x09 outside grammar)
        let unsupportedBytes = Data([0x31, 0x0B, 0x30, 0x09, 0x0C, 0x01, 0x6B, 0x09, 0x01, 0x00]) // SET { SEQ { UTF8 "k", REAL } }
        // Real tag 0x09 is not in grammar, so decoder reports unsupportedValueType
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(unsupportedBytes)) { XCTAssertEqual($0 as? EntitlementsError, .unsupportedValueType) }
        // Malformed DER (truncated)
        XCTAssertThrowsError(try DEREntitlementsDecoder().decode(Data([0x31, 0x03, 0x30, 0x01]))) { XCTAssertEqual($0 as? EntitlementsError, .malformedDEREncoding) }
    }

    func testDERVerificationDiagnosticsForEachFailureMode() throws {
        let store = try NestedSigningTestIdentityStore()
        let engine = SignMachOUseCase(identities: store, digest: digest, verifier: NestedSigningTestVerifier())
        let claims = try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)])
        let request = try MachOSigningRequest(artifact: MachOSigningFixtures.unsignedMachO, identityID: store.id,
            codeDirectory: CodeDirectoryConstructionRequest(version: .v20400, flags: [], identifier: try CodeDirectoryIdentifier(rawValue: "com.example.single"),
                teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256), pageSize: .exponent(12), codeLimit: 4144, specialSlots: []),
            algorithm: .rsaPKCS1SHA256Digest, existingSignaturePolicy: .rejectExistingSignature,
            policy: .singleImageCryptographicExperiment, metadata: MachOSigningMetadata(entitlements: claims, emitDEREntitlements: true))
        let result = try engine.sign(request)
        let slice = try XCTUnwrap(try ReadOnlyMachOParser().parse(result.artifact).slices.first?.embeddedSignature)
        let derIndex = try XCTUnwrap(slice.superBlob.entries.firstIndex { $0.slot == .derEntitlements })
        let derEntry = slice.superBlob.entries[derIndex]
        let cdEntry = try XCTUnwrap(slice.superBlob.entries.first { $0.slot == .codeDirectory })

        // Missing DER entitlements: flip DER slot type to something else
        var missing = result.artifact
        // Change slot number 7 to 99 (0x63) at index table
        let superOffset = slice.superBlob.fileRange.lowerBound
        let indexPos = superOffset + 12 + derIndex * 8
        missing[indexPos + 3] = 0x63
        XCTAssertThrowsError(try engine.verify(artifact: missing, request: request, certificate: store.certificate)) { XCTAssertEqual($0 as? MachOSigningError, .entitlements(.missingDEREntitlements)) }

        // Invalid DER magic: tamper blob header magic
        var badMagic = result.artifact
        badMagic[derEntry.fileRange.lowerBound] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: badMagic, request: request, certificate: store.certificate)) { error in
            let e = error as? MachOSigningError
            XCTAssertTrue(e == .entitlements(.invalidDERMagic) || e == .entitlements(.invalidBlobFraming) || e == .postSignVerification)
        }

        // Slot digest mismatch: flip a byte in the CodeDirectory's slot 7 hash
        var badDigest = result.artifact
        let cdDir = try XCTUnwrap(cdEntry.codeDirectory)
        let slot = try XCTUnwrap(cdDir.specialSlots.first { $0.kind == .derEntitlements })
        badDigest[slot.hashRange.lowerBound] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: badDigest, request: request, certificate: store.certificate)) { XCTAssertEqual($0 as? MachOSigningError, .entitlements(.derEntitlementsDigestMismatch)) }

        // DER mismatch (embedded bytes != expected)
        var mismatch = result.artifact
        mismatch[derEntry.fileRange.upperBound - 1] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: mismatch, request: request, certificate: store.certificate)) { XCTAssertEqual($0 as? MachOSigningError, .entitlements(.derEntitlementsMismatch)) }

        // Malformed DER (change tag to truncated)
        var malformed = result.artifact
        malformed[derEntry.fileRange.lowerBound + 8] = 0x31 // outer SET -> should be SET, but change inner to bad
        malformed[derEntry.fileRange.lowerBound + 9] = 0xFF
        XCTAssertThrowsError(try engine.verify(artifact: malformed, request: request, certificate: store.certificate)) { error in
            let e = error as? MachOSigningError
            XCTAssertTrue(e == .entitlements(.malformedDEREncoding) || e == .entitlements(.invalidBlobFraming) || e == .postSignVerification)
        }

        // Unsupported value type (REAL)
        var unsupported = result.artifact
        // Locate a string value and replace its tag 0x0C with 0x09 (REAL)
        for off in derEntry.fileRange.lowerBound..<derEntry.fileRange.upperBound {
            if unsupported[off] == 0x0C {
                unsupported[off] = 0x09
                break
            }
        }
        XCTAssertThrowsError(try engine.verify(artifact: unsupported, request: request, certificate: store.certificate)) { error in
            let e = error as? MachOSigningError
            XCTAssertTrue(e == .entitlements(.unsupportedValueType) || e == .entitlements(.malformedDEREncoding))
        }
    }

    // MARK: - Regression protection: DER remains disabled in pipelines

    func testPipelineDERRefusalRemains() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let pipeline = SignApplicationPipeline(identities: identities, digest: digest,
            signatureVerifier: NestedSigningTestVerifier(), profileValidation: fakeProfileValidation(identities: identities),
            writer: ZipArchiveWriter())
        let request = SignApplicationRequest(sourceURL: URL(fileURLWithPath: "/tmp/notfound.ipa"),
            profile: Data(), identityID: identities.id, entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: URL(fileURLWithPath: "/tmp/out.ipa"),
            options: SignApplicationOptions(emitDEREntitlements: true))
        let result = try await pipeline.sign(request)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .mainExecutable)
        XCTAssertTrue(result.failure?.detail.contains("DER entitlements are not embedded") ?? false)
    }

    func testCoordinatorDERRefusalRemains() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = URL(fileURLWithPath: "/tmp/not-present.ipa")
        let output = URL(fileURLWithPath: "/tmp/must-not-exist.ipa")
        let request = SigningEngineRequest(sourceURL: source, profile: Data(),
            identityID: identities.id, entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output, options: SignApplicationOptions(emitDEREntitlements: true))
        let engine = SigningEngineCoordinator(pipeline: SignApplicationPipeline(identities: identities, digest: digest,
            signatureVerifier: NestedSigningTestVerifier(),
            profileValidation: fakeProfileValidation(identities: identities), writer: ZipArchiveWriter()),
            validator: SigningEngineBundleValidator(),
            workingCopyVerifier: SigningEngineVerifier(identities: identities, digest: digest, cryptographicVerifier: NestedSigningTestVerifier()),
            containerVerifier: VerifySignedApplication(digest: digest), digest: digest)
        let result = try await engine.sign(request)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .validating)
        XCTAssertEqual(result.failure?.category, .unsupportedInput)
        XCTAssertNil(result.workingCopy)
    }

    // MARK: - Finding 5: Cryptographic regression — real key where available

    func testFixedVectorIdentityVerifiesDERBindingAndRejectsTampering() throws {
        // This uses NestedSigningTestIdentityStore and
        // NestedSigningTestVerifier, so it checks signing orchestration and
        // DER/slot/digest binding only; it does not prove RSA verification.
        // Real Security.framework RSA coverage lives in MachOSigningAppleTests.
        let store = try NestedSigningTestIdentityStore()
        let engine = SignMachOUseCase(identities: store, digest: digest, verifier: NestedSigningTestVerifier())
        let claims = try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true), "aps-environment": .string("development")])
        let request = try MachOSigningRequest(artifact: MachOSigningFixtures.unsignedMachO, identityID: store.id,
            codeDirectory: CodeDirectoryConstructionRequest(version: .v20400, flags: [], identifier: try CodeDirectoryIdentifier(rawValue: "com.example.single"),
                teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256), pageSize: .exponent(12), codeLimit: 4144, specialSlots: []),
            algorithm: .rsaPKCS1SHA256Digest, existingSignaturePolicy: .rejectExistingSignature,
            policy: .singleImageCryptographicExperiment, metadata: MachOSigningMetadata(entitlements: claims, emitDEREntitlements: true))
        let result = try engine.sign(request)
        XCTAssertEqual(store.signCalls, 1)
        // Verification via the same certificate succeeds.
        XCTAssertNoThrow(try engine.verify(artifact: result.artifact, request: request, certificate: store.certificate))
        XCTAssertEqual(store.signCalls, 1) // verify does not sign
        // Tampering the DER blob is rejected as derEntitlementsMismatch or malformed.
        let slice = try XCTUnwrap(try ReadOnlyMachOParser().parse(result.artifact).slices.first?.embeddedSignature)
        guard let derEntry = slice.superBlob.entries.first(where: { $0.slot == .derEntitlements }) else { return XCTFail("DER entry missing") }
        var tampered = result.artifact
        tampered[derEntry.fileRange.upperBound - 1] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: tampered, request: request, certificate: store.certificate))
        // Tampering code page also fails (postSignVerification, not a DER-specific error, but still a failure).
        var tamperedCode = result.artifact
        tamperedCode[512] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: tamperedCode, request: request, certificate: store.certificate))
        // Wrong certificate fails.
        let other = try NestedSigningTestIdentityStore()
        other.certificate = try Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: CertificateFixtures.validDER), derData: CertificateFixtures.validDER)
        XCTAssertThrowsError(try engine.verify(artifact: result.artifact, request: request, certificate: other.certificate))
    }

    // MARK: - Helpers

    private func fakeProfileValidation(identities: NestedSigningTestIdentityStore) -> ValidateProvisioningProfileUseCase {
        ValidateProvisioningProfileUseCase(
            profileVerification: ProvisioningProfileVerificationUseCase(
                cmsVerifier: ProvisioningProfileCMSVerifier(certificateParser: AppleCertificateParser(), signatureVerifier: RecordingCMSSignatureVerifier()),
                inspection: ProvisioningProfileInspectionUseCase(payloadDecoder: UnusedPayloadDecoder(),
                    parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                    clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))),
                identityStore: TestIdentityStore()),
            configurationValidation: ValidateProvisioningConfigurationUseCase(
                policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))),
                identityStore: TestIdentityStore()))
    }
}

// MARK: - Support doubles reused from other suites (minimal)

private struct UnusedPayloadDecoder: ProvisioningProfilePayloadDecoding {
    func decode(_ payload: ProvisioningProfilePayload) throws -> ProvisioningProfileParserResult { throw ZynSignError.provisioningProfile(.invalidStructure) }
}
