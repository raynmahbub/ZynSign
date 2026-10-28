import Foundation
import XCTest
@testable import ZynSign

/// Tests for the DER entitlement decoder — the half the encoder never had.
///
/// Every round-trip below goes through the production serializer, so a change to
/// either side breaks here rather than in the field. Every refusal below is a
/// payload a real signature should never carry, and the decoder must say so
/// rather than returning a partial set: a signature's claims are read completely
/// or not at all.
final class DEREntitlementsDecodingTests: XCTestCase {

    private let decoder = DEREntitlementsDecoder()

    /// Builds one DER element with a minimal length encoding.
    private func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    private func utf8(_ text: String) -> [UInt8] {
        der(0x0C, Array(text.utf8))
    }

    private func pair(_ key: String, _ value: [UInt8]) -> [UInt8] {
        der(0x30, utf8(key) + value)
    }

    private func set(_ pairs: [[UInt8]]) -> Data {
        Data(der(0x31, pairs.flatMap { $0 }))
    }

    private func decode(_ data: Data) throws -> CodeSigningEntitlements {
        try decoder.decode(data)
    }

    // MARK: - Round trips through the production encoder

    /// An empty claim set is representable: the DER SET is empty, and the
    /// decoder returns an empty set rather than "unknown".
    func testAnEmptySetRoundTrips() throws {
        let original = try CodeSigningEntitlements(values: [:])
        let payload = try DEREntitlementsSerializer().serialize(original)
        XCTAssertEqual(payload, Data([0x31, 0x00]))
        let decoded = try decode(payload)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(decoded, original)
    }

