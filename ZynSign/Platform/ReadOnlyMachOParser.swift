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

    private enum Encoding {
        case thin(MachOHeaderMagic, MachOByteOrder)
        case universal(MachOUniversalMagic, MachOByteOrder)
    }

    private static func magic(in reader: BoundedBinaryReader) throws -> Encoding {
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

    private static func universal(
        in reader: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder
    ) throws -> MachOUniversal {
        let rawCount = try reader.uint32(at: 4, order: order, boundary: .architectureTable)
        guard let count = Int(exactly: rawCount), count > 0 else {
            throw MachOParsingError(.malformedHeader, at: .architectureTable)
        }
        guard count <= maximumArchitectures else {
            throw MachOParsingError(.resourceLimitExceeded, at: .architectureTable)
        }
        // count is bounded above, so neither this product nor the addition
        // can overflow Int. A short table remains a truncated-input failure.
        let recordSize = magic == .fat64 ? 32 : 20
        let tableEnd = 8 + count * recordSize
        let table = try reader.view(at: 8, length: count * recordSize, boundary: .architectureTable)

        var architectures: [MachOArchitecture] = []
        architectures.reserveCapacity(count)
        for index in 0..<count {
            do {
                let position = index * recordSize
                let cpu = MachOCPU(rawValue: try table.int32(at: position, order: order, boundary: .architectureTable))
                let subtype = try table.int32(at: position + 4, order: order, boundary: .architectureTable)
                let rawOffset: UInt64
                let rawSize: UInt64
                let exponent: UInt32
                let reserved: UInt32?
                if magic == .fat64 {
                    rawOffset = try table.uint64(at: position + 8, order: order, boundary: .architectureTable)
                    rawSize = try table.uint64(at: position + 16, order: order, boundary: .architectureTable)
                    exponent = try table.uint32(at: position + 24, order: order, boundary: .architectureTable)
                    reserved = try table.uint32(at: position + 28, order: order, boundary: .architectureTable)
                } else {
                    rawOffset = UInt64(try table.uint32(at: position + 8, order: order, boundary: .architectureTable))
                    rawSize = UInt64(try table.uint32(at: position + 12, order: order, boundary: .architectureTable))
                    exponent = try table.uint32(at: position + 16, order: order, boundary: .architectureTable)
                    reserved = nil
                }
                guard let offset = Int(exactly: rawOffset) else {
                    throw MachOParsingError(.invalidOffset, at: .architectureSlice)
                }
                guard let size = Int(exactly: rawSize), size > 0 else {
                    throw MachOParsingError(.invalidLength, at: .architectureSlice)
                }
                // A larger exponent cannot describe a slice within the input
                // bound. Limiting the shift is also independent of word size.
                guard exponent <= 30 else {
                    throw MachOParsingError(.invalidLength, at: .architectureTable)
                }
                let alignment = 1 << Int(exponent)
                guard offset >= tableEnd, offset % alignment == 0 else {
                    throw MachOParsingError(.invalidOffset, at: .architectureSlice)
                }
                let range = try reader.checkedRange(
                    at: offset, length: size, boundary: .architectureSlice, ifTooLong: .invalidLength
                )
                guard !architectures.contains(where: { $0.fileRange.overlaps(range) }) else {
                    throw MachOParsingError(.invalidOffset, at: .architectureSlice)
                }
                architectures.append(.init(
                    cpu: cpu, cpuSubtype: subtype, fileRange: range,
                    alignmentExponent: exponent, reserved: reserved
                ))
            } catch let error as MachOParsingError {
                throw error.inArchitecture(index)
            }
        }

        var slices: [MachOSlice] = []
        slices.reserveCapacity(count)
        for (index, architecture) in architectures.enumerated() {
            do {
                let readerForSlice = try reader.view(
                    at: architecture.fileRange.lowerBound,
                    length: architecture.fileRange.count,
                    boundary: .architectureSlice
                )
                guard case .thin(let sliceMagic, let sliceOrder) = try Self.magic(in: readerForSlice) else {
                    throw MachOParsingError(.unsupportedFormat, at: .architectureSlice)
                }
                let parsed = try slice(in: readerForSlice, magic: sliceMagic, order: sliceOrder)
                guard parsed.header.cpu == architecture.cpu,
                      parsed.header.cpuSubtype == architecture.cpuSubtype else {
                    throw MachOParsingError(.malformedHeader, at: .architectureSlice)
                }
                slices.append(parsed)
            } catch let error as MachOParsingError {
                throw error.inArchitecture(index)
            }
        }
        return MachOUniversal(magic: magic, byteOrder: order, architectures: architectures, slices: slices)
    }

    private static func slice(
        in reader: BoundedBinaryReader,
        magic: MachOHeaderMagic,
        order: MachOByteOrder
    ) throws -> MachOSlice {
        let headerSize = magic == .mach64 ? 32 : 28
        _ = try reader.checkedRange(at: 0, length: headerSize, boundary: .header)
        let rawCount = try reader.uint32(at: 16, order: order, boundary: .header)
        let rawSize = try reader.uint32(at: 20, order: order, boundary: .header)
        guard let commandCount = Int(exactly: rawCount),
              let commandsSize = Int(exactly: rawSize) else {
            throw MachOParsingError(.malformedHeader, at: .header)
        }
        guard commandCount <= maximumLoadCommands, commandsSize <= maximumLoadCommandBytes else {
            throw MachOParsingError(.resourceLimitExceeded, at: .loadCommands)
        }
        let alignment = magic == .mach64 ? 8 : 4
        guard commandsSize % alignment == 0,
              commandsSize >= commandCount * 8,
              (commandCount != 0 || commandsSize == 0) else {
            throw MachOParsingError(.malformedHeader, at: .header)
        }
        let header = MachOHeader(
            magic: magic, byteOrder: order,
            cpu: MachOCPU(rawValue: try reader.int32(at: 4, order: order, boundary: .header)),
            cpuSubtype: try reader.int32(at: 8, order: order, boundary: .header),
            fileType: try reader.uint32(at: 12, order: order, boundary: .header),
            loadCommandCount: commandCount, loadCommandsSize: commandsSize,
            flags: try reader.uint32(at: 24, order: order, boundary: .header),
            reserved: magic == .mach64 ? try reader.uint32(at: 28, order: order, boundary: .header) : nil
        )
        let commands = try reader.view(at: headerSize, length: commandsSize, boundary: .loadCommands)
        var loadCommands: [MachOLoadCommand] = []
        loadCommands.reserveCapacity(commandCount)
        var segments: [MachOSegment] = []
        segments.reserveCapacity(commandCount)
        var signatureCommand: MachOCodeSignatureCommand?
        var cursor = 0
        for _ in 0..<commandCount {
            _ = try commands.checkedRange(at: cursor, length: 8, boundary: .loadCommands)
            let type = try commands.uint32(at: cursor, order: order, boundary: .loadCommands)
            let rawCommandSize = try commands.uint32(at: cursor + 4, order: order, boundary: .loadCommands)
            guard let size = Int(exactly: rawCommandSize), size >= 8,
                  size % alignment == 0, size <= commands.count - cursor else {
                throw MachOParsingError(.invalidLoadCommand, at: .loadCommands)
            }
            let commandRange = try commands.checkedRange(at: cursor, length: size, boundary: .loadCommands)
            loadCommands.append(MachOLoadCommand(type: type, fileRange: commandRange))
            if type == MachOLoadCommandType.segment || type == MachOLoadCommandType.segment64 {
                let command = try commands.view(at: cursor, length: size, boundary: .segment)
                segments.append(try segment(
                    in: command, type: type, wordSize: header.wordSize,
                    order: order, sliceLength: reader.count
                ))
            }
            if type == MachOLoadCommandType.codeSignature {
                guard signatureCommand == nil, size == 16 else {
                    throw MachOParsingError(.invalidLoadCommand, at: .codeSignatureCommand)
                }
                let offset = try commands.uint32AsInt(
                    at: cursor + 8, order: order, boundary: .codeSignatureCommand, ifUnrepresentable: .invalidOffset
                )
                let length = try commands.uint32AsInt(
                    at: cursor + 12, order: order, boundary: .codeSignatureCommand, ifUnrepresentable: .invalidLength
                )
                guard length > 0 else {
                    throw MachOParsingError(.invalidLength, at: .signatureRegion)
                }
                // The signature is separate from the header and commands.
                // Offset and size are relative to this slice, even in a fat file.
                guard offset >= headerSize + commandsSize else {
                    throw MachOParsingError(.invalidOffset, at: .signatureRegion)
                }
                let region = try reader.checkedRange(
                    at: offset, length: length, boundary: .signatureRegion, ifTooLong: .invalidLength
                )
                signatureCommand = MachOCodeSignatureCommand(
                    commandRange: commandRange, dataOffset: offset, dataSize: length, fileRange: region
                )
            }
            cursor += size  // size <= commands.count - cursor
        }
        guard cursor == commands.count else {
            throw MachOParsingError(.invalidLoadCommand, at: .loadCommands)
        }
        let signature: MachOEmbeddedSignature?
        if let command = signatureCommand {
            let region = try reader.view(
                at: command.dataOffset, length: command.dataSize, boundary: .signatureRegion
            )
            signature = MachOEmbeddedSignature(
                command: command,
                superBlob: try superBlob(in: region, signatureOffset: command.dataOffset)
            )
        } else {
            signature = nil
        }
        let firstFileBackedContentOffset = segments.compactMap { segment -> Int? in
            if let sectionOffset = segment.firstFileBackedSectionOffset {
                return sectionOffset
            }
            guard segment.sectionCount == 0,
                  segment.fileOffset > 0,
                  segment.fileSize > 0 else {
                return nil
            }
            return Int(exactly: segment.fileOffset)
        }.min()
        return MachOSlice(
            fileRange: reader.fileRange, header: header, loadCommands: loadCommands,
            segments: segments, firstFileBackedContentOffset: firstFileBackedContentOffset,
            embeddedSignature: signature
        )
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
    private static func segment(
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

    private static func superBlob(
        in signature: BoundedBinaryReader,
        signatureOffset: Int?
    ) throws -> MachOSuperBlob {
        _ = try signature.checkedRange(at: 0, length: 12, boundary: .superBlob)
        let magic = try signature.uint32(at: 0, order: .bigEndian, boundary: .superBlob)
        guard magic == 0xFADE0CC0 else {
            throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
        }
        let length = try signature.uint32AsInt(
            at: 4, order: .bigEndian, boundary: .superBlob, ifUnrepresentable: .invalidLength
        )
        let count = try signature.uint32AsInt(at: 8, order: .bigEndian, boundary: .superBlob)
        guard length >= 12 else {
            throw MachOParsingError(.invalidLength, at: .superBlob)
        }
        guard count <= maximumSignatureEntries else {
            throw MachOParsingError(.resourceLimitExceeded, at: .superBlob)
        }
        let blob = try signature.view(at: 0, length: length, boundary: .superBlob)
        // Both operands are bounded (count <= 128). An index cannot begin in
        // the middle of the table, even if it points to a plausible blob.
        let tableEnd = 12 + count * 8
        guard tableEnd <= length else {
            throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
        }
        var indexed: [IndexedBlob] = []
        indexed.reserveCapacity(count)
        var seenSlots: Set<UInt32> = []
        for index in 0..<count {
            let position = 12 + index * 8
            let slot = try blob.uint32(at: position, order: .bigEndian, boundary: .superBlob)
            let offset = try blob.uint32AsInt(
                at: position + 4, order: .bigEndian, boundary: .superBlob, ifUnrepresentable: .invalidOffset
            )
            guard seenSlots.insert(slot).inserted else {
                throw MachOParsingError(.malformedSuperBlob, at: .superBlob)
            }
            guard offset >= tableEnd else {
                throw MachOParsingError(.invalidOffset, at: .signatureBlob)
            }
            let blobHeader = try blob.view(at: offset, length: 8, boundary: .signatureBlob)
            let typeMagic = try blobHeader.uint32(at: 0, order: .bigEndian, boundary: .signatureBlob)
            let blobLength = try blobHeader.uint32AsInt(
                at: 4, order: .bigEndian, boundary: .signatureBlob, ifUnrepresentable: .invalidLength
            )
            guard blobLength >= 8 else {
                throw MachOParsingError(.invalidLength, at: .signatureBlob)
            }
            let range = try blob.checkedRange(
                at: offset, length: blobLength, boundary: .signatureBlob, ifTooLong: .invalidLength
            )
            guard !indexed.contains(where: { $0.fileRange.overlaps(range) }) else {
                throw MachOParsingError(.malformedSignatureBlob, at: .signatureBlob)
            }
            indexed.append(.init(slotNumber: slot, relativeOffset: offset,
                                 magic: typeMagic, fileRange: range, length: blobLength))
        }

        var entries: [MachOSignatureEntry] = []
        entries.reserveCapacity(count)
        for item in indexed {
            let slot = CodeSignatureBlobType(rawValue: item.slotNumber)
            if let expectedMagic = slot.expectedMagic, item.magic != expectedMagic {
                throw MachOParsingError(.malformedSignatureBlob, at: .signatureBlob)
            }
            let directory: MachOCodeDirectory?
            switch slot {
            case .codeDirectory, .alternateCodeDirectory:
                let member = try blob.view(
                    at: item.relativeOffset, length: item.length, boundary: .codeDirectory
                )
                directory = try codeDirectory(in: member, signatureOffset: signatureOffset)
            default:
                directory = nil
            }
            entries.append(.init(slotNumber: item.slotNumber, slot: slot,
                                 relativeOffset: item.relativeOffset, magic: item.magic,
                                 fileRange: item.fileRange, codeDirectory: directory))
        }
        return MachOSuperBlob(magic: magic, fileRange: blob.fileRange, entries: entries)
    }
}
