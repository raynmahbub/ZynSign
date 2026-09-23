import Foundation
import XCTest
@testable import ZynSign

final class SuperBlobConstructionTests: XCTestCase {
    private let parser = ReadOnlyMachOParser()

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

    // Literal vectors are independent of both production writer and parser.
    private var emptyBytes: Data { hex("fade0cc0 0000000c 00000000") }
    private var oneBlobBytes: Data {
        hex("fade0cc0 0000001c 00000001 00010000 00000014 fade0b01 00000008")
    }
    private var multipleBytes: Data {
        hex("""
        fade0cc0 0000002d 00000002
        00000005 0000001c 00010000 00000025
        fade7171 00000009 41 fade0b01 00000008
        """)
    }
    private var directoryBytes: Data {
        hex("""
        fade0cc0 00000042 00000001 00000000 00000014
        fade0c02 0000002e 00020001 00000000
        0000002e 0000002c 00000000 00000000 00000000
        20020000 00000000 7800
        """)
    }

    private func replaced(_ data: Data, at offset: Int, with value: UInt32) -> Data {
        var result = Data(data)
        result.replaceSubrange(offset..<offset + 4, with: [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
        ])
        return result
    }

    private func opaque(_ type: CodeSignatureBlobType, _ bytes: String) throws -> CodeSignatureBlobEntry {
        try CodeSignatureBlobEntry(type: type, blob: .opaque(serializedBytes: hex(bytes)))
    }

    private func emptyDirectory() throws -> CodeDirectory {
        let request = CodeDirectoryConstructionRequest(
            version: .v20001, identifier: try CodeDirectoryIdentifier(rawValue: "x"),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            pageSize: .unpaged, codeLimit: 0
        )
        return try CodeDirectoryConstructor(messageDigest: NoDigestExpected()).construct(request, code: Data())
    }

    private struct NoDigestExpected: MessageDigest {
        func digest(_ data: Data, algorithm: DigestAlgorithm) throws -> Digest {
            XCTFail("An empty code range must not invoke the digest boundary")
            throw CodeDirectoryError.malformedBinary
        }
    }