    /// Every value type the encoder can write comes back with its type intact —
    /// strings, booleans, integers (including the sign boundaries), data, arrays
    /// and nested dictionaries.
    func testEveryValueTypeRoundTrips() throws {
        let original = try CodeSigningEntitlements(values: [
            "aps-environment": .string("development"),
            "get-task-allow": .boolean(true),
            "run-unsigned-code": .boolean(false),
            "zero": .integer(0),
            "one": .integer(1),
            "max-positive": .integer(127),
            "over-positive": .integer(128),
            "min-negative": .integer(-128),
            "negative": .integer(-1),
            "big": .integer(300),
            "payload": .data(Data([0x00, 0xFF, 0x10])),
            "com.apple.developer.team-identifier": .array([.string("A"), .integer(2), .boolean(true)]),
            "nested": .dictionary([
                "inner": .string("value"),
                "deeper": .dictionary(["leaf": .integer(9)]),
            ]),
            "empty-array": .array([]),
            "empty-dictionary": .dictionary([:]),
            "unicode": .string("é — ✓ 日本語"),
        ])
        let payload = try DEREntitlementsSerializer().serialize(original)
        let decoded = try decode(payload)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.keys, original.keys, "the encoder's canonical order is preserved")
    }

    /// A value longer than 127 bytes uses the long-form length, which the reader
    /// parses rather than refusing.
    func testALongValueRoundTrips() throws {
        let long = String(repeating: "z", count: 300)
        let original = try CodeSigningEntitlements(values: ["long": .string(long)])
        let decoded = try decode(try DEREntitlementsSerializer().serialize(original))
        XCTAssertEqual(decoded["long"], .string(long))
    }

    /// A `real` has no DER type; the encoder writes it as text and the decoder
    /// reads text. The asymmetry is recorded here so it cannot change silently.
    func testARealIsEncodedAsTextAndComesBackAsText() throws {
        let original = try CodeSigningEntitlements(values: ["ratio": .real(1.5)])
        let decoded = try decode(try DEREntitlementsSerializer().serialize(original))
        XCTAssertEqual(decoded["ratio"], .string("1.5"))
    }

    /// The framed blob form decodes too, and framing is still policed.
    func testTheFramedBlobDecodesAndChecksItsMagic() throws {
        let original = try CodeSigningEntitlements(values: ["k": .string("v")])
        let blob = try DEREntitlementsSerializer().blob(original)
        XCTAssertEqual(try decoder.decode(blob: blob.bytes), original)

        var wrongMagic = blob.bytes
        wrongMagic[0] = blob.bytes[0] &+ 1
        XCTAssertThrowsError(try decoder.decode(blob: wrongMagic)) { error in
            XCTAssertEqual(error as? EntitlementsError, .invalidBlobFraming)
        }
    }

    // MARK: - Refusals

    func testAnEmptyPayloadIsRefused() {
        XCTAssertThrowsError(try decode(Data())) { error in
            XCTAssertEqual(error as? EntitlementsError, .emptyPayload)
        }
    }

    /// The root has to be a SET. A SEQUENCE with the right contents is still
    /// the wrong document.
    func testTheRootMustBeASet() {
        let bytes = Data(der(0x30, pair("k", utf8("v"))))
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    /// A tag outside the grammar is reported as an unsupported type, not coerced
    /// into a string.
    func testAnUnknownValueTagIsUnsupported() {
        for tag: UInt8 in [0x09, 0x17, 0x18, 0x0A] {
            let bytes = set([pair("k", der(tag, [0x01, 0x02]))])
            XCTAssertThrowsError(try decode(bytes), "tag 0x\(String(tag, radix: 16))") { error in
                XCTAssertEqual(error as? EntitlementsError, .unsupportedValueType)
            }
        }
    }

    func testADuplicateKeyIsRefused() {
        let bytes = set([pair("k", utf8("one")), pair("k", utf8("two"))])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    func testATruncatedElementIsRefused() {
        let bytes = Data([0x31, 0x05, 0x30, 0x03])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    func testTrailingBytesAfterTheSetAreRefused() {
        var bytes = set([pair("k", utf8("v"))])
        bytes.append(0x00)
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    /// DER forbids the indefinite form; so does this reader.
    func testAnIndefiniteLengthIsRefused() {
        let bytes = Data([0x31, 0x80, 0x00, 0x00])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    /// A length that fits in the short form must use it, and a long form may not
    /// begin with a zero byte.
    func testNonMinimalLengthsAreRefused() {
        for bytes: [UInt8] in [
            [0x31, 0x81, 0x00],
            [0x31, 0x82, 0x00, 0x02, 0x30, 0x00],
        ] {
            XCTAssertThrowsError(try decode(Data(bytes))) { error in
                XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
            }
        }
    }

    /// A boolean is one byte, 0x00 or 0xFF. Anything else is not a boolean this
    /// grammar wrote.
    func testANonCanonicalBooleanIsRefused() {
        for content: [UInt8] in [[0x01], [0x01, 0x00], []] {
            let bytes = set([pair("k", der(0x01, content))])
            XCTAssertThrowsError(try decode(bytes)) { error in
                XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
            }
        }
    }

    /// Integers are minimally encoded and fit in eight bytes.
    func testNonMinimalAndOversizedIntegersAreRefused() {
        for content: [UInt8] in [
            [0x00, 0x00],              // leading zero then a positive byte
            [0xFF, 0xFF],              // redundant negative sign
            [0xFF, 0x80],              // leading 0xFF then a negative byte
            [],                        // empty
            Array(repeating: 0x01, count: 9), // too wide for Int64
        ] {
            let bytes = set([pair("k", der(0x02, content))])
            XCTAssertThrowsError(try decode(bytes), "content \(content)") { error in
                XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
            }
        }
    }

    /// A pair is exactly a key and one value; a key alone is not a claim.
    func testAPairWithoutAValueIsRefused() {
        let bytes = set([der(0x30, utf8("k"))])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    /// A key that is not a UTF8String is refused before it can become a claim.
    func testANonStringKeyIsRefused() {
        let bytes = set([der(0x30, der(0x04, [0x01]) + utf8("v"))])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .malformedDEREncoding)
        }
    }

    /// A tree deeper than the configured bound is refused rather than walked.
    func testADeeplyNestedTreeHitsTheDepthBound() {
        var value = utf8("leaf")
        for _ in 0..<40 {
            value = der(0x31, der(0x30, utf8("k") + value))
        }
        let bytes = set([pair("root", value)])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .resourceLimitExceeded)
        }
    }

    /// A payload larger than the blob bound is refused before it is read.
    func testAnOversizedElementIsRefused() {
        let bytes = Data([0x31, 0x84, 0x01, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try decode(bytes)) { error in
            XCTAssertEqual(error as? EntitlementsError, .resourceLimitExceeded)
        }
    }

    /// Decoding never claims authority: the decoded set is data, and the record
    /// that says so lives beside the type.
    func testDecodingMakesNoAuthorizationClaim() throws {
        let decoded = try decode(set([pair("get-task-allow", der(0x01, [0xFF]))]))
        XCTAssertEqual(decoded["get-task-allow"], .boolean(true))
        XCTAssertEqual(decoded.count, 1)
    }
}
