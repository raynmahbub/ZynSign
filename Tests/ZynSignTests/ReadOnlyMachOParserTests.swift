import Foundation
import XCTest
@testable import ZynSign

/// All inputs here are deliberately small, synthetic, and unsigned.
final class ReadOnlyMachOParserTests: XCTestCase {
    private let parser = ReadOnlyMachOParser()
    private let directoryStart = 48 + 20 // 64-bit header, one command, one SuperBlob index

    private func read(_ bytes: [UInt8]) throws -> MachOImage {
        try parser.parse(Data(bytes))
    }

    private func withDirectory(
        version: UInt32 = 0x20500,
        codeLimit: UInt32 = 48,
        extendedCodeLimit: UInt64 = 0,
        hashType: UInt8 = 2,
        hashSize: Int = 32,
        specialCount: Int = 1,
        team: String? = "EXAMPLETEAM",
        scatter: Bool = false,
        preEncrypt: Bool = false,
        linkage: [UInt8] = []
    ) -> [UInt8] {
        let directory = MachOFixtures.codeDirectory(
            version: version, codeLimit: codeLimit, extendedCodeLimit: extendedCodeLimit,
            hashType: hashType, hashSize: hashSize, specialCount: specialCount,
            team: team, scatter: scatter, preEncrypt: preEncrypt, linkage: linkage
        )
        return MachOFixtures.signedThin(MachOFixtures.superBlob([(0, directory)]))
    }

    private func directory(in bytes: [UInt8]) throws -> MachOCodeDirectory {
        let image = try read(bytes)
        return try XCTUnwrap(image.slice(at: 0)?.embeddedSignature?.superBlob.entries.first?.codeDirectory)
    }

