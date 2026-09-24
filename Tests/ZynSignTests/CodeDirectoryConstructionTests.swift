import Foundation
import XCTest
@testable import ZynSign

/// Independent construction and page-hash vectors for the supported
/// CodeDirectory subset. The parser is used only for a separate structural
/// round-trip assertion; page digest expectations below are fixed vectors.
final class CodeDirectoryConstructionTests: XCTestCase {
    private let digest = CryptoKitMessageDigest()

    private func identifier(_ value: String = "com.example.test") throws -> CodeDirectoryIdentifier {
        try CodeDirectoryIdentifier(rawValue: value)
    }

    private func team(_ value: String = "EXAMPLETEAM") throws -> CodeDirectoryTeamIdentifier {
        try CodeDirectoryTeamIdentifier(rawValue: value)
    }

    private func sha256Configuration() throws -> CodeDirectoryHashConfiguration {
        try CodeDirectoryHashConfiguration(hashType: .sha256)
    }

    private func hex(_ value: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex) ?? value.endIndex
            guard next > index, let byte = UInt8(String(value[index..<next]), radix: 16) else {
                return Data()
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func makeRequest(
        version: CodeDirectoryVersion = .v20200,
        flags: CodeDirectoryFlags = [],
        platform: UInt8 = 0,
        codeLimit: UInt64,
        pageSize: CodeDirectoryPageSize,
        hashConfiguration: CodeDirectoryHashConfiguration? = nil,
        specialSlots: [CodeDirectorySpecialSlot] = []
    ) throws -> CodeDirectoryConstructionRequest {
        let configuration: CodeDirectoryHashConfiguration
        if let hashConfiguration {
            configuration = hashConfiguration
        } else {
            configuration = try sha256Configuration()
        }
        let teamIdentifier: CodeDirectoryTeamIdentifier?
        if version.supportsTeamIdentifier {
            teamIdentifier = try team()
        } else {
            teamIdentifier = nil
        }
        return CodeDirectoryConstructionRequest(
            version: version,
            flags: flags,
            identifier: try identifier(),
            teamIdentifier: teamIdentifier,
            platform: platform,
            hashConfiguration: configuration,
            pageSize: pageSize,
            codeLimit: codeLimit,
            specialSlots: specialSlots
        )
    }

    private func constructed(
        _ request: CodeDirectoryConstructionRequest,
        code: Data
    ) throws -> CodeDirectory {
        try CodeDirectoryConstructor(messageDigest: digest).construct(request, code: code)
    }

    private func parsedDirectory(from serialization: CodeDirectorySerialization) throws -> MachOCodeDirectory {
        let signature = MachOFixtures.superBlob([(0, Array(serialization.bytes))])
        let image = try ReadOnlyMachOParser().parse(Data(MachOFixtures.signedThin(signature)))
        return try XCTUnwrap(image.slice(at: 0)?.embeddedSignature?.superBlob.entries.first?.codeDirectory)
    }

    private func assertCodeDirectoryError(
        _ operation: () throws -> Void,
        equals expected: CodeDirectoryError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? CodeDirectoryError, expected, file: file, line: line)
        }
    }

    // MARK: - Format and hashing configuration

    func testSupportedVersionsAndHashConfigurationsAreExplicit() throws {
        XCTAssertEqual(CodeDirectoryVersion(rawValue: 0x20001), .v20001)
        XCTAssertEqual(CodeDirectoryVersion(rawValue: 0x20200), .v20200)
        XCTAssertEqual(CodeDirectoryVersion(rawValue: 0x20500), .unsupported(0x20500))
        XCTAssertEqual(CodeDirectoryVersion.v20001.headerLength, 44)
        XCTAssertEqual(CodeDirectoryVersion.v20200.headerLength, 52)

        let sha1 = try CodeDirectoryHashConfiguration(hashType: .sha1)
        XCTAssertEqual(sha1.digestAlgorithm, .sha1)
        XCTAssertEqual(sha1.hashSize, 20)
        let truncated = try CodeDirectoryHashConfiguration(hashType: .sha256Truncated)
        XCTAssertEqual(truncated.digestAlgorithm, .sha256)
        XCTAssertEqual(truncated.digestSize, 32)
        XCTAssertEqual(truncated.hashSize, 20)
        let sha384 = try CodeDirectoryHashConfiguration(hashType: .sha384)
        XCTAssertEqual(sha384.digestAlgorithm, .sha384)
        XCTAssertEqual(sha384.hashSize, 48)
        assertCodeDirectoryError(
            { _ = try CodeDirectoryHashConfiguration(hashType: .unsupported(99)) },
            equals: .invalidHashType(99)
        )
        assertCodeDirectoryError(
            { _ = try CodeDirectoryHashConfiguration(hashType: .sha256, hashSize: 20) },
            equals: .invalidHashSize(expected: 32, actual: 20)
        )
        assertCodeDirectoryError(
            { _ = try CodeDirectoryHashConfiguration(digestAlgorithm: .sha512) },
            equals: .unsupportedDigestAlgorithm(.sha512)
        )
    }

    func testPageSizeIsExponentEncodedAndRejectsNonPowerOfTwoValues() throws {
        XCTAssertEqual(try CodeDirectoryPageSize(exponent: 0), .unpaged)
        let fourKiB = try CodeDirectoryPageSize(bytes: 4_096)
        XCTAssertEqual(fourKiB, .exponent(12))
        XCTAssertEqual(fourKiB.exponent, 12)
        XCTAssertEqual(fourKiB.byteCount, 4_096)
        assertCodeDirectoryError(
            { _ = try CodeDirectoryPageSize(bytes: 3_000) },
            equals: .nonPowerOfTwoPageSize(3_000)
        )
        assertCodeDirectoryError(
            { _ = try CodeDirectoryPageSize(exponent: 31) },
            equals: .invalidPageSize(31)
        )
    }

    // MARK: - Independent page-hash vectors

    func testIndependentSHA256PageVectorsCoverCompleteAndPartialPages() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let request = try makeRequest(codeLimit: 9, pageSize: pageSize)
        let directory = try constructed(request, code: Data("abcdefghij".utf8))

        XCTAssertEqual(directory.codeSlots.map(\.index), [0, 1, 2])
        XCTAssertEqual(
            directory.codeSlots.map(\.hash),
            [
                hex("88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"),
                hex("e5e088a0b66163a0a26a5e053d2a4496dc16ab6e0e3dd1adf2d16aa84a078c9d"),
                hex("de7d1b721a1e0632b7cf04edf5032c8ecffa9f9a08492152b926f1a5a7e765d7")
            ]
        )
    }

    func testIndependentPartialPageVectorUsesOnlyCodeLimitBytes() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let request = try makeRequest(codeLimit: 2, pageSize: pageSize)
        let directory = try constructed(request, code: Data("ij-and-unhashed".utf8))
        XCTAssertEqual(directory.codeSlots.count, 1)
        XCTAssertEqual(
            directory.codeSlots[0].hash,
            hex("c9df9c3f2963b19b9b95f58c4d33b053fa9f8586dd6ee04126e52a868f882108")
        )
    }

    func testEmptyAndPageBoundaryCodeLimitsProduceExactSlotCounts() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let empty = try constructed(
            makeRequest(codeLimit: 0, pageSize: .unpaged),
            code: Data([0xAA, 0xBB])
        )
        XCTAssertTrue(empty.codeSlots.isEmpty)

        let boundary = try constructed(
            makeRequest(codeLimit: 8, pageSize: pageSize),
            code: Data(repeating: 0x61, count: 8)
        )
        XCTAssertEqual(boundary.codeSlots.count, 2)
        XCTAssertEqual(
            boundary.codeSlots.map(\.hash),
            [
                hex("61be55a8e2f6b4e172338bddf184d6dbee29c98853e0a0485ecee7f27b9af0b4"),
                hex("61be55a8e2f6b4e172338bddf184d6dbee29c98853e0a0485ecee7f27b9af0b4")
            ]
        )
    }

    func testTruncatedSHA256AndSHA384HashConfigurationsProduceExpectedBytes() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let truncated = try constructed(
            makeRequest(
                codeLimit: 3,
                pageSize: pageSize,
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256Truncated)
            ),
            code: Data("abc".utf8)
        )
        XCTAssertEqual(
            truncated.codeSlots[0].hash,
            hex("ba7816bf8f01cfea414140de5dae2223b00361a3")
        )

        let sha384 = try constructed(
            makeRequest(
                codeLimit: 3,
                pageSize: pageSize,
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha384)
            ),
            code: Data("abc".utf8)
        )
        XCTAssertEqual(
            sha384.codeSlots[0].hash,
            hex("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                + "8086072ba1e7cc2358baeca134c825a7")
        )
    }

    func testPageHasherRejectsCodeLimitOutsideAvailableBytes() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        assertCodeDirectoryError(
            {
                _ = try constructed(
                    makeRequest(codeLimit: 3, pageSize: pageSize),
                    code: Data([0x01, 0x02])
                )
            },
            equals: .codeLimitExceedsAvailableBytes
        )
    }

    func testUnpagedCodeLimitUsesOneWholeRangeHash() throws {
        let directory = try constructed(
            makeRequest(codeLimit: 3, pageSize: .unpaged),
            code: Data("abcdef".utf8)
        )
        XCTAssertEqual(directory.codeSlots.count, 1)
        XCTAssertEqual(
            directory.codeSlots[0].hash,
            hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        )
    }

    // MARK: - Construction, special slots, and deterministic serialization

    func testSpecialSlotsAreExplicitNegativeIndicesWithZeroPlaceholders() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let hashConfiguration = try sha256Configuration()
        let specialSlots = [
            CodeDirectorySpecialSlot(index: 1, hash: Data(repeating: 0x11, count: 32)),
            CodeDirectorySpecialSlot(index: 2),
            CodeDirectorySpecialSlot(index: 3, hash: Data(repeating: 0x33, count: 32))
        ]
        let directory = try constructed(
            makeRequest(
                codeLimit: 0,
                pageSize: .unpaged,
                hashConfiguration: hashConfiguration,
                specialSlots: specialSlots
            ),
            code: Data()
        )
        XCTAssertEqual(directory.specialSlots.compactMap(\.negativeIndex), [-1, -2, -3])
        XCTAssertEqual(directory.specialSlots[0].kind, .infoPlist)
        XCTAssertEqual(directory.specialSlots[2].kind, .codeResources)

        let serialization = try directory.serialize()
        let layout = serialization.layout
        XCTAssertEqual(
            serialization.bytes.subdata(in: layout.specialHashesOffset..<(layout.specialHashesOffset + 32)),
            Data(repeating: 0x33, count: 32)
        )
        XCTAssertEqual(
            serialization.bytes.subdata(in: (layout.specialHashesOffset + 32)..<(layout.specialHashesOffset + 64)),
            Data(repeating: 0, count: 32)
        )
        XCTAssertEqual(
            serialization.bytes.subdata(in: (layout.specialHashesOffset + 64)..<layout.hashOffset),
            Data(repeating: 0x11, count: 32)
        )
    }

    func testEarliestSupportedVersionOmitsTeamIdentifierField() throws {
        let request = try makeRequest(
            version: .v20001,
            codeLimit: 0,
            pageSize: .unpaged
        )
        let directory = try constructed(request, code: Data())
        let serialization = try directory.serialize()
        XCTAssertEqual(serialization.layout.headerLength, 44)
        XCTAssertNil(serialization.layout.teamIdentifierOffset)
        let parsed = try parsedDirectory(from: serialization)
        XCTAssertEqual(parsed.version, 0x20001)
        XCTAssertNil(parsed.teamIdentifier)
    }

    func testSerializationIsDeterministicAndUsesBigEndianHeaderAndOffsets() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let directory = try constructed(
            makeRequest(codeLimit: 3, pageSize: pageSize),
            code: Data("abc".utf8)
        )
        let first = try directory.serialize()
        let second = try directory.serialize()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.layout.magic, CodeDirectory.magic)
        XCTAssertEqual(first.layout.headerLength, 52)
        XCTAssertEqual(first.bytes.subdata(in: 0..<4), Data([0xFA, 0xDE, 0x0C, 0x02]))
        XCTAssertEqual(first.bytes.subdata(in: 8..<12), Data([0x00, 0x02, 0x02, 0x00]))
        XCTAssertEqual(first.bytes.count, first.layout.length)
        XCTAssertEqual(first.layout.codeSlotCount, 1)
        XCTAssertEqual(first.layout.specialSlotCount, 0)
        try first.validate()
    }

    func testSerializedDirectoryParsesBackToEquivalentFieldsAndHashes() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let specialSlots = [
            CodeDirectorySpecialSlot(index: 1, hash: Data(repeating: 0x11, count: 32)),
            CodeDirectorySpecialSlot(index: 2)
        ]
        let directory = try constructed(
            makeRequest(
                flags: CodeDirectoryFlags(rawValue: 0x10000),
                platform: 2,
                codeLimit: 9,
                pageSize: pageSize,
                specialSlots: specialSlots
            ),
            code: Data("abcdefghij".utf8)
        )
        let serialization = try directory.serialize()
        let parsed = try parsedDirectory(from: serialization)

        XCTAssertEqual(parsed.version, directory.version.rawValue)
        XCTAssertEqual(parsed.flags, directory.flags.rawValue)
        XCTAssertEqual(parsed.platform, directory.platform)
        XCTAssertEqual(parsed.identifier, directory.identifier.rawValue)
        XCTAssertEqual(parsed.teamIdentifier, directory.teamIdentifier?.rawValue)
        XCTAssertEqual(parsed.hashType, .sha256)
        XCTAssertEqual(parsed.hashSize, directory.hashConfiguration.hashSize)
        XCTAssertEqual(parsed.pageSizeExponent, directory.pageSize.exponent)
        XCTAssertEqual(parsed.effectiveCodeLimit, directory.codeLimit)
        XCTAssertEqual(parsed.codeSlotCount, directory.codeSlots.count)
        XCTAssertEqual(parsed.specialSlotCount, directory.specialSlots.count)
        XCTAssertEqual(parsed.hashOffset, serialization.layout.hashOffset)
        XCTAssertEqual(parsed.codeHashes, directory.codeSlots.map(\.hash))
        for parsedSlot in parsed.specialSlots {
            let source = directory.specialSlots[abs(parsedSlot.slotNumber) - 1]
            let expected = source.hash ?? Data(repeating: 0, count: directory.hashConfiguration.hashSize)
            XCTAssertEqual(parsedSlot.hash, expected)
        }
    }

    // MARK: - Structural and malformed-input failures

    func testConstructionRejectsUnsupportedFeaturesAndInconsistentSlots() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let config = try sha256Configuration()
        let id = try identifier()
        let slots = [CodeDirectoryCodeSlot(index: 0, hash: Data(repeating: 0, count: 32))]
        assertCodeDirectoryError(
            {
                _ = try CodeDirectory(
                    version: .v20001,
                    identifier: id,
                    teamIdentifier: try team(),
                    hashConfiguration: config,
                    pageSize: pageSize,
                    codeLimit: 0,
                    codeSlots: []
                )
            },
            equals: .unsupportedFeature(.teamIdentifier)
        )
        assertCodeDirectoryError(
            {
                _ = try CodeDirectory(
                    version: .unsupported(0x20500),
                    identifier: id,
                    hashConfiguration: config,
                    pageSize: pageSize,
                    codeLimit: 0,
                    codeSlots: []
                )
            },
            equals: .unsupportedVersion(0x20500)
        )
        assertCodeDirectoryError(
            {
                _ = try CodeDirectory(
                    version: .v20200,
                    identifier: id,
                    hashConfiguration: config,
                    pageSize: pageSize,
                    codeLimit: 4,
                    codeSlots: []
                )
            },
            equals: .invalidPageCount
        )
        assertCodeDirectoryError(
            {
                _ = try CodeDirectory(
                    version: .v20200,
                    identifier: id,
                    hashConfiguration: config,
                    pageSize: pageSize,
                    codeLimit: 0,
                    specialSlots: [CodeDirectorySpecialSlot(index: 2)],
                    codeSlots: slots
                )
            },
            equals: .invalidSlotIndex
        )
        assertCodeDirectoryError(
            {
                _ = try CodeDirectory(
                    version: .v20200,
                    identifier: id,
                    hashConfiguration: config,
                    pageSize: pageSize,
                    codeLimit: UInt64(UInt32.max) + 1,
                    codeSlots: []
                )
            },
            equals: .invalidCodeLimit
        )
    }

    func testStringAndHashRepresentationsRejectUnsafeValues() throws {
        assertCodeDirectoryError(
            { _ = try CodeDirectoryIdentifier(rawValue: "") },
            equals: .invalidIdentifier
        )
        assertCodeDirectoryError(
            { _ = try CodeDirectoryIdentifier(rawValue: "bad\0identifier") },
            equals: .invalidIdentifier
        )
        assertCodeDirectoryError(
            { _ = try CodeDirectoryTeamIdentifier(rawValue: "") },
            equals: .invalidTeamIdentifier
        )
    }

    func testBinaryWriterRefusesNarrowingAndLengthOverflow() {
        var writer = CheckedBinaryWriter(maximumLength: 3)
        XCTAssertThrowsError(try writer.appendUInt32BigEndian(1)) { error in
            XCTAssertEqual(error as? CodeDirectoryError, .resourceLimitExceeded)
        }
        XCTAssertEqual(writer.count, 0)
        XCTAssertThrowsError(try writer.appendData(Data(repeating: 0, count: 4))) { error in
            XCTAssertEqual(error as? CodeDirectoryError, .resourceLimitExceeded)
        }
        XCTAssertEqual(writer.count, 0)
    }

    func testMalformedSerializedBytesStillUseParserValidation() throws {
        let pageSize = try CodeDirectoryPageSize(bytes: 4)
        let directory = try constructed(
            makeRequest(codeLimit: 3, pageSize: pageSize),
            code: Data("abc".utf8)
        )
        let serialization = try directory.serialize()
        var bytes = MachOFixtures.signedThin(
            MachOFixtures.superBlob([(0, Array(serialization.bytes))])
        )
        // The CodeDirectory member begins at the fixed Mach-O header, command,
        // and SuperBlob index: this changes its member magic independently of
        // the constructor's fixed magic.
        bytes[68] = 0
        XCTAssertThrowsError(try ReadOnlyMachOParser().parse(Data(bytes))) { error in
            let parsed = error as? MachOParsingError
            XCTAssertEqual(parsed?.reason, .malformedSignatureBlob)
            XCTAssertEqual(parsed?.boundary, .signatureBlob)
        }
    }
}
