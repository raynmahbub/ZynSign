import Foundation
import XCTest
@testable import ZynSign

/// Requirements model, blob-set framing, round-trip, determinism, malformed
/// input handling, and SuperBlob integration.
///
/// The byte and digest expectations were computed independently on a host
/// over the documented framing and are recorded as literals.
final class CodeSignatureRequirementsTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    private func hex(_ text: String) -> Data {
        let characters = Array(text.filter { !$0.isWhitespace })
        var bytes = Data()
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard offset + 1 < characters.count,
                  let byte = UInt8(String(characters[offset...offset + 1]), radix: 16) else {
                XCTFail("Invalid test vector")
                return Data()
            }
            bytes.append(byte)
        }
        return bytes
    }

    private func designatedSet() throws -> RequirementsSet {
        let requirement = try FramedRequirement(
            expressionBytes: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        )
        return try RequirementsSet(entries: [
            RequirementsSetEntry(kind: .designated, requirement: requirement)
        ])
    }

    // MARK: - Kinds

    func testDocumentedKindsCarryTheirEstablishedValues() {
        XCTAssertEqual(RequirementKind.host.rawValue, 1)
        XCTAssertEqual(RequirementKind.guest.rawValue, 2)
        XCTAssertEqual(RequirementKind.designated.rawValue, 3)
        XCTAssertEqual(RequirementKind.library.rawValue, 4)
        XCTAssertEqual(RequirementKind.plugin.rawValue, 5)
        XCTAssertEqual(RequirementKind(rawValue: 99), .other(99))
        XCTAssertEqual(RequirementKind.other(99).rawValue, 99)
    }

    // MARK: - Serialization (independently computed vectors)

    func testOneDesignatedRequirementMatchesIndependentVector() throws {
        let bytes = try designatedSet().serialized()
        XCTAssertEqual(bytes, hex("""
        fade0c01 00000024 00000001
        00000003 00000014
        fade0c00 00000010 0001020304050607
        """))
        XCTAssertEqual(try digest.digest(bytes, algorithm: .sha256).hexString,
                       "fb68f59a513f4cc2f81597abea1be016e966ca46747b9c293bf98f095ea16251")
    }

    func testEmptySetMatchesIndependentVector() throws {
        let empty = try RequirementsSet(entries: [])
        let bytes = try empty.serialized()
        XCTAssertEqual(bytes, hex("fade0c01 0000000c 00000000"))
        XCTAssertEqual(try digest.digest(bytes, algorithm: .sha256).hexString,
                       "987920904eab650e75788c054aa0b0524e6a80bfc71aa32df8d237a61743f986")
    }

    /// Regression: an empty set — the form ad-hoc signatures carry — used to
    /// trap while checking entry ranges (`1..<0`) instead of parsing.
    func testEmptySetParsesWithoutEntries() throws {
        let parsed = try RequirementsSet.parse(hex("fade0c01 0000000c 00000000"))
        XCTAssertEqual(parsed.disposition, .presentAndParsed)
        XCTAssertNotNil(parsed.set)
        XCTAssertEqual(parsed.set?.entries.count, 0)
    }

    func testSerializationIsDeterministicAndSortedByKind() throws {
        let requirement = try FramedRequirement(expressionBytes: Data([0xAA]))
        let ascending = try RequirementsSet(entries: [
            RequirementsSetEntry(kind: .host, requirement: requirement),
            RequirementsSetEntry(kind: .designated, requirement: requirement),
        ])
        let reversed = try RequirementsSet(entries: [
            RequirementsSetEntry(kind: .designated, requirement: requirement),
            RequirementsSetEntry(kind: .host, requirement: requirement),
        ])
        XCTAssertEqual(try ascending.serialized(), try reversed.serialized())
        // The index is emitted in ascending kind order: host (1) before
        // designated (3).
        let bytes = try ascending.serialized()
        XCTAssertEqual(bytes.subdata(in: 12..<16), hex("00000001"))
        XCTAssertEqual(bytes.subdata(in: 20..<24), hex("00000003"))
    }

    func testRoundTripPreservesExactBytes() throws {
        let set = try designatedSet()
        let bytes = try set.serialized()
        let parsed = try RequirementsSet.parse(bytes)
        XCTAssertEqual(parsed.disposition, .presentAndParsed)
        XCTAssertEqual(parsed.set, set)
        // The parsed set re-serializes to the identical bytes: preservation,
        // not reinterpretation.
        XCTAssertEqual(try parsed.set?.serialized(), bytes)
        // Expressions are never interpreted.
        XCTAssertEqual(parsed.expressionInterpretation, .notImplemented)
    }

    // MARK: - Dispositions

    func testUnknownKindIsReportedUnsupportedButEmbeddable() throws {
        let requirement = try FramedRequirement(expressionBytes: Data([0x01]))
        let set = try RequirementsSet(entries: [
            RequirementsSetEntry(kind: .other(99), requirement: requirement)
        ])
        let parsed = try RequirementsSet.parse(try set.serialized())
        XCTAssertEqual(parsed.disposition, .presentButUnsupported([99]))
        XCTAssertTrue(parsed.isEmbeddable)
        // No code path fabricates a generated or verified disposition.
        XCTAssertFalse(CodeSigningRequirements(disposition: .generated, set: nil).isEmbeddable)
        XCTAssertFalse(CodeSigningRequirements(disposition: .verified, set: nil).isEmbeddable)
        XCTAssertFalse(CodeSigningRequirements(disposition: .malformed, set: nil).isEmbeddable)
        XCTAssertFalse(CodeSigningRequirements.none.isEmbeddable)
        XCTAssertFalse(CodeSigningRequirements.none.requiresEmbedding)
    }

    // MARK: - Malformed framing

    func testMalformedFramingsFailWithTypedErrors() throws {
        let valid = try designatedSet().serialized()

        // Wrong set magic.
        var wrongMagic = valid
        wrongMagic[3] ^= 0x01
        XCTAssertThrowsError(try RequirementsSet.parse(wrongMagic)) {
            XCTAssertEqual($0 as? RequirementsError, .invalidMagic(expected: 0xFADE0C01, actual: 0xFADE0C00))
        }

        // Length shorter than the header.
        XCTAssertThrowsError(try RequirementsSet.parse(hex("fade0c01 00000008 00000000"))) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidLength)
        }

        // Truncated beyond declared length.
        XCTAssertThrowsError(
            try RequirementsSet.parse(valid.prefix(valid.count - 1))
        ) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidLength)
        }

        // Entry offset before the index.
        var beforeIndex = valid
        beforeIndex.replaceSubrange(16..<20, with: hex("00000004"))
        XCTAssertThrowsError(try RequirementsSet.parse(beforeIndex)) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidOffset)
        }

        // Duplicate kinds.
        let requirement = try FramedRequirement(expressionBytes: Data([0x01]))
        XCTAssertThrowsError(
            try RequirementsSet(entries: [
                RequirementsSetEntry(kind: .designated, requirement: requirement),
                RequirementsSetEntry(kind: .designated, requirement: requirement),
            ])
        ) { error in
            XCTAssertEqual(error as? RequirementsError, .duplicateEntryKind(3))
        }

        // A nested requirement blob with the wrong magic.
        var wrongNested = valid
        wrongNested.replaceSubrange(20..<24, with: hex("fade0c02"))
        XCTAssertThrowsError(try RequirementsSet.parse(wrongNested)) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidMagic(expected: 0xFADE0C00, actual: 0xFADE0C02))
        }

        // Overlapping entries.
        let small = try RequirementsSet(entries: [
            RequirementsSetEntry(kind: .host, requirement: try FramedRequirement(expressionBytes: Data(repeating: 1, count: 8))),
            RequirementsSetEntry(kind: .guest, requirement: try FramedRequirement(expressionBytes: Data(repeating: 2, count: 8))),
        ]).serialized()
        var overlapping = small
        // Point the second entry at the first entry's blob: the index is
        // interleaved (kind, offset) pairs, so the second offset at 24..<28
        // takes the first offset's value from 16..<20.
        overlapping.replaceSubrange(24..<28, with: small.subdata(in: 16..<20))
        XCTAssertThrowsError(try RequirementsSet.parse(overlapping)) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidOffset)
        }

        XCTAssertThrowsError(try RequirementsSet.parse(Data())) { error in
            XCTAssertEqual(error as? RequirementsError, .emptyInput)
        }
    }

    func testEntryCountBoundIsEnforced() throws {
        let requirement = try FramedRequirement(expressionBytes: Data([0x01]))
        let tooMany = (0...RequirementsSet.maximumEntries).map { index in
            RequirementsSetEntry(
                kind: .other(UInt32(100 + index)),
                requirement: requirement
            )
        }
        XCTAssertThrowsError(try RequirementsSet(entries: tooMany)) { error in
            XCTAssertEqual(error as? RequirementsError, .invalidEntryCount)
        }
    }

    // MARK: - SuperBlob integration

    func testRequirementsBlobIntegratesIntoSuperBlob() throws {
        let set = try designatedSet()
        let requirementsBlob = try CodeSignatureBlob.requirements(set)
        XCTAssertEqual(requirementsBlob.magic, 0xFADE0C01)
        XCTAssertEqual(requirementsBlob.bytes, try set.serialized())

        let entitlements = try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)])
        let entitlementsBlob = try EntitlementsCanonicalSerializer().blob(entitlements)
        let typedEntitlementsBlob = CodeSignatureBlob.entitlements(blob: entitlementsBlob)
        XCTAssertEqual(typedEntitlementsBlob.magic, 0xFADE7171)

        let directory = try CodeDirectory(
            version: .v20200,
            identifier: try CodeDirectoryIdentifier(rawValue: "req-test"),
            teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            pageSize: .exponent(12),
            codeLimit: 4096,
            specialSlots: [
                CodeDirectorySpecialSlot(index: 1, hash: nil),
                CodeDirectorySpecialSlot(kind: .requirements, hash: Data(repeating: 0, count: 32)),
                CodeDirectorySpecialSlot(index: 3, hash: nil),
                CodeDirectorySpecialSlot(index: 4, hash: nil),
                CodeDirectorySpecialSlot(kind: .entitlements, hash: Data(repeating: 0, count: 32)),
            ],
            codeSlots: (0..<1).map { CodeDirectoryCodeSlot(index: $0, hash: Data(repeating: 0, count: 32)) }
        )
        let superBlob = try SignatureSuperBlob(entries: [
            try CodeSignatureBlobEntry(type: .requirements, blob: requirementsBlob),
            try CodeSignatureBlobEntry(type: .entitlements, blob: typedEntitlementsBlob),
            try CodeSignatureBlobEntry(type: .codeDirectory, blob: .codeDirectory(directory)),
        ]).serialize()
        try superBlob.validate()

        // The independent parser confirms the packed layout and slot order.
        let parsed = try ReadOnlyMachOParser().parseSuperBlob(superBlob.bytes)
        XCTAssertEqual(parsed.entries.map(\.slot), [.codeDirectory, .requirements, .entitlements])
        XCTAssertEqual(
            superBlob.bytes.subdata(in: parsed.entries[1].fileRange),
            try set.serialized()
        )
    }

    func testTypedBlobContentRestrictsItsSlot() throws {
        let set = try designatedSet()
        let requirementsBlob = try CodeSignatureBlob.requirements(set)
        // A requirements blob cannot masquerade as an entitlements slot entry.
        XCTAssertThrowsError(
            try CodeSignatureBlobEntry(type: .entitlements, blob: requirementsBlob)
        ) { error in
            XCTAssertEqual(error as? SuperBlobError, .invalidBlobMagic(expected: 0xFADE7171, actual: 0xFADE0C01))
        }
    }
}
