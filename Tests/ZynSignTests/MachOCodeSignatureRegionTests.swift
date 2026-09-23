import Foundation
import XCTest
@testable import ZynSign

/// Construction and append-boundary tests use hand-assembled Mach-O bytes and
/// independently decoded fixed fields. They do not create a CMS signature or
/// assert Apple-platform acceptance.
final class MachOCodeSignatureRegionTests: XCTestCase {
    private let parser = ReadOnlyMachOParser()

    private func emptySerializedSuperBlob() throws -> SuperBlobSerialization {
        try SignatureSuperBlob(entries: []).serialize()
    }

    private func region() throws -> MachOCodeSignatureRegion {
        try MachOCodeSignatureRegion(serializedSuperBlob: emptySerializedSuperBlob())
    }

    private func assertRegionError(
        _ expected: MachOCodeSignatureRegionError,
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? MachOCodeSignatureRegionError, expected, file: file, line: line)
        }
    }

    private func readUInt32(_ bytes: Data, at offset: Int, order: MachOByteOrder) -> UInt32 {
        let selected: [Int]
        switch order {
        case .bigEndian: selected = [0, 1, 2, 3]
        case .littleEndian: selected = [3, 2, 1, 0]
        }
        return selected.reduce(UInt32(0)) { partial, index in
            (partial << 8) | UInt32(bytes[offset + index])
        }
    }

    private func readUInt64(_ bytes: Data, at offset: Int, order: MachOByteOrder) -> UInt64 {
        let selected: [Int]
        switch order {
        case .bigEndian: selected = Array(0..<8)
        case .littleEndian: selected = Array((0..<8).reversed())
        }
        return selected.reduce(UInt64(0)) { partial, index in
            (partial << 8) | UInt64(bytes[offset + index])
        }
    }

    private func assertPreservedOutside(
        _ source: Data,
        in output: Data,
        allowedRanges: [Range<Int>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(output.count, source.count, file: file, line: line)
        for offset in 0..<source.count where !allowedRanges.contains(where: { $0.contains(offset) }) {
            XCTAssertEqual(output[offset], source[offset], "Unexpected mutation at byte \(offset)", file: file, line: line)
        }
    }

    // MARK: - Region construction and integer-width layout

    func testRegionPadsSuperBlobAndLayoutSeparatesPrefixAndTrailingPadding() throws {
        let region = try region()
        XCTAssertEqual(region.serializedSuperBlobLength, 12)
        XCTAssertEqual(region.dataSize, 16)
        XCTAssertEqual(region.trailingPaddingLength, 4)
        XCTAssertEqual(region.bytes.prefix(12), try emptySerializedSuperBlob().bytes)
        XCTAssertEqual(region.bytes.suffix(4), Data(repeating: 0, count: 4))

        let layout = try region.layout(appendingToFileLength: 17)
        XCTAssertEqual(layout.placement, .append)
        XCTAssertEqual(layout.originalFileLength, 17)
        XCTAssertEqual(layout.offset, 32)
        XCTAssertEqual(layout.prefixPaddingLength, 15)
        XCTAssertEqual(layout.size, 16)
        XCTAssertEqual(layout.trailingPaddingLength, 4)
        XCTAssertEqual(layout.endOffset, 48)
        XCTAssertEqual(layout.resultingFileLength, 48)
        XCTAssertEqual(try layout.loadCommandFields(), .init(dataOffset: 32, dataSize: 16))
        try layout.validate(signedCodeLimit: 0)
        try layout.validate(signedCodeLimit: 32)
        assertRegionError(.codeLimitOverlapsSignatureRegion(codeLimit: 33, signatureOffset: 32)) {
            try layout.validate(signedCodeLimit: 33)
        }
    }

    func testOddLengthSuperBlobGetsOnlyZeroTrailingReserve() throws {
        let cms = try CodeSignatureBlob.opaque(serializedBytes: Data([
            0xFA, 0xDE, 0x0B, 0x01, 0, 0, 0, 9, 0xA5
        ]))
        let serialized = try SignatureSuperBlob(entries: [
            CodeSignatureBlobEntry(type: .cms, blob: cms)
        ]).serialize()
        XCTAssertEqual(serialized.bytes.count, 29)

        let region = try MachOCodeSignatureRegion(serializedSuperBlob: serialized)
        XCTAssertEqual(region.dataSize, 32)
        XCTAssertEqual(region.trailingPaddingLength, 3)
        XCTAssertEqual(region.bytes.prefix(29), serialized.bytes)
        XCTAssertEqual(region.bytes.suffix(3), Data(repeating: 0, count: 3))
    }

    func testLayoutRejectsOverflowAndMachOFieldNarrowingWithoutAllocation() throws {
        let oversizedDataSize = Int(UInt32.max) + 1
        let dataSizeLayout = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: Int(UInt32.max),
            toFileLength: 0
        )
        XCTAssertEqual(dataSizeLayout.size, oversizedDataSize)
        assertRegionError(.unrepresentableDataSize(oversizedDataSize)) {
            _ = try dataSizeLayout.loadCommandFields()
        }

        let oversizedOffset = Int(UInt32.max) + 1
        let offsetLayout = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: 1,
            toFileLength: Int(UInt32.max)
        )
        XCTAssertEqual(offsetLayout.offset, oversizedOffset)
        assertRegionError(.unrepresentableDataOffset(oversizedOffset)) {
            _ = try offsetLayout.loadCommandFields()
        }

        assertRegionError(.integerOverflow) {
            _ = try MachOCodeSignatureRegionLayout(
                appendingSerializedSuperBlobLength: 16,
                toFileLength: Int.max - 15
            )
        }
        assertRegionError(.integerOverflow) {
            _ = try MachOCodeSignatureRegionLayout(
                appendingSerializedSuperBlobLength: 1,
                toFileLength: Int.max
            )
        }
        assertRegionError(.invalidFileLength) {
            _ = try MachOCodeSignatureRegionLayout(
                appendingSerializedSuperBlobLength: 1,
                toFileLength: -1
            )
        }
        assertRegionError(.invalidLength) {
            _ = try MachOCodeSignatureRegionLayout(
                appendingSerializedSuperBlobLength: 0,
                toFileLength: 0
            )
        }
    }

    // MARK: - Existing signature inspection

    func testInspectorDistinguishesAbsentValidAndMalformedSignatureStates() throws {
        let inspector = MachOCodeSignatureInspector()
        guard case .thin(let absent) = inspector.inspect(bytes: Data(MachOFixtures.appendableThin())) else {
            return XCTFail("Expected thin inspection")
        }
        XCTAssertEqual(absent.existingSignature, .absent)

        let validBytes = Data(MachOFixtures.signedThin(MachOFixtures.superBlob([])))
        guard case .thin(let valid) = inspector.inspect(bytes: validBytes),
              case .valid(let embedded) = valid.existingSignature else {
            return XCTFail("Expected valid embedded signature")
        }
        XCTAssertEqual(embedded.command.dataOffset, 48)
        XCTAssertEqual(embedded.command.dataSize, 12)

        var invalidOffset = Array(validBytes)
        MachOFixtures.put(UInt64(UInt32.max), at: 40, in: &invalidOffset, order: .littleEndian)
        guard case .malformedSignature(_, .invalidRegionOffset(let offsetError)) = inspector.inspect(bytes: Data(invalidOffset)) else {
            return XCTFail("Expected an invalid signature offset")
        }
        XCTAssertEqual(offsetError.boundary, .signatureRegion)

        var invalidSize = Array(validBytes)
        MachOFixtures.put(0, at: 44, in: &invalidSize, order: .littleEndian)
        guard case .malformedSignature(_, .invalidRegionSize(let sizeError)) = inspector.inspect(bytes: Data(invalidSize)) else {
            return XCTFail("Expected an invalid signature size")
        }
        XCTAssertEqual(sizeError.reason, .invalidLength)

        var malformedRegion = Array(validBytes)
        malformedRegion[48] ^= 0xFF
        guard case .malformedSignature(_, .malformedRegion(let regionError)) = inspector.inspect(bytes: Data(malformedRegion)) else {
            return XCTFail("Expected a malformed SuperBlob region")
        }
        XCTAssertEqual(regionError.boundary, .superBlob)

        var malformedCommand = Array(validBytes)
        MachOFixtures.put(8, at: 36, in: &malformedCommand, order: .littleEndian)
        guard case .malformedSignature(_, .malformedCommand(let commandError)) = inspector.inspect(bytes: Data(malformedCommand)) else {
            return XCTFail("Expected a malformed LC_CODE_SIGNATURE command")
        }
        XCTAssertEqual(commandError.boundary, .codeSignatureCommand)
    }

    func testInspectorReportsUniversalSlicesWithoutTreatingThemAsThin() throws {
        let thin = MachOFixtures.appendableThin()
        let fat = Data(MachOFixtures.fat([(MachOFixtures.arm64, 0, thin)]))
        guard case .universal(let slices) = MachOCodeSignatureInspector().inspect(bytes: fat) else {
            return XCTFail("Expected universal inspection")
        }
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].architectureIndex, 0)
        XCTAssertEqual(slices[0].existingSignature, .absent)

        assertRegionError(.universalImageUnsupported) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: fat,
                signedCodeLimit: UInt64(thin.count)
            )
        }
    }

    // MARK: - Thin append mutation

    func testParserExposesOnlySegmentFactsNeededForSafeHeaderCapacity() throws {
        let bytes = Data(MachOFixtures.appendableThin())
        let slice = try XCTUnwrap(try parser.parse(bytes).slice(at: 0))
        XCTAssertEqual(slice.loadCommandsEndOffset, 104)
        XCTAssertEqual(slice.firstFileBackedContentOffset, 128)
        let segment = try XCTUnwrap(slice.segments.first)
        XCTAssertTrue(segment.isLinkEdit)
        XCTAssertEqual(segment.fileOffset, 128)
        XCTAssertEqual(segment.fileSize, 32)
        XCTAssertEqual(segment.virtualMemorySize, 4_096)
        XCTAssertEqual(segment.fileSizeFieldRange, 80..<88)
        XCTAssertEqual(segment.firstFileBackedSectionOffset, nil)
    }

    func testWriterAppendsAlignedRegionAndEncodesIndependentLoadCommandFields() throws {
        let source = Data(MachOFixtures.appendableThin())
        let signatureRegion = try region()
        let result = try MachOCodeSignatureWriter().append(
            signatureRegion,
            to: source,
            signedCodeLimit: UInt64(source.count)
        )

        XCTAssertEqual(result.layout.offset, source.count)
        XCTAssertEqual(result.layout.size, 16)
        XCTAssertEqual(result.layout.resultingFileLength, source.count + 16)
        XCTAssertEqual(result.loadCommandFields, .init(dataOffset: UInt32(source.count), dataSize: 16))
        XCTAssertEqual(result.signedCodeLimit, UInt64(source.count))
        XCTAssertEqual(readUInt32(result.bytes, at: 16, order: .littleEndian), 2)
        XCTAssertEqual(readUInt32(result.bytes, at: 20, order: .littleEndian), 88)
        XCTAssertEqual(readUInt32(result.bytes, at: 104, order: .littleEndian), MachOLoadCommandType.codeSignature)
        XCTAssertEqual(readUInt32(result.bytes, at: 108, order: .littleEndian), 16)
        XCTAssertEqual(readUInt32(result.bytes, at: 112, order: .littleEndian), UInt32(source.count))
        XCTAssertEqual(readUInt32(result.bytes, at: 116, order: .littleEndian), 16)
        XCTAssertEqual(readUInt64(result.bytes, at: 80, order: .littleEndian), 48)
        XCTAssertEqual(
            result.bytes.subdata(in: source.count..<(source.count + signatureRegion.serializedSuperBlobLength)),
            signatureRegion.serializedSuperBlob
        )
        XCTAssertEqual(result.bytes.suffix(signatureRegion.trailingPaddingLength), Data(repeating: 0, count: 4))
        assertPreservedOutside(source, in: result.bytes, allowedRanges: result.modifiedByteRanges)

        let parsed = try parser.parse(result.bytes)
        let signature = try XCTUnwrap(parsed.slice(at: 0)?.embeddedSignature)
        XCTAssertEqual(signature.command.dataOffset, source.count)
        XCTAssertEqual(signature.command.dataSize, signatureRegion.dataSize)
        XCTAssertEqual(signature.superBlob.length, signatureRegion.serializedSuperBlobLength)
    }

    func testWriterCanInsertDeterministicPrefixPaddingWithoutHashingIt() throws {
        let source = Data(MachOFixtures.appendableThin(payload: Array(repeating: 0xA5, count: 31)))
        XCTAssertEqual(source.count, 159)
        let result = try MachOCodeSignatureWriter().append(
            try region(),
            to: source,
            // This deliberately differs from the original file length and is
            // supplied by a future CodeDirectory construction caller.
            signedCodeLimit: 160
        )
        XCTAssertEqual(result.layout.offset, 160)
        XCTAssertEqual(result.layout.prefixPaddingLength, 1)
        XCTAssertEqual(result.bytes[159], 0)
        XCTAssertEqual(readUInt32(result.bytes, at: 112, order: .littleEndian), 160)
        XCTAssertEqual(readUInt64(result.bytes, at: 80, order: .littleEndian), 48)
        assertPreservedOutside(source, in: result.bytes, allowedRanges: result.modifiedByteRanges)
    }

    func testWriterHandlesBigEndianThinFieldsWithoutTruncation() throws {
        let source = Data(MachOFixtures.appendableThin(order: .bigEndian))
        let result = try MachOCodeSignatureWriter().append(
            try region(),
            to: source,
            signedCodeLimit: UInt64(source.count)
        )
        XCTAssertEqual(readUInt32(result.bytes, at: 16, order: .bigEndian), 2)
        XCTAssertEqual(readUInt32(result.bytes, at: 20, order: .bigEndian), 88)
        XCTAssertEqual(readUInt32(result.bytes, at: 104, order: .bigEndian), MachOLoadCommandType.codeSignature)
        XCTAssertEqual(readUInt32(result.bytes, at: 112, order: .bigEndian), UInt32(source.count))
        XCTAssertEqual(readUInt64(result.bytes, at: 80, order: .bigEndian), 48)
    }

    // MARK: - Refusals and preservation policy

    func testWriterRejectsExistingSignaturesAndNeverTreatsReplacementAsImplicit() throws {
        let source = Data(MachOFixtures.signedThin(MachOFixtures.superBlob([])))
        let signatureRegion = try region()
        assertRegionError(.existingSignatureRejected) {
            _ = try MachOCodeSignatureWriter().append(signatureRegion, to: source, signedCodeLimit: 48)
        }
        assertRegionError(.replacementUnsupported) {
            _ = try MachOCodeSignatureWriter().append(
                signatureRegion,
                to: source,
                signedCodeLimit: 48,
                existingSignaturePolicy: .replaceExistingSignature
            )
        }
        XCTAssertEqual(source, Data(MachOFixtures.signedThin(MachOFixtures.superBlob([]))))
    }

    func testWriterRejectsMalformedExistingSignatureBeforeAnyMutation() throws {
        var malformed = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        MachOFixtures.put(0, at: 44, in: &malformed, order: .littleEndian)
        guard case .malformedSignature(_, let state) = MachOCodeSignatureInspector().inspect(bytes: Data(malformed)) else {
            return XCTFail("Expected malformed existing signature")
        }
        assertRegionError(.malformedExistingSignature(state)) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: Data(malformed),
                signedCodeLimit: 0
            )
        }
    }

    func testWriterRejectsInsufficientOrNonZeroLoadCommandCapacity() throws {
        let insufficient = Data(MachOFixtures.appendableThin(headerPaddingLength: 0))
        assertRegionError(.insufficientLoadCommandCapacity(requiredEndOffset: 120, firstFileBackedContentOffset: 104)) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: insufficient,
                signedCodeLimit: UInt64(insufficient.count)
            )
        }

        var nonZeroPadding = MachOFixtures.appendableThin()
        nonZeroPadding[104] = 0x7F
        assertRegionError(.nonZeroLoadCommandPadding) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: Data(nonZeroPadding),
                signedCodeLimit: UInt64(nonZeroPadding.count)
            )
        }
    }

    func testWriterRejectsMissingOrUnsafeLinkEditLayout() throws {
        let payload = Array(repeating: UInt8(0xA5), count: 32)
        let textSegment = MachOFixtures.segment64(
            name: "__TEXT",
            fileOffset: 128,
            fileSize: UInt64(payload.count),
            virtualMemorySize: 4_096
        )
        let noLinkEdit = Data(MachOFixtures.thin(
            commands: [textSegment],
            headerPadding: Array(repeating: 0, count: 24),
            payload: payload
        ))
        assertRegionError(.missingLinkEditSegment) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: noLinkEdit,
                signedCodeLimit: UInt64(noLinkEdit.count)
            )
        }

        let noVirtualSlack = Data(MachOFixtures.appendableThin(virtualMemorySize: 32))
        assertRegionError(.unsafeLinkEditLayout) {
            _ = try MachOCodeSignatureWriter().append(
                try self.region(),
                to: noVirtualSlack,
                signedCodeLimit: UInt64(noVirtualSlack.count)
            )
        }
    }
}