    private func assertConstructionFailure(
        _ expected: SuperBlobError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? SuperBlobError, expected, file: file, line: line)
        }
    }

    private func assertParseFailure(
        _ data: Data, _ reason: MachOParsingError.Reason, _ boundary: MachOParsingError.Boundary,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Repetition also ensures a malformed input fails deterministically.
        for _ in 0..<2 {
            XCTAssertThrowsError(try parser.parseSuperBlob(data), file: file, line: line) {
                XCTAssertEqual($0 as? MachOParsingError, MachOParsingError(reason, at: boundary),
                               file: file, line: line)
            }
        }
    }

    func testEmptyContainerIndependentBytes() throws {
        let model = try SignatureSuperBlob(entries: [])
        try model.validate()
        let result = try model.serialize()
        XCTAssertEqual(result.bytes, emptyBytes)
        XCTAssertEqual(result.layout.length, 12)
        XCTAssertEqual(result.layout.indexEnd, 12)
        XCTAssertTrue(result.layout.blobs.isEmpty)
        try result.validate()
        XCTAssertEqual(try parser.parseSuperBlob(result.bytes).count, 0)
    }

    func testOneMinimalOpaqueBlobIndependentBytes() throws {
        let entry = try opaque(.cms, "fade0b01 00000008")
        let result = try SignatureSuperBlob(entries: [entry]).serialize()
        XCTAssertEqual(result.bytes, oneBlobBytes)
        XCTAssertEqual(entry.blob.serializedLength, 8)
        XCTAssertTrue(entry.blob.payload.isEmpty)
        XCTAssertEqual(entry.blob.content, .opaque)
        try result.validate()
    }

    func testCodeDirectoryConstructorIntegrationAndIndependentBytes() throws {
        let directory = try emptyDirectory()
        let original = try directory.serialize()
        let blob = try CodeSignatureBlob.codeDirectory(directory)
        let result = try SignatureSuperBlob(entries: [
            CodeSignatureBlobEntry(type: .codeDirectory, blob: blob)
        ]).serialize()
        XCTAssertEqual(blob.content, .codeDirectory(original))
        XCTAssertEqual(blob.bytes, original.bytes)
        XCTAssertEqual(Data(result.bytes.dropFirst(20)), original.bytes)
        XCTAssertEqual(result.bytes, directoryBytes)
        try result.validate()
        let parsed = try parser.parseSuperBlob(result.bytes)
        let entry = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(entry.slot, .codeDirectory)
        XCTAssertEqual(entry.relativeOffset, 20)
        XCTAssertEqual(entry.fileRange, 20..<66)
        XCTAssertEqual(entry.codeDirectory?.identifier, "x")
        XCTAssertEqual(entry.codeDirectory?.codeSlotCount, 0)
    }

    func testMultipleBlobsIndependentBytesAndNoInventedAlignment() throws {
        let entitlements = try opaque(.entitlements, "fade7171 00000009 41")
        let cms = try opaque(.cms, "fade0b01 00000008")
        let model = try SignatureSuperBlob(entries: [cms, entitlements])
        let result = try model.serialize()
        XCTAssertEqual(result.bytes, multipleBytes)
        XCTAssertEqual(model.entries.map(\.type), [.entitlements, .cms])
        XCTAssertEqual(result.layout.blobs.map(\.offset), [28, 37])
        XCTAssertEqual(result.layout.blobs.map(\.length), [9, 8])
        XCTAssertEqual(result.layout.length, 45)
        try result.validate()
        let parsed = try parser.parseSuperBlob(result.bytes)
        XCTAssertEqual(parsed.entries.map(\.slot), model.entries.map(\.type))
        for (entry, inspected) in zip(model.entries, parsed.entries) {
            XCTAssertEqual(result.bytes.subdata(in: inspected.fileRange), entry.blob.bytes)
            XCTAssertEqual(result.bytes.subdata(in: inspected.fileRange).dropFirst(8), entry.blob.payload)
        }
    }

    func testDeterminismAcrossInputPermutationsAndRepeatedSerialization() throws {
        let a = try opaque(.cms, "fade0b01 00000008")
        let b = try opaque(.entitlements, "fade7171 00000009 41")
        let c = try opaque(.other(0x20000), "deadbeef 0000000a 0102")
        let expected = try SignatureSuperBlob(entries: [a, b, c]).serialize()
        for entries in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            let model = try SignatureSuperBlob(entries: entries)
            XCTAssertEqual(try model.serialize(), expected)
            XCTAssertEqual(try model.serialize(), try model.serialize())
        }
    }

    func testKnownOpaqueSlotMagicsAndUnknownPayloadPreservation() throws {
        let entries = try [
            opaque(.requirements, "fade0c01 0000000c 00000000"),
            opaque(.entitlements, "fade7171 0000000b 010203"),
            opaque(.derEntitlements, "fade7172 0000000b 010203"),
            opaque(.cms, "fade0b01 0000000b 010203"),
            opaque(.other(UInt32.max), "deadbeef 0000000b 010203")
        ]
        let result = try SignatureSuperBlob(entries: entries).serialize()
        try result.validate()
        let parsed = try parser.parseSuperBlob(result.bytes)
        XCTAssertEqual(parsed.count, entries.count)
        for (entry, inspected) in zip(entries, parsed.entries) {
            XCTAssertEqual(inspected.slot, entry.type)
            XCTAssertEqual(inspected.magic, entry.blob.magic)
            XCTAssertEqual(result.bytes.subdata(in: inspected.fileRange), entry.blob.bytes)
            XCTAssertNil(inspected.codeDirectory)
        }
    }

    func testMultipleCodeDirectoriesRemainIndependentWithoutAlternateGeneration() throws {
        let first = try CodeSignatureBlob.codeDirectory(emptyDirectory())
        // Manually supplied synthetic page hash, not alternate-hash generation.
        let secondDirectory = try CodeDirectory(
            version: .v20200, identifier: CodeDirectoryIdentifier(rawValue: "other"),
            hashConfiguration: CodeDirectoryHashConfiguration(hashType: .sha384),
            pageSize: .unpaged, codeLimit: 100,
            codeSlots: [CodeDirectoryCodeSlot(index: 0, hash: Data(repeating: 0x42, count: 48))]
        )
        let second = try CodeSignatureBlob.codeDirectory(secondDirectory)
        let result = try SignatureSuperBlob(entries: [
            CodeSignatureBlobEntry(type: .alternateCodeDirectory(4), blob: second),
            CodeSignatureBlobEntry(type: .codeDirectory, blob: first),
            CodeSignatureBlobEntry(type: .alternateCodeDirectory(0), blob: first)
        ]).serialize()
        try result.validate()
        let parsed = try parser.parseSuperBlob(result.bytes)
        XCTAssertEqual(parsed.entries.map(\.slotNumber), [0, 0x1000, 0x1004])
        XCTAssertEqual(parsed.entries.map { $0.codeDirectory?.identifier }, ["x", "x", "other"])
        XCTAssertEqual(parsed.entries.last?.codeDirectory?.codeLimit, 100)
        XCTAssertEqual(parsed.entries.last?.codeDirectory?.codeHashes, secondDirectory.codeSlots.map(\.hash))
        for (index, blob) in [first, first, second].enumerated() {
            XCTAssertEqual(result.bytes.subdata(in: parsed.entries[index].fileRange), blob.bytes)
        }
    }

    func testOpaqueDataSubsequenceHasNoZeroBasedIndexAssumption() throws {
        let full = hex("aabbcc fade0b01 00000009 42")
        let sliced = full.dropFirst(3)
        XCTAssertEqual(sliced.startIndex, 3)
        let blob = try CodeSignatureBlob.opaque(serializedBytes: sliced)
        XCTAssertEqual(blob.payload, Data([0x42]))
        let result = try SignatureSuperBlob(entries: [CodeSignatureBlobEntry(type: .cms, blob: blob)]).serialize()
        var prefixed = Data([0xAA, 0xBB])
        prefixed.append(result.bytes)
        XCTAssertEqual(try parser.parseSuperBlob(prefixed.dropFirst(2)).length, result.bytes.count)
        try result.validate()
    }

    func testDuplicateTypesAreNotSilentlyReplaced() throws {
        let entry = try opaque(.cms, "fade0b01 00000008")
        assertConstructionFailure(.duplicateBlobType(0x10000)) {
            _ = try SignatureSuperBlob(entries: [entry, entry])
        }
    }

    func testUnsupportedTypeRepresentationsCannotAliasKnownSlots() throws {
        for index in [Int.min, -1, 5, Int.max] {
            assertConstructionFailure(.unsupportedBlobType) {
                _ = try CodeSignatureBlobType.alternateCodeDirectory(index).encodedValue()
            }
        }
        for raw in [UInt32(0), 2, 5, 7, 0x1000, 0x1004, 0x10000] {
            assertConstructionFailure(.unsupportedBlobType) {
                _ = try CodeSignatureBlobType.other(raw).encodedValue()
            }
            XCTAssertEqual(try CodeSignatureBlobType(rawValue: raw).encodedValue(), raw)
        }
    }

    func testKnownSlotMagicMismatchIsRejected() throws {
        let blob = try CodeSignatureBlob.opaque(serializedBytes: hex("deadbeef 00000008"))
        for type in [CodeSignatureBlobType.codeDirectory, .alternateCodeDirectory(0), .requirements,
                                           .entitlements, .derEntitlements, .cms] {
            let expected = try XCTUnwrap(type.expectedMagic)
            assertConstructionFailure(.invalidBlobMagic(expected: expected, actual: 0xDEADBEEF)) {
                _ = try CodeSignatureBlobEntry(type: type, blob: blob)
            }
        }
    }

    func testCodeDirectoryCannotBypassTypedConstruction() throws {
        assertConstructionFailure(.codeDirectoryRequiresTypedConstruction) {
            _ = try CodeSignatureBlob.opaque(serializedBytes: hex("fade0c02 00000008"))
        }
        assertConstructionFailure(.codeDirectoryRequiresTypedConstruction) {
            _ = try CodeSignatureBlob.opaque(serializedBytes: emptyDirectory().serialize().bytes)
        }
        let blob = try CodeSignatureBlob.codeDirectory(emptyDirectory())
        assertConstructionFailure(.unsupportedBlobType) {
            _ = try CodeSignatureBlobEntry(type: .other(0x20000), blob: blob)
        }
    }

    func testOpaqueHeaderAndLengthMustBeExact() throws {
        for value in ["", "fade0b01", "fade0b01 000000", "fade0b01 00000007",
                      "fade0b01 00000009", "fade0b01 00000008 00", "fade0b01 ffffffff"] {
            assertConstructionFailure(.invalidLength) {
                _ = try CodeSignatureBlob.opaque(serializedBytes: hex(value))
            }
        }
    }

    func testMaximumEntryCountAndFirstRejectedCount() throws {
        let blob = try CodeSignatureBlob.opaque(serializedBytes: hex("deadbeef 00000008"))
        let entries = try (0..<128).map {
            try CodeSignatureBlobEntry(type: .other(0x20000 + UInt32($0)), blob: blob)
        }
        let result = try SignatureSuperBlob(entries: entries).serialize()
        XCTAssertEqual(result.layout.length, 2060)
        XCTAssertEqual(result.layout.indexEnd, 1036)
        XCTAssertEqual(try parser.parseSuperBlob(result.bytes).count, 128)
        try result.validate()
        assertConstructionFailure(.resourceLimitExceeded) {
            _ = try SignatureSuperBlob(entries: entries + [entries[0]])
        }
        assertConstructionFailure(.resourceLimitExceeded) {
            _ = try SuperBlobLayout(blobLengths: Array(repeating: 8, count: 129))
        }
    }

    func testSizeAndOverflowBoundariesWithoutAllocatingLargePayloads() throws {
        let maximum = SignatureSuperBlob.maximumSerializedLength
        XCTAssertEqual(try SuperBlobLayout(blobLengths: [maximum - 20]).length, maximum)
        XCTAssertEqual(try SuperBlobLayout(blobLengths: [maximum - 36, 8]).length, maximum)
        assertConstructionFailure(.resourceLimitExceeded) {
            _ = try SuperBlobLayout(blobLengths: [maximum - 19])
        }
        assertConstructionFailure(.resourceLimitExceeded) {
            _ = try SuperBlobLayout(blobLengths: [maximum - 36, 9])
        }
        for value in [Int.max, Int(UInt32.max)] {
            assertConstructionFailure(.integerOverflow) { _ = try SuperBlobLayout(blobLengths: [value]) }
        }
        for value in [Int.min, -1, 0, 7] {
            assertConstructionFailure(.invalidLength) { _ = try SuperBlobLayout(blobLengths: [value]) }
        }
    }

    func testModeratelyLargePayloadAndEverySmallLengthAlignmentResidue() throws {
        for size in [0, 1, 2, 3, 4, 7, 8, 255, 1024 * 1024] {
            var bytes = replaced(hex("deadbeef 00000008"), at: 4, with: UInt32(size + 8))
            bytes.append(Data(repeating: 0xA5, count: size))
            let blob = try CodeSignatureBlob.opaque(serializedBytes: bytes)
            let model = try SignatureSuperBlob(entries: [
                CodeSignatureBlobEntry(type: .other(0x20000), blob: blob),
                CodeSignatureBlobEntry(type: .other(0x20001), blob: blob)
            ])
            let result = try model.serialize()
            XCTAssertEqual(result.layout.blobs[1].offset, 36 + size)
            XCTAssertEqual(result.layout.length, 44 + size * 2)
            try result.validate()
        }
    }

    func testEveryTruncatedPrefixFailsStructurally() throws {
        for bytes in [oneBlobBytes, multipleBytes, directoryBytes] {
            for length in 0..<bytes.count {
                XCTAssertThrowsError(try parser.parseSuperBlob(Data(bytes.prefix(length)))) {
                    XCTAssertNotNil($0 as? MachOParsingError)
                }
            }
        }
        for length in 0..<12 {
            assertParseFailure(Data(emptyBytes.prefix(length)), .truncatedInput, .superBlob)
        }
    }

    func testInvalidContainerMagicLengthsAndCount() throws {
        assertParseFailure(replaced(oneBlobBytes, at: 0, with: 0xFADE0CC1), .malformedSuperBlob, .superBlob)
        assertParseFailure(replaced(oneBlobBytes, at: 0, with: 0xC00CDEFA), .malformedSuperBlob, .superBlob)
        for length in [UInt32(0), 8, 11] {
            assertParseFailure(replaced(oneBlobBytes, at: 4, with: length), .invalidLength, .superBlob)
        }
        assertParseFailure(replaced(oneBlobBytes, at: 4, with: UInt32.max), .truncatedInput, .superBlob)
        assertParseFailure(replaced(emptyBytes, at: 8, with: 1), .malformedSuperBlob, .superBlob)
        for count in [UInt32(129), UInt32.max] {
            assertParseFailure(replaced(emptyBytes, at: 8, with: count), .resourceLimitExceeded, .superBlob)
        }
        var trailing = oneBlobBytes
        trailing.append(0)
        assertParseFailure(trailing, .invalidLength, .superBlob)
    }

    func testIndexOffsetsBeforeTableAtEndAndBeyondContainer() throws {
        for offset in [UInt32(0), 1, 12, 19] {
            assertParseFailure(replaced(oneBlobBytes, at: 16, with: offset), .invalidOffset, .signatureBlob)
        }
        assertParseFailure(replaced(oneBlobBytes, at: 16, with: 28), .truncatedInput, .signatureBlob)
        for offset in [UInt32(29), UInt32.max] {
            assertParseFailure(replaced(oneBlobBytes, at: 16, with: offset), .invalidOffset, .signatureBlob)
        }
    }

    func testDuplicateIndexAndOverlappingRegions() throws {
        assertParseFailure(replaced(multipleBytes, at: 20, with: 5), .malformedSuperBlob, .superBlob)
        assertParseFailure(replaced(multipleBytes, at: 24, with: 28), .malformedSignatureBlob, .signatureBlob)
        // First blob extends one byte into the otherwise valid second blob.
        assertParseFailure(replaced(multipleBytes, at: 32, with: 10), .malformedSignatureBlob, .signatureBlob)
    }

    func testMalformedMemberLengthAndWrongMagic() throws {
        for length in [UInt32(0), 7] {
            assertParseFailure(replaced(oneBlobBytes, at: 24, with: length), .invalidLength, .signatureBlob)
        }
        for length in [UInt32(9), UInt32.max] {
            assertParseFailure(replaced(oneBlobBytes, at: 24, with: length), .invalidLength, .signatureBlob)
        }
        assertParseFailure(replaced(oneBlobBytes, at: 20, with: 0), .malformedSignatureBlob, .signatureBlob)
        assertParseFailure(replaced(directoryBytes, at: 20, with: 0xFADE0B01), .malformedSignatureBlob, .signatureBlob)
    }

    func testCorruptedCodeDirectoryStructureIsNotTreatedAsOpaque() throws {
        assertParseFailure(replaced(directoryBytes, at: 60, with: 1), .malformedCodeDirectory, .codeDirectory)
        assertParseFailure(replaced(directoryBytes, at: 40, with: UInt32.max), .invalidOffset, .identifier)
        assertParseFailure(replaced(directoryBytes, at: 24, with: 8), .truncatedInput, .codeDirectory)
    }

    func testOpaquePayloadCorruptionIsNotFalselyAuthenticated() throws {
        var payloadChange = multipleBytes
        payloadChange[36] ^= 0xFF
        let parsed = try parser.parseSuperBlob(payloadChange)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNotEqual(payloadChange, multipleBytes)
        // Structural validity cannot detect a changed arbitrary payload.
        let layout = try SuperBlobLayout(blobLengths: [9, 8])
        try SuperBlobSerialization(bytes: payloadChange, layout: layout).validate()
    }

    func testExplicitSerializationValidationRejectsInconsistentMetadata() throws {
        assertConstructionFailure(.inconsistentSerialization) {
            try SuperBlobSerialization(bytes: oneBlobBytes, layout: SuperBlobLayout(blobLengths: [9])).validate()
        }
        assertConstructionFailure(.invalidBlobCount) {
            try SuperBlobSerialization(bytes: multipleBytes, layout: SuperBlobLayout(blobLengths: [25])).validate()
        }
        assertConstructionFailure(.inconsistentSerialization) {
            try SuperBlobSerialization(bytes: multipleBytes, layout: SuperBlobLayout(blobLengths: [8, 9])).validate()
        }
        // Arbitrary index order is parseable, but not ZynSign's canonical output.
        var reordered = multipleBytes
        reordered.replaceSubrange(12..<20, with: multipleBytes[20..<28])
        reordered.replaceSubrange(20..<28, with: multipleBytes[12..<20])
        XCTAssertEqual(try parser.parseSuperBlob(reordered).entries.map(\.slotNumber), [0x10000, 5])
        assertConstructionFailure(.inconsistentSerialization) {
            try SuperBlobSerialization(bytes: reordered, layout: SuperBlobLayout(blobLengths: [9, 8])).validate()
        }
    }
}