    private func assertFailure(
        _ bytes: [UInt8],
        _ reason: MachOParsingError.Reason,
        _ boundary: MachOParsingError.Boundary,
        architecture: Int? = nil,
        version: UInt32? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try read(bytes), file: file, line: line) { error in
            guard let parsed = error as? MachOParsingError else {
                return XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
            }
            XCTAssertEqual(parsed.reason, reason, file: file, line: line)
            XCTAssertEqual(parsed.boundary, boundary, file: file, line: line)
            XCTAssertEqual(parsed.architectureIndex, architecture, file: file, line: line)
            XCTAssertEqual(parsed.version, version, file: file, line: line)
        }
    }

    // MARK: - Headers and load commands

    func testLittleEndian32BitThinImageWithoutSignature() throws {
        let image = try read(MachOFixtures.thin(wordSize: .bits32, cpu: 12, subtype: 9))
        guard case .thin(let slice) = image.container else { return XCTFail("Expected thin") }
        XCTAssertEqual(slice.header.magic, .mach32)
        XCTAssertEqual(slice.header.wordSize, .bits32)
        XCTAssertEqual(slice.header.byteOrder, .littleEndian)
        XCTAssertEqual(slice.header.cpu, .arm)
        XCTAssertEqual(slice.header.cpuSubtype, 9)
        XCTAssertEqual(slice.header.fileType, 2)
        XCTAssertEqual(slice.header.flags, 0x20)
        XCTAssertNil(slice.header.reserved)
        XCTAssertEqual(slice.fileRange, 0..<28)
        XCTAssertTrue(slice.loadCommands.isEmpty)
        XCTAssertNil(slice.embeddedSignature)
    }

    func test64BitThinImageAndCodeSignatureCommand() throws {
        let image = try read(withDirectory())
        let slice = try XCTUnwrap(image.slice(at: 0))
        let signature = try XCTUnwrap(slice.embeddedSignature)
        XCTAssertEqual(slice.header.magic, .mach64)
        XCTAssertEqual(slice.header.wordSize, .bits64)
        XCTAssertEqual(slice.header.cpu, .arm64)
        XCTAssertEqual(slice.header.loadCommandCount, 1)
        XCTAssertEqual(slice.header.loadCommandsSize, 16)
        XCTAssertEqual(slice.header.reserved, 0)
        XCTAssertEqual(slice.loadCommands[0].fileRange, 32..<48)
        XCTAssertTrue(slice.loadCommands[0].isCodeSignature)
        XCTAssertEqual(signature.command.commandRange, 32..<48)
        XCTAssertEqual(signature.command.dataOffset, 48)
        XCTAssertEqual(signature.command.fileRange.lowerBound, 48)
        XCTAssertEqual(signature.command.dataSize, signature.superBlob.length)
    }

    func testBigEndianThinHeadersAndLoadCommand() throws {
        let empty = MachOFixtures.superBlob([])
        let image = try read(MachOFixtures.signedThin(empty, order: .bigEndian))
        let slice = try XCTUnwrap(image.slice(at: 0))
        XCTAssertEqual(slice.header.byteOrder, .bigEndian)
        XCTAssertEqual(slice.header.magic, .mach64)
        XCTAssertEqual(slice.embeddedSignature?.superBlob.count, 0)
        let image32 = try read(MachOFixtures.thin(wordSize: .bits32, order: .bigEndian))
        XCTAssertEqual(image32.slice(at: 0)?.header.byteOrder, .bigEndian)
        XCTAssertEqual(image32.slice(at: 0)?.header.magic, .mach32)
    }

    func testUnknownCPUFamilyAnd32BitCommandAlignmentAreDescriptive() throws {
        let command = MachOFixtures.command(0x12345678, size: 12)
        let image = try read(MachOFixtures.thin(wordSize: .bits32, cpu: -123,
                                               commands: [command]))
        XCTAssertEqual(image.slice(at: 0)?.header.cpu, .other(-123))
        XCTAssertEqual(image.slice(at: 0)?.loadCommands[0].size, 12)
    }

    func testUnknownCommandsAreDelimitableAndNotInterpreted() throws {
        let image = try read(MachOFixtures.thin(commands: [MachOFixtures.command(0xDEADBEEF)]))
        let slice = try XCTUnwrap(image.slice(at: 0))
        XCTAssertEqual(slice.loadCommands.map(\.type), [0xDEADBEEF])
        XCTAssertEqual(slice.loadCommands[0].fileRange, 32..<40)
        XCTAssertNil(slice.embeddedSignature)
    }

    func testUnrecognizedAndTruncatedMagic() {
        assertFailure([0, 0, 0, 0], .unsupportedFormat, .magic)
        assertFailure([0xFE, 0xED, 0xFA], .truncatedInput, .magic)
        assertFailure([], .truncatedInput, .magic)
    }

    func testTruncatedAndInconsistentHeaders() {
        assertFailure(Array(MachOFixtures.thin().prefix(31)), .truncatedInput, .header)
        var countAndSize = MachOFixtures.thin()
        MachOFixtures.put(8, at: 20, in: &countAndSize, order: .littleEndian)
        assertFailure(countAndSize, .malformedHeader, .header)
        var invalidCount = MachOFixtures.thin()
        MachOFixtures.put(UInt64(UInt32.max), at: 16, in: &invalidCount, order: .littleEndian)
        assertFailure(invalidCount, .resourceLimitExceeded, .loadCommands)
        var unaligned = MachOFixtures.thin()
        MachOFixtures.put(1, at: 16, in: &unaligned, order: .littleEndian)
        MachOFixtures.put(9, at: 20, in: &unaligned, order: .littleEndian)
        assertFailure(unaligned, .malformedHeader, .header)
    }

    func testTruncatedCommandsAndInvalidCommandSizes() {
        var truncated = MachOFixtures.thin(commands: [MachOFixtures.command(0x28)])
        truncated.removeLast()
        assertFailure(truncated, .truncatedInput, .loadCommands)

        var zero = MachOFixtures.thin(commands: [MachOFixtures.command(0x28)])
        MachOFixtures.put(0, at: 36, in: &zero, order: .littleEndian)
        assertFailure(zero, .invalidLoadCommand, .loadCommands)

        var outside = MachOFixtures.thin(commands: [MachOFixtures.command(0x28)])
        MachOFixtures.put(24, at: 36, in: &outside, order: .littleEndian)
        assertFailure(outside, .invalidLoadCommand, .loadCommands)

        var extra = MachOFixtures.thin(
            commands: [MachOFixtures.command(0x28)], payload: [UInt8](repeating: 0, count: 8)
        )
        MachOFixtures.put(16, at: 20, in: &extra, order: .littleEndian)
        assertFailure(extra, .invalidLoadCommand, .loadCommands)

        var excessive = MachOFixtures.thin()
        MachOFixtures.put(UInt64(UInt32.max), at: 20, in: &excessive, order: .littleEndian)
        assertFailure(excessive, .resourceLimitExceeded, .loadCommands)
    }

    func testCodeSignatureCommandMalformedOrAbsent() throws {
        XCTAssertNil(try read(MachOFixtures.thin()).slice(at: 0)?.embeddedSignature)
        var short = MachOFixtures.thin(commands: [MachOFixtures.command(0x1D)])
        assertFailure(short, .invalidLoadCommand, .codeSignatureCommand)
        short = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        MachOFixtures.put(0, at: 44, in: &short, order: .littleEndian)
        assertFailure(short, .invalidLength, .signatureRegion)

        var command = Array(short[32..<48])
        MachOFixtures.put(64, at: 8, in: &command, order: .littleEndian)
        MachOFixtures.put(12, at: 12, in: &command, order: .littleEndian)
        let duplicate = MachOFixtures.thin(commands: [command, command], payload: MachOFixtures.superBlob([]))
        assertFailure(duplicate, .invalidLoadCommand, .codeSignatureCommand)
    }

    func testSignatureRangeIsCheckedWithinSlice() {
        var outside = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        MachOFixtures.put(UInt64(UInt32.max), at: 40, in: &outside, order: .littleEndian)
        assertFailure(outside, .invalidOffset, .signatureRegion)
        var hugeSize = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        MachOFixtures.put(UInt64(UInt32.max), at: 44, in: &hugeSize, order: .littleEndian)
        assertFailure(hugeSize, .invalidLength, .signatureRegion)
        var overlap = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        MachOFixtures.put(32, at: 40, in: &overlap, order: .littleEndian)
        assertFailure(overlap, .invalidOffset, .signatureRegion)
    }

    // MARK: - Universal containers

    func testOneAndMultipleSlicesAreInspectedIndependently() throws {
        let first = MachOFixtures.thin(cpu: MachOFixtures.arm64, subtype: 0)
        let second = MachOFixtures.signedThin(MachOFixtures.superBlob([]), cpu: MachOFixtures.x86_64, subtype: 3)
        let one = try read(MachOFixtures.fat([(MachOFixtures.arm64, 0, first)]))
        guard case .universal(let oneContainer) = one.container else { return XCTFail("Expected fat") }
        XCTAssertEqual(oneContainer.magic, .fat32)
        XCTAssertEqual(oneContainer.architectureCount, 1)
        XCTAssertNil(one.slice(at: 1))

        let image = try read(MachOFixtures.fat([
            (MachOFixtures.arm64, 0, first), (MachOFixtures.x86_64, 3, second),
        ]))
        guard case .universal(let universal) = image.container else { return XCTFail("Expected fat") }
        XCTAssertEqual(universal.architectureCount, 2)
        XCTAssertEqual(universal.architectures.map(\.cpu), [.arm64, .x86_64])
        XCTAssertEqual(universal.architectures.map(\.alignmentExponent), [2, 2])
        XCTAssertEqual(image.slice(at: 1)?.header.cpu, .x86_64)
        XCTAssertNil(image.slice(at: 0)?.embeddedSignature)
        XCTAssertEqual(image.slice(at: 1)?.embeddedSignature?.command.dataOffset, 48)
        XCTAssertEqual(image.slice(at: 1)?.embeddedSignature?.command.fileRange.lowerBound,
                       universal.architectures[1].fileRange.lowerBound + 48)
        XCTAssertNil(image.slice(at: -1))
    }

    func testFat64AndSwappedFatRecords() throws {
        let slice = MachOFixtures.thin(wordSize: .bits32, cpu: 12)
        for magic in [MachOUniversalMagic.fat32, .fat64] {
            let input = MachOFixtures.fat([(12, 0, slice)], magic: magic, order: .littleEndian)
            let image = try read(input)
            guard case .universal(let container) = image.container else { return XCTFail("Expected fat") }
            XCTAssertEqual(container.magic, magic)
            XCTAssertEqual(container.byteOrder, .littleEndian)
            XCTAssertEqual(container.slices[0].header.wordSize, .bits32)
            XCTAssertEqual(container.architectures[0].fileRange.count, slice.count)
            XCTAssertEqual(container.architectures[0].reserved, magic == .fat64 ? 0 : nil)
        }
        let big64 = try read(MachOFixtures.fat([(12, 0, slice)], magic: .fat64))
        guard case .universal(let container) = big64.container else { return XCTFail("Expected fat") }
        XCTAssertEqual(container.magic, .fat64)
        XCTAssertEqual(container.byteOrder, .bigEndian)
    }

    func testFatHeaderCountsOffsetsSizesAndAlignmentAreBounded() {
        let slice = MachOFixtures.thin()
        let base = MachOFixtures.fat([(MachOFixtures.arm64, 0, slice)])
        var zero = base
        MachOFixtures.put(0, at: 4, in: &zero)
        assertFailure(zero, .malformedHeader, .architectureTable)
        var many = base
        MachOFixtures.put(UInt64(UInt32.max), at: 4, in: &many)
        assertFailure(many, .resourceLimitExceeded, .architectureTable)
        var truncated = base
        truncated = Array(truncated.prefix(8 + 19))
        assertFailure(truncated, .truncatedInput, .architectureTable)

        var offset = base
        MachOFixtures.put(UInt64(UInt32.max), at: 16, in: &offset)
        assertFailure(offset, .invalidOffset, .architectureSlice, architecture: 0)
        var size = base
        MachOFixtures.put(0, at: 20, in: &size)
        assertFailure(size, .invalidLength, .architectureSlice, architecture: 0)
        MachOFixtures.put(UInt64(UInt32.max), at: 20, in: &size)
        assertFailure(size, .invalidLength, .architectureSlice, architecture: 0)
        var alignment = base
        MachOFixtures.put(UInt64(UInt32.max), at: 24, in: &alignment)
        assertFailure(alignment, .invalidLength, .architectureTable, architecture: 0)
        MachOFixtures.put(5, at: 24, in: &alignment)
        assertFailure(alignment, .invalidOffset, .architectureSlice, architecture: 0)
    }

    func testFat64HugeOffsetsAndOverlappingSlices() {
        let slice = MachOFixtures.thin()
        var huge = MachOFixtures.fat([(MachOFixtures.arm64, 0, slice)], magic: .fat64)
        MachOFixtures.put(UInt64.max, width: 8, at: 16, in: &huge)
        assertFailure(huge, .invalidOffset, .architectureSlice, architecture: 0)

        var overlapping = MachOFixtures.fat([
            (MachOFixtures.arm64, 0, slice), (MachOFixtures.arm64, 0, slice),
        ])
        let firstOffset = overlapping[16..<20]
        overlapping.replaceSubrange(36..<40, with: firstOffset)
        assertFailure(overlapping, .invalidOffset, .architectureSlice, architecture: 1)
    }

    func testFatSliceCannotImpersonateArchitectureOrEscapeItsBoundary() {
        let thin = MachOFixtures.thin()
        var wrongCPU = MachOFixtures.fat([(MachOFixtures.arm64, 0, thin)])
        MachOFixtures.put(UInt64(UInt32(bitPattern: MachOFixtures.x86_64)), at: 8, in: &wrongCPU)
        assertFailure(wrongCPU, .malformedHeader, .architectureSlice, architecture: 0)

        var short = MachOFixtures.fat([(MachOFixtures.arm64, 0, thin)])
        MachOFixtures.put(27, at: 20, in: &short)
        assertFailure(short, .truncatedInput, .header, architecture: 0)

        // The signature's dataoff must not reach a different fat slice even
        // when the bytes exist in the outer file.
        let signed = MachOFixtures.signedThin(MachOFixtures.superBlob([]))
        var otherSlice = MachOFixtures.fat([
            (MachOFixtures.arm64, 0, signed), (MachOFixtures.arm64, 0, thin),
        ])
        let firstSliceStart = 8 + 2 * 20
        MachOFixtures.put(96, at: firstSliceStart + 40, in: &otherSlice, order: .littleEndian)
        assertFailure(otherSlice, .invalidOffset, .signatureRegion, architecture: 0)
    }

    // MARK: - SuperBlob and indexed blobs

    func testSuperBlobAndKnownSlotTypesAreStructuralOnly() throws {
        let entries: [(UInt32, [UInt8])] = [
            (2, MachOFixtures.genericBlob(0xFADE0C01)),
            (5, MachOFixtures.genericBlob(0xFADE7171, payload: [0x41])),
            (7, MachOFixtures.genericBlob(0xFADE7172)),
            (0x10000, MachOFixtures.genericBlob(0xFADE0B01)),
            (0x77, MachOFixtures.genericBlob(0x12345678)),
        ]
        let slice = try XCTUnwrap(try read(MachOFixtures.signedThin(MachOFixtures.superBlob(entries))).slice(at: 0))
        let blob = try XCTUnwrap(slice.embeddedSignature?.superBlob)
        XCTAssertEqual(blob.magic, 0xFADE0CC0)
        XCTAssertEqual(blob.count, 5)
        XCTAssertEqual(blob.entries.map(\.slot), [.requirements, .entitlements,
                                                  .derEntitlements, .cms, .other(0x77)])
        XCTAssertEqual(blob.entries.last?.magic, 0x12345678)
        XCTAssertTrue(blob.entries.allSatisfy { $0.codeDirectory == nil })
    }

    func testEmptySuperBlobHasNoCodeDirectoryAndMakesNoVerificationClaim() throws {
        let blob = try XCTUnwrap(try read(MachOFixtures.signedThin(MachOFixtures.superBlob([])))
            .slice(at: 0)?.embeddedSignature?.superBlob)
        XCTAssertEqual(blob.length, 12)
        XCTAssertTrue(blob.entries.isEmpty)
        let padded = try XCTUnwrap(try read(MachOFixtures.signedThin(
            MachOFixtures.superBlob([]) + [0, 0, 0, 0]
        )).slice(at: 0)?.embeddedSignature)
        XCTAssertEqual(padded.command.dataSize, 16)
        XCTAssertEqual(padded.superBlob.length, 12)
    }

    func testSuperBlobInvalidMagicLengthCountAndIndex() {
        var wrongMagic = MachOFixtures.superBlob([])
        MachOFixtures.put(0xFADE0CC1, at: 0, in: &wrongMagic)
        assertFailure(MachOFixtures.signedThin(wrongMagic), .malformedSuperBlob, .superBlob)
        var short = MachOFixtures.superBlob([])
        MachOFixtures.put(8, at: 4, in: &short)
        assertFailure(MachOFixtures.signedThin(short), .invalidLength, .superBlob)
        assertFailure(MachOFixtures.signedThin(Array(short.prefix(8))), .truncatedInput, .superBlob)
        var count = MachOFixtures.superBlob([])
        MachOFixtures.put(UInt64(UInt32.max), at: 8, in: &count)
        assertFailure(MachOFixtures.signedThin(count), .resourceLimitExceeded, .superBlob)
        MachOFixtures.put(1, at: 8, in: &count)
        assertFailure(MachOFixtures.signedThin(count), .malformedSuperBlob, .superBlob)
        var index = MachOFixtures.superBlob([(0x99, MachOFixtures.genericBlob(0x77777777))])
        MachOFixtures.put(UInt64(UInt32.max), at: 16, in: &index)
        assertFailure(MachOFixtures.signedThin(index), .invalidOffset, .signatureBlob)
        MachOFixtures.put(12, at: 16, in: &index)
        assertFailure(MachOFixtures.signedThin(index), .invalidOffset, .signatureBlob)
        MachOFixtures.put(40, at: 4, in: &index)
        assertFailure(MachOFixtures.signedThin(index), .truncatedInput, .superBlob)
    }

    func testOverlappingDuplicateAndTruncatedIndexedBlobs() {
        let members: [(UInt32, [UInt8])] = [
            (0x77, MachOFixtures.genericBlob(0x77777777)),
            (0x78, MachOFixtures.genericBlob(0x88888888)),
        ]
        var overlap = MachOFixtures.superBlob(members)
        let firstOffset = overlap[16..<20]
        overlap.replaceSubrange(24..<28, with: firstOffset)
        assertFailure(MachOFixtures.signedThin(overlap), .malformedSignatureBlob, .signatureBlob)
        var duplicate = MachOFixtures.superBlob(members)
        MachOFixtures.put(0x77, at: 20, in: &duplicate)
        assertFailure(MachOFixtures.signedThin(duplicate), .malformedSuperBlob, .superBlob)
        var length = MachOFixtures.superBlob([(0x77, MachOFixtures.genericBlob(0x77777777))])
        MachOFixtures.put(UInt64(UInt32.max), at: 24, in: &length) // member length
        assertFailure(MachOFixtures.signedThin(length), .invalidLength, .signatureBlob)
        MachOFixtures.put(0, at: 24, in: &length)
        assertFailure(MachOFixtures.signedThin(length), .invalidLength, .signatureBlob)
        let truncated = Array(MachOFixtures.superBlob([(0x77, [0, 0, 0, 0])]).prefix(24))
        assertFailure(MachOFixtures.signedThin(truncated), .truncatedInput, .signatureBlob)
    }

    func testKnownSlotWithWrongBlobMagicIsNotTrusted() {
        let wrong = MachOFixtures.superBlob([(0x10000, MachOFixtures.genericBlob(0xDEADBEEF))])
        assertFailure(MachOFixtures.signedThin(wrong), .malformedSignatureBlob, .signatureBlob)
    }

    // MARK: - CodeDirectory

    func testVersionedFieldsAndHashRanges() throws {
        for version in [UInt32(0x20001), 0x20100, 0x20200, 0x20300, 0x20400, 0x20500, 0x20600] {
            let parsed = try directory(in: withDirectory(version: version))
            XCTAssertEqual(parsed.version, version)
            XCTAssertEqual(parsed.flags, 0x20000)
            XCTAssertEqual(parsed.identifier, "com.example.test")
            XCTAssertEqual(parsed.teamIdentifier, version >= 0x20200 ? "EXAMPLETEAM" : nil)
            XCTAssertEqual(parsed.hashSize, 32)
            XCTAssertEqual(parsed.hashType, .sha256)
            XCTAssertEqual(parsed.pageSizeExponent, 12)
            XCTAssertEqual(parsed.codeSlotCount, 1)
            XCTAssertEqual(parsed.specialSlotCount, 1)
            XCTAssertEqual(parsed.codeLimit, 48)
            XCTAssertEqual(parsed.codeHashesRange.count, 32)
            XCTAssertEqual(parsed.codeLimit64, version >= 0x20300 ? 0 : nil)
            XCTAssertEqual(parsed.executableSegment?.limit, version >= 0x20400 ? 0x100 : nil)
            XCTAssertEqual(parsed.runtime, version >= 0x20500 ? 0x0001_0000 : nil)
            XCTAssertEqual(parsed.linkage?.dataRange, nil)
        }
    }

    func testAlternateDirectoriesAreNotAssumedToBeFirst() throws {
        let primary = MachOFixtures.codeDirectory()
        let alternate = MachOFixtures.codeDirectory(
            version: 0x20001, hashType: 1, hashSize: 20, team: nil
        )
        let signature = MachOFixtures.superBlob([(0x1000, alternate), (0, primary)])
        let entries = try XCTUnwrap(try read(MachOFixtures.signedThin(signature))
            .slice(at: 0)?.embeddedSignature?.superBlob.entries)
        XCTAssertEqual(entries.map(\.slot), [.alternateCodeDirectory(0), .codeDirectory])
        XCTAssertEqual(entries[0].codeDirectory?.hashType, .sha1)
        XCTAssertEqual(entries[0].codeDirectory?.teamIdentifier, nil)
        XCTAssertEqual(entries[1].codeDirectory?.hashType, .sha256)
        XCTAssertEqual(entries[1].codeDirectory?.teamIdentifier, "EXAMPLETEAM")
    }

    func testSpecialSlotsArePositionsNotProofOfValidContent() throws {
        let directory = try self.directory(in: withDirectory(specialCount: 7))
        XCTAssertEqual(directory.specialSlots.map(\.slotNumber), [-1, -2, -3, -4, -5, -6, -7])
        XCTAssertEqual(directory.specialSlots[0].kind, .infoPlist)
        XCTAssertTrue(directory.specialSlots[0].hasNonzeroBytes)
        XCTAssertEqual(directory.specialSlots[2].kind, .codeResources)
        XCTAssertEqual(directory.specialSlots[5].kind, .representationSpecific)
        XCTAssertEqual(directory.specialSlots[6].kind, .derEntitlements)
        XCTAssertFalse(directory.specialSlots[6].hasNonzeroBytes)
        let extended = try self.directory(in: withDirectory(specialCount: 12))
        XCTAssertEqual(extended.specialSlots[10].kind, .libraryConstraint)
        XCTAssertEqual(extended.specialSlots[11].kind, .other(12))
    }

    func testExtendedCodeLimitScatterPreEncryptAndLinkageAreDelimitable() throws {
        let extended = try directory(in: withDirectory(version: 0x20300,
            codeLimit: UInt32.max, extendedCodeLimit: 48))
        XCTAssertEqual(extended.codeLimit, UInt32.max)
        XCTAssertEqual(extended.codeLimit64, 48)
        XCTAssertEqual(extended.effectiveCodeLimit, 48)

        let scattered = try directory(in: withDirectory(version: 0x20100, scatter: true))
        XCTAssertEqual(scattered.scatter?.records.count, 1)
        XCTAssertEqual(scattered.scatter?.records.first?.pageCount, 1)
        XCTAssertEqual(scattered.scatter?.relativeOffset, 65)

        let extra = try directory(in: withDirectory(version: 0x20600,
            preEncrypt: true, linkage: [0x10, 0x20, 0x30]))
        XCTAssertEqual(extra.preEncryptHashesRange?.count, 32)
        XCTAssertEqual(extra.linkage?.hashType, 2)
        XCTAssertEqual(extra.linkage?.applicationType, 1)
        XCTAssertEqual(extra.linkage?.applicationSubtype, 2)
        XCTAssertEqual(extra.linkage?.dataRange?.count, 3)
    }

    func testKnownHashVariantsAndUnknownHashTypeAreDescriptive() throws {
        XCTAssertEqual(try directory(in: withDirectory(hashType: 3, hashSize: 20)).hashType,
                       .sha256Truncated)
        XCTAssertEqual(try directory(in: withDirectory(hashType: 4, hashSize: 48)).hashType,
                       .sha384)
        XCTAssertEqual(try directory(in: withDirectory(hashType: 99)).hashType, .other(99))
        var unpaged = withDirectory()
        unpaged[directoryStart + 39] = 0
        XCTAssertEqual(try directory(in: unpaged).pageSizeExponent, 0)
        var bad = withDirectory()
        bad[directoryStart + 37] = 1 // SHA-1, but 32-byte slots
        assertFailure(bad, .malformedCodeDirectory, .hashSlots)
    }

    func testUnsupportedAndTruncatedCodeDirectoryVersions() {
        var unsupported = withDirectory()
        MachOFixtures.put(0x20700, at: directoryStart + 8, in: &unsupported)
        assertFailure(unsupported, .unsupportedCodeDirectoryVersion, .codeDirectory, version: 0x20700)
        MachOFixtures.put(0x20000, at: directoryStart + 8, in: &unsupported)
        assertFailure(unsupported, .unsupportedCodeDirectoryVersion, .codeDirectory, version: 0x20000)
        let tooShort = MachOFixtures.superBlob([(0, MachOFixtures.genericBlob(0xFADE0C02, payload: [0, 0, 0, 0]))])
        assertFailure(MachOFixtures.signedThin(tooShort),
                      .unsupportedCodeDirectoryVersion, .codeDirectory, version: 0)
        let noVersion = MachOFixtures.superBlob([(0, MachOFixtures.genericBlob(0xFADE0C02))])
        assertFailure(MachOFixtures.signedThin(noVersion), .truncatedInput, .codeDirectory)
    }

    func testStringOffsetsTerminatorsAndEncodingAreChecked() {
        var identifier = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 20, in: &identifier)
        assertFailure(identifier, .invalidOffset, .identifier)
        var team = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 48, in: &team)
        assertFailure(team, .invalidOffset, .teamIdentifier)
        var overlap = withDirectory()
        let identOffset = MachOFixtures.codeDirectory()[20..<24]
        overlap.replaceSubrange((directoryStart + 48)..<(directoryStart + 52), with: identOffset)
        assertFailure(overlap, .malformedCodeDirectory, .codeDirectory)
        var badEncoding = withDirectory()
        badEncoding[directoryStart + 96] = 0xFF // start of identifier
        assertFailure(badEncoding, .malformedCodeDirectory, .identifier)
        var noTerminator = withDirectory(version: 0x20001, team: nil)
        noTerminator[directoryStart + 44 + "com.example.test".utf8.count] = 0x41
        assertFailure(noTerminator, .malformedCodeDirectory, .identifier)
    }

    func testIdentifierResourceBoundAndTruncatedFixedVersionHeader() {
        let oversized = MachOFixtures.codeDirectory(
            identifier: String(repeating: "x", count: ReadOnlyMachOParser.maximumIdentifierBytes + 1)
        )
        assertFailure(MachOFixtures.signedThin(MachOFixtures.superBlob([(0, oversized)])),
                      .resourceLimitExceeded, .identifier)
        var short = MachOFixtures.genericBlob(0xFADE0C02, payload: [UInt8](repeating: 0, count: 4))
        MachOFixtures.put(0x20500, at: 8, in: &short)
        assertFailure(MachOFixtures.signedThin(MachOFixtures.superBlob([(0, short)])),
                      .truncatedInput, .codeDirectory)
    }

    func testHashMetadataCodeLimitAndTablesAreChecked() {
        var hashSize = withDirectory()
        hashSize[directoryStart + 36] = 0
        assertFailure(hashSize, .malformedCodeDirectory, .hashSlots)
        var pageSize = withDirectory()
        pageSize[directoryStart + 39] = 255
        assertFailure(pageSize, .malformedCodeDirectory, .hashSlots)
        var hashOffset = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 16, in: &hashOffset)
        assertFailure(hashOffset, .invalidOffset, .hashSlots)
        var slots = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 28, in: &slots)
        assertFailure(slots, .invalidLength, .hashSlots)
        var special = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 24, in: &special)
        assertFailure(special, .resourceLimitExceeded, .hashSlots)
        var spare2 = withDirectory()
        MachOFixtures.put(1, at: directoryStart + 40, in: &spare2)
        assertFailure(spare2, .malformedCodeDirectory, .codeDirectory)
        var spare3 = withDirectory()
        MachOFixtures.put(1, at: directoryStart + 52, in: &spare3)
        assertFailure(spare3, .malformedCodeDirectory, .codeDirectory)
        var countMismatch = withDirectory()
        MachOFixtures.put(0, at: directoryStart + 28, in: &countMismatch)
        assertFailure(countMismatch, .malformedCodeDirectory, .hashSlots)
        var limit = withDirectory()
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 32, in: &limit)
        assertFailure(limit, .malformedCodeDirectory, .codeDirectory)
        var extended = withDirectory(version: 0x20300)
        MachOFixtures.put(UInt64.max, width: 8, at: directoryStart + 56, in: &extended)
        assertFailure(extended, .malformedCodeDirectory, .codeDirectory)
        let emptyPaged = MachOFixtures.codeDirectory(codeLimit: 0, codeCount: 0)
        assertFailure(MachOFixtures.signedThin(MachOFixtures.superBlob([(0, emptyPaged)])),
                      .malformedCodeDirectory, .hashSlots)
    }

    func testOptionalRangesCannotPointOutsideOrIntoHashes() throws {
        var scatter = withDirectory(version: 0x20100, scatter: true)
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 44, in: &scatter)
        assertFailure(scatter, .invalidOffset, .scatter)
        var preEncrypt = withDirectory(preEncrypt: true)
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + 92, in: &preEncrypt)
        assertFailure(preEncrypt, .invalidOffset, .preEncryptHashes)
        var linkage = withDirectory(version: 0x20600, linkage: [0x42])
        MachOFixtures.put(0, at: directoryStart + 104, in: &linkage)
        assertFailure(linkage, .invalidLength, .linkage)
        var overlappingHashes = withDirectory(preEncrypt: true)
        let hashOffset = try directory(in: overlappingHashes).hashOffset
        MachOFixtures.put(UInt64(hashOffset), at: directoryStart + 92, in: &overlappingHashes)
        assertFailure(overlappingHashes, .malformedCodeDirectory, .codeDirectory)
        var badScatter = withDirectory(version: 0x20100, scatter: true)
        let offset = try XCTUnwrap(try directory(in: badScatter).scatter?.relativeOffset)
        MachOFixtures.put(UInt64(UInt32.max), at: directoryStart + offset, in: &badScatter)
        assertFailure(badScatter, .malformedCodeDirectory, .scatter)
        var reserved = withDirectory(version: 0x20100, scatter: true)
        MachOFixtures.put(1, width: 8, at: directoryStart + offset + 16, in: &reserved)
        assertFailure(reserved, .malformedCodeDirectory, .scatter)
    }

    func testEveryTruncationOfSmallSignedFixtureFailsWithoutTrap() {
        let fixture = withDirectory()
        for end in 0..<fixture.count {
            do {
                _ = try read(Array(fixture.prefix(end)))
                XCTFail("Truncated at byte \(end) but was accepted")
            } catch is MachOParsingError {
                // Every failure is structured and no pointer outlives a read.
            } catch {
                XCTFail("Unexpected failure type at byte \(end): \(type(of: error))")
            }
        }
    }

    func testDataSubsequenceUsesItsOwnBounds() throws {
        let fixture = withDirectory()
        let container = Data([0xAA, 0xBB, 0xCC] + fixture)
        let subsequence = container.dropFirst(3)
        XCTAssertEqual(try parser.parse(subsequence).slice(at: 0)?.header.cpu, .arm64)
    }
}
