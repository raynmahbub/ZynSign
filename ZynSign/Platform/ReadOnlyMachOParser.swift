import Foundation

/// Bounded, read-only parsing of Mach-O and embedded code-signature records.
/// The reader never loads or executes the image, computes a hash, or evaluates
/// the validity of any signature. Every file-relative offset is resolved
/// inside its containing slice before it can reach the SuperBlob reader.
struct ReadOnlyMachOParser: MachOParsing {
    // Inspection policy, not format limits. No array is allocated from an
    // unbounded count, and the input is already in memory before inspection.
    static let maximumInputBytes = 256 * 1_024 * 1_024
    static let maximumArchitectures = 64
    static let maximumLoadCommands = 4_096
    static let maximumLoadCommandBytes = 1_024 * 1_024
    static let maximumSignatureEntries = SignatureSuperBlob.maximumEntries
    static let maximumSpecialSlots = 64
    static let maximumCodeSlots = 65_536
    static let maximumScatterRecords = 4_096
    static let maximumIdentifierBytes = 4_096

    /// Standalone inspection of exactly one embedded SuperBlob. Unlike a
    /// Mach-O signature region, this input must not contain trailing reserve
    /// bytes. Code limits are checked structurally, but cannot be compared
    /// with a containing executable when none was supplied.
    func parseSuperBlob(_ bytes: Data) throws -> MachOSuperBlob {
        guard bytes.count <= SignatureSuperBlob.maximumSerializedLength else {
            throw MachOParsingError(.resourceLimitExceeded, at: .superBlob)
        }
        return try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let result = try Self.superBlob(
                in: BoundedBinaryReader(bytes: raw), signatureOffset: nil
            )
            guard result.length == bytes.count else {
                throw MachOParsingError(.invalidLength, at: .superBlob)
            }
            return result
        }
    }

    func parse(_ bytes: Data) throws -> MachOImage {
        guard bytes.count <= Self.maximumInputBytes else {
            throw MachOParsingError(.resourceLimitExceeded, at: .input)
        }
        return try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> MachOImage in
            let reader = BoundedBinaryReader(bytes: raw)
            let encoding = try Self.magic(in: reader)
            switch encoding {
            case .thin(let magic, let order):
                return .init(container: .thin(try Self.slice(in: reader, magic: magic, order: order)))
            case .universal(let magic, let order):
                return .init(container: .universal(try Self.universal(in: reader, magic: magic, order: order)))
            }
        }
    }

    enum Encoding {
        case thin(MachOHeaderMagic, MachOByteOrder)
        case universal(MachOUniversalMagic, MachOByteOrder)
    }

    static func magic(in reader: BoundedBinaryReader) throws -> Encoding {
        let raw = try reader.uint32(at: 0, order: .bigEndian, boundary: .magic)
        switch raw {
        case 0xFEEDFACE: return .thin(.mach32, .bigEndian)
        case 0xCEFAEDFE: return .thin(.mach32, .littleEndian)
        case 0xFEEDFACF: return .thin(.mach64, .bigEndian)
        case 0xCFFAEDFE: return .thin(.mach64, .littleEndian)
        case 0xCAFEBABE: return .universal(.fat32, .bigEndian)
        case 0xBEBAFECA: return .universal(.fat32, .littleEndian)
        case 0xCAFEBABF: return .universal(.fat64, .bigEndian)
        case 0xBFBAFECA: return .universal(.fat64, .littleEndian)
        default: throw MachOParsingError(.unsupportedFormat, at: .magic)
        }
    }

    private struct SegmentFormat {
        let is64Bit: Bool
        let commandHeaderLength: Int
        let sectionLength: Int
        let sectionCountOffset: Int
    }

    private struct SegmentFields {
        let virtualMemoryAddress: UInt64
        let virtualMemorySize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
        let fileSizeFieldRange: Range<Int>
    }

    private struct SegmentSections {
        let values: [MachOSection]
        let firstFileBackedOffset: Int?
    }

    /// Reads only the segment facts needed by the append-only mutation
    /// boundary. Each file-backed section is proved to lie inside both its
    /// segment's file range and the containing slice before it can establish
    /// header-padding capacity.
    static func segment(
        in command: BoundedBinaryReader,
        type: UInt32,
        wordSize: MachOWordSize,
        order: MachOByteOrder,
        sliceLength: Int
    ) throws -> MachOSegment {
        let format = try segmentFormat(type: type, wordSize: wordSize, commandCount: command.count)
        let sectionCount = try command.uint32AsInt(
            at: format.sectionCountOffset,
            order: order,
            boundary: .segment,
            ifUnrepresentable: .invalidLength
        )
        try validateSectionTable(in: command, format: format, count: sectionCount)
        let fields = try segmentFields(in: command, format: format, order: order)
        let segmentEnd = try validateSegmentFileRange(fields, sliceLength: sliceLength)
        let sectionData = try readSections(
            in: command,
            format: format,
            count: sectionCount,
            fileOffset: fields.fileOffset,
            segmentEnd: segmentEnd,
            sliceLength: sliceLength,
            order: order
        )
        return MachOSegment(
            commandRange: command.fileRange,
            wordSize: wordSize,
            name: MachOSegmentName(rawBytes: Array(try command.data(at: 8, length: 16, boundary: .segment))),
            fileOffset: fields.fileOffset,
            fileSize: fields.fileSize,
            virtualMemoryAddress: fields.virtualMemoryAddress,
            virtualMemorySize: fields.virtualMemorySize,
            maximumProtection: try command.uint32(at: format.is64Bit ? 56 : 40, order: order, boundary: .segment),
            initialProtection: try command.uint32(at: format.is64Bit ? 60 : 44, order: order, boundary: .segment),
            flags: try command.uint32(at: format.is64Bit ? 68 : 52, order: order, boundary: .segment),
            sections: sectionData.values,
            sectionCount: sectionCount,
            firstFileBackedSectionOffset: sectionData.firstFileBackedOffset,
            fileSizeFieldRange: fields.fileSizeFieldRange
        )
    }

    private static func segmentFormat(
        type: UInt32,
        wordSize: MachOWordSize,
        commandCount: Int
    ) throws -> SegmentFormat {
        let is64Bit = type == MachOLoadCommandType.segment64
        guard (is64Bit && wordSize == .bits64) || (!is64Bit && wordSize == .bits32) else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }
        let headerLength = is64Bit ? 72 : 56
        let sectionLength = is64Bit ? 80 : 68
        guard commandCount >= headerLength else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }
        return SegmentFormat(
            is64Bit: is64Bit,
            commandHeaderLength: headerLength,
            sectionLength: sectionLength,
            sectionCountOffset: is64Bit ? 64 : 48
        )
    }

    private static func validateSectionTable(
        in command: BoundedBinaryReader,
        format: SegmentFormat,
        count: Int
    ) throws {
        let (sectionBytes, sectionBytesOverflow) = count.multipliedReportingOverflow(by: format.sectionLength)
        guard !sectionBytesOverflow else {
            throw MachOParsingError(.invalidLength, at: .segment)
        }
        let (expectedLength, expectedLengthOverflow) = format.commandHeaderLength.addingReportingOverflow(sectionBytes)
        guard !expectedLengthOverflow, expectedLength == command.count else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }
    }

    private static func segmentFields(
        in command: BoundedBinaryReader,
        format: SegmentFormat,
        order: MachOByteOrder
    ) throws -> SegmentFields {
        let virtualMemoryAddress: UInt64
        let virtualMemorySize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
        let fileSizeFieldRange: Range<Int>
        if format.is64Bit {
            virtualMemoryAddress = try command.uint64(at: 24, order: order, boundary: .segment)
            virtualMemorySize = try command.uint64(at: 32, order: order, boundary: .segment)
            fileOffset = try command.uint64(at: 40, order: order, boundary: .segment)
            fileSize = try command.uint64(at: 48, order: order, boundary: .segment)
            fileSizeFieldRange = try command.checkedRange(at: 48, length: 8, boundary: .segment)
        } else {
            virtualMemoryAddress = UInt64(try command.uint32(at: 24, order: order, boundary: .segment))
            virtualMemorySize = UInt64(try command.uint32(at: 28, order: order, boundary: .segment))
            fileOffset = UInt64(try command.uint32(at: 32, order: order, boundary: .segment))
            fileSize = UInt64(try command.uint32(at: 36, order: order, boundary: .segment))
            fileSizeFieldRange = try command.checkedRange(at: 36, length: 4, boundary: .segment)
        }
        return SegmentFields(
            virtualMemoryAddress: virtualMemoryAddress,
            virtualMemorySize: virtualMemorySize,
            fileOffset: fileOffset,
            fileSize: fileSize,
            fileSizeFieldRange: fileSizeFieldRange
        )
    }

    private static func validateSegmentFileRange(_ fields: SegmentFields, sliceLength: Int) throws -> UInt64 {
        let (segmentEnd, overflow) = fields.fileOffset.addingReportingOverflow(fields.fileSize)
        guard !overflow else {
            throw MachOParsingError(.invalidLength, at: .segment)
        }
        if fields.fileSize > 0 {
            guard let offset = Int(exactly: fields.fileOffset), offset <= sliceLength else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let length = Int(exactly: fields.fileSize), length <= sliceLength - offset else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
        }
        return segmentEnd
    }

    private static func readSections(
        in command: BoundedBinaryReader,
        format: SegmentFormat,
        count: Int,
        fileOffset: UInt64,
        segmentEnd: UInt64,
        sliceLength: Int,
        order: MachOByteOrder
    ) throws -> SegmentSections {
        var firstFileBackedOffset: Int?
        var sections: [MachOSection] = []
        sections.reserveCapacity(count)
        for index in 0..<count {
            let position = format.commandHeaderLength + index * format.sectionLength
            let decoded = try readSection(in: command, at: position, format: format, order: order)
            sections.append(decoded.value)
            guard decoded.size == 0 || !decoded.isZeroFill else { continue }
            guard decoded.size > 0 else { continue }
            let (sectionEnd, overflow) = decoded.fileOffset.addingReportingOverflow(decoded.size)
            guard !overflow else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
            guard decoded.fileOffset >= fileOffset, sectionEnd <= segmentEnd else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let offset = Int(exactly: decoded.fileOffset), offset <= sliceLength else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let length = Int(exactly: decoded.size), length <= sliceLength - offset else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
            firstFileBackedOffset = min(firstFileBackedOffset ?? offset, offset)
        }
        return SegmentSections(values: sections, firstFileBackedOffset: firstFileBackedOffset)
    }

    private struct DecodedSection {
        let value: MachOSection
        let fileOffset: UInt64
        let size: UInt64
        let isZeroFill: Bool
    }

    private static func readSection(
        in command: BoundedBinaryReader,
        at position: Int,
        format: SegmentFormat,
        order: MachOByteOrder
    ) throws -> DecodedSection {
        let is64Bit = format.is64Bit
        let size = is64Bit
            ? try command.uint64(at: position + 40, order: order, boundary: .segment)
            : UInt64(try command.uint32(at: position + 36, order: order, boundary: .segment))
        let fileOffset = UInt64(try command.uint32(
            at: position + (is64Bit ? 48 : 40), order: order, boundary: .segment
        ))
        let flags = try command.uint32(at: position + (is64Bit ? 64 : 56), order: order, boundary: .segment)
        let virtualAddress = is64Bit
            ? try command.uint64(at: position + 32, order: order, boundary: .segment)
            : UInt64(try command.uint32(at: position + 32, order: order, boundary: .segment))
        let sectionFields = position + (is64Bit ? 52 : 44)
        let section = MachOSection(
            name: Array(try command.data(at: position, length: 16, boundary: .segment)),
            segmentName: Array(try command.data(at: position + 16, length: 16, boundary: .segment)),
            virtualAddress: virtualAddress,
            size: size,
            fileOffset: fileOffset,
            alignmentExponent: try command.uint32(at: sectionFields, order: order, boundary: .segment),
            relocationOffset: try command.uint32(at: sectionFields + 4, order: order, boundary: .segment),
            relocationCount: try command.uint32(at: sectionFields + 8, order: order, boundary: .segment),
            flags: flags,
            reserved1: try command.uint32(at: sectionFields + 16, order: order, boundary: .segment),
            reserved2: try command.uint32(at: sectionFields + 20, order: order, boundary: .segment),
            reserved3: is64Bit
                ? try command.uint32(at: sectionFields + 24, order: order, boundary: .segment) : nil
        )
        let sectionType = flags & MachOSectionType.mask
        let isZeroFill = sectionType == MachOSectionType.zeroFill ||
            sectionType == MachOSectionType.threadLocalZeroFill
        return DecodedSection(value: section, fileOffset: fileOffset, size: size, isZeroFill: isZeroFill)
    }

    private struct IndexedBlob {
        let slotNumber: UInt32
        let relativeOffset: Int
        let magic: UInt32
        let fileRange: Range<Int>
        let length: Int
    }

    static func superBlob(
        in signature: BoundedBinaryReader,
        signatureOffset: Int?
    ) throws -> MachOSuperBlob {
        _ = try signature.checkedRange(at: 0, length: 12, boundary: .superBlob)
        let magic = try signature.uint32(at: 0, order: .bigEndian, boundary: .superBlob)
        guard magic == 0xFADE0CC0 else {
            throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
        }
        let length = try signature.uint32AsInt(
            at: 4,
            order: .bigEndian,
            boundary: .superBlob,
            ifUnrepresentable: .invalidLength
        )
        let count = try signature.uint32AsInt(at: 8, order: .bigEndian, boundary: .superBlob)
        guard length >= 12 else { throw MachOParsingError(.invalidLength, at: .superBlob) }
        guard count <= maximumSignatureEntries else {
            throw MachOParsingError(.resourceLimitExceeded, at: .superBlob)
        }
        let blob = try signature.view(at: 0, length: length, boundary: .superBlob)
        let indexed = try indexedSignatureBlobs(in: blob, count: count, length: length)
        let entries = try signatureEntries(in: blob, indexed: indexed, signatureOffset: signatureOffset)
        return MachOSuperBlob(magic: magic, fileRange: blob.fileRange, entries: entries)
    }

    private static func indexedSignatureBlobs(
        in blob: BoundedBinaryReader,
        count: Int,
        length: Int
    ) throws -> [IndexedBlob] {
        // Both operands are bounded (count <= 128), so this table cannot overflow.
        let tableEnd = 12 + count * 8
        guard tableEnd <= length else {
            throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
        }
        var indexed: [IndexedBlob] = []
        indexed.reserveCapacity(count)
        var seenSlots: Set<UInt32> = []
        for index in 0..<count {
            let item = try indexedSignatureBlob(
                at: index,
                in: blob,
                tableEnd: tableEnd,
                seenSlots: &seenSlots
            )
            guard !indexed.contains(where: { $0.fileRange.overlaps(item.fileRange) }) else {
                throw MachOParsingError(.malformedSignatureBlob, at: .signatureBlob)
            }
            indexed.append(item)
        }
        return indexed
    }

    private static func indexedSignatureBlob(
        at index: Int,
        in blob: BoundedBinaryReader,
        tableEnd: Int,
        seenSlots: inout Set<UInt32>
    ) throws -> IndexedBlob {
        let position = 12 + index * 8
        let slot = try blob.uint32(at: position, order: .bigEndian, boundary: .superBlob)
        let offset = try blob.uint32AsInt(
            at: position + 4,
            order: .bigEndian,
            boundary: .superBlob,
            ifUnrepresentable: .invalidOffset
        )
        guard seenSlots.insert(slot).inserted else {
            throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
        }
        guard offset >= tableEnd else {
            throw MachOParsingError(.invalidOffset, at: .signatureBlob)
        }
        let header = try blob.view(at: offset, length: 8, boundary: .signatureBlob)
        let typeMagic = try header.uint32(at: 0, order: .bigEndian, boundary: .signatureBlob)
        let blobLength = try header.uint32AsInt(
            at: 4,
            order: .bigEndian,
            boundary: .signatureBlob,
            ifUnrepresentable: .invalidLength
        )
        guard blobLength >= 8 else {
            throw MachOParsingError(.invalidLength, at: .signatureBlob)
        }
        let range = try blob.checkedRange(
            at: offset,
            length: blobLength,
            boundary: .signatureBlob,
            ifTooLong: .invalidLength
        )
        return IndexedBlob(
            slotNumber: slot,
            relativeOffset: offset,
            magic: typeMagic,
            fileRange: range,
            length: blobLength
        )
    }

    private static func signatureEntries(
        in blob: BoundedBinaryReader,
        indexed: [IndexedBlob],
        signatureOffset: Int?
    ) throws -> [MachOSignatureEntry] {
        var entries: [MachOSignatureEntry] = []
        entries.reserveCapacity(indexed.count)
        for item in indexed {
            let slot = CodeSignatureBlobType(rawValue: item.slotNumber)
            try validateSignatureBlobMagic(item, slot: slot)
            let directory = try codeDirectoryIfPresent(
                item,
                slot: slot,
                in: blob,
                signatureOffset: signatureOffset
            )
            entries.append(MachOSignatureEntry(
                slotNumber: item.slotNumber,
                slot: slot,
                relativeOffset: item.relativeOffset,
                magic: item.magic,
                fileRange: item.fileRange,
                codeDirectory: directory
            ))
        }
        return entries
    }

    private static func validateSignatureBlobMagic(
        _ item: IndexedBlob,
        slot: CodeSignatureBlobType
    ) throws {
        guard let expectedMagic = slot.expectedMagic, item.magic != expectedMagic else { return }
        throw MachOParsingError(.malformedSignatureBlob, at: .signatureBlob)
    }

    private static func codeDirectoryIfPresent(
        _ item: IndexedBlob,
        slot: CodeSignatureBlobType,
        in blob: BoundedBinaryReader,
        signatureOffset: Int?
    ) throws -> MachOCodeDirectory? {
        switch slot {
        case .codeDirectory, .alternateCodeDirectory:
            let member = try blob.view(
                at: item.relativeOffset,
                length: item.length,
                boundary: .codeDirectory
            )
            return try codeDirectory(in: member, signatureOffset: signatureOffset)
        default:
            return nil
        }
    }

}
