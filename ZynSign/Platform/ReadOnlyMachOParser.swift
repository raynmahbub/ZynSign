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

    /// Reads only the segment facts needed by the append-only mutation
    /// boundary. This remains part of the one bounded Mach-O parser rather
    /// than a second layout reader. Each file-backed section is proved to lie
    /// inside both its segment's file range and the containing slice before it
    /// can establish header-padding capacity.
    private static func segment(
        in command: BoundedBinaryReader,
        type: UInt32,
        wordSize: MachOWordSize,
        order: MachOByteOrder,
        sliceLength: Int
    ) throws -> MachOSegment {
        let is64BitCommand = type == MachOLoadCommandType.segment64
        guard (is64BitCommand && wordSize == .bits64) ||
              (!is64BitCommand && wordSize == .bits32) else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }

        let commandHeaderLength = is64BitCommand ? 72 : 56
        let sectionLength = is64BitCommand ? 80 : 68
        guard command.count >= commandHeaderLength else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }
        let sectionCount = try command.uint32AsInt(
            at: is64BitCommand ? 64 : 48,
            order: order,
            boundary: .segment,
            ifUnrepresentable: .invalidLength
        )
        let (sectionBytes, sectionBytesOverflow) = sectionCount.multipliedReportingOverflow(by: sectionLength)
        guard !sectionBytesOverflow else {
            throw MachOParsingError(.invalidLength, at: .segment)
        }
        let (expectedLength, expectedLengthOverflow) = commandHeaderLength.addingReportingOverflow(sectionBytes)
        guard !expectedLengthOverflow, expectedLength == command.count else {
            throw MachOParsingError(.invalidLoadCommand, at: .segment)
        }

        let name = MachOSegmentName(rawBytes: Array(try command.data(
            at: 8, length: 16, boundary: .segment
        )))
        let virtualMemoryAddress: UInt64
        let virtualMemorySize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
        let fileSizeFieldRange: Range<Int>
        if is64BitCommand {
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
        let (segmentEnd, segmentEndOverflow) = fileOffset.addingReportingOverflow(fileSize)
        guard !segmentEndOverflow else {
            throw MachOParsingError(.invalidLength, at: .segment)
        }
        if fileSize > 0 {
            guard let offset = Int(exactly: fileOffset), offset <= sliceLength else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let length = Int(exactly: fileSize), length <= sliceLength - offset else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
        }

        var firstFileBackedSectionOffset: Int?
        var sections: [MachOSection] = []
        // The complete section table was bounded by command size above.
        sections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let position = commandHeaderLength + index * sectionLength
            let sectionSize: UInt64
            let sectionOffset: UInt64
            let flags: UInt32
            if is64BitCommand {
                sectionSize = try command.uint64(at: position + 40, order: order, boundary: .segment)
                sectionOffset = UInt64(try command.uint32(at: position + 48, order: order, boundary: .segment))
                flags = try command.uint32(at: position + 64, order: order, boundary: .segment)
            } else {
                sectionSize = UInt64(try command.uint32(at: position + 36, order: order, boundary: .segment))
                sectionOffset = UInt64(try command.uint32(at: position + 40, order: order, boundary: .segment))
                flags = try command.uint32(at: position + 56, order: order, boundary: .segment)
            }
            let virtualAddress = is64BitCommand
                ? try command.uint64(at: position + 32, order: order, boundary: .segment)
                : UInt64(try command.uint32(at: position + 32, order: order, boundary: .segment))
            let sectionFields = position + (is64BitCommand ? 52 : 44)
            sections.append(MachOSection(
                name: Array(try command.data(at: position, length: 16, boundary: .segment)),
                segmentName: Array(try command.data(at: position + 16, length: 16, boundary: .segment)),
                virtualAddress: virtualAddress, size: sectionSize, fileOffset: sectionOffset,
                alignmentExponent: try command.uint32(at: sectionFields, order: order, boundary: .segment),
                relocationOffset: try command.uint32(at: sectionFields + 4, order: order, boundary: .segment),
                relocationCount: try command.uint32(at: sectionFields + 8, order: order, boundary: .segment),
                flags: flags,
                reserved1: try command.uint32(at: sectionFields + 16, order: order, boundary: .segment),
                reserved2: try command.uint32(at: sectionFields + 20, order: order, boundary: .segment),
                reserved3: is64BitCommand
                    ? try command.uint32(at: sectionFields + 24, order: order, boundary: .segment) : nil))
            let sectionType = flags & MachOSectionType.mask
            guard sectionSize == 0 ||
                  (sectionType != MachOSectionType.zeroFill &&
                   sectionType != MachOSectionType.threadLocalZeroFill) else {
                continue
            }
            guard sectionSize > 0 else { continue }
            let (sectionEnd, sectionEndOverflow) = sectionOffset.addingReportingOverflow(sectionSize)
            guard !sectionEndOverflow else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
            guard sectionOffset >= fileOffset, sectionEnd <= segmentEnd else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let offset = Int(exactly: sectionOffset), offset <= sliceLength else {
                throw MachOParsingError(.invalidOffset, at: .segment)
            }
            guard let length = Int(exactly: sectionSize), length <= sliceLength - offset else {
                throw MachOParsingError(.invalidLength, at: .segment)
            }
            if let current = firstFileBackedSectionOffset {
                firstFileBackedSectionOffset = min(current, offset)
            } else {
                firstFileBackedSectionOffset = offset
            }
        }

        return MachOSegment(
            commandRange: command.fileRange, wordSize: wordSize, name: name,
            fileOffset: fileOffset, fileSize: fileSize,
            virtualMemoryAddress: virtualMemoryAddress, virtualMemorySize: virtualMemorySize,
            maximumProtection: try command.uint32(at: is64BitCommand ? 56 : 40, order: order, boundary: .segment),
            initialProtection: try command.uint32(at: is64BitCommand ? 60 : 44, order: order, boundary: .segment),
            flags: try command.uint32(at: is64BitCommand ? 68 : 52, order: order, boundary: .segment),
            sections: sections,
            sectionCount: sectionCount, firstFileBackedSectionOffset: firstFileBackedSectionOffset,
            fileSizeFieldRange: fileSizeFieldRange
        )
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

    private static func codeDirectory(
        in blob: BoundedBinaryReader,
        signatureOffset: Int?
    ) throws -> MachOCodeDirectory {
        let boundary: MachOParsingError.Boundary = .codeDirectory
        _ = try blob.checkedRange(at: 0, length: 12, boundary: boundary)
        let version = try blob.uint32(at: 8, order: .bigEndian, boundary: boundary)
        guard version >= 0x20001, version <= 0x20600 else {
            throw MachOParsingError(.unsupportedCodeDirectoryVersion, at: boundary, version: version)
        }
        let fixedSize: Int
        switch version {
        case ..<0x20100: fixedSize = 44
        case ..<0x20200: fixedSize = 48
        case ..<0x20300: fixedSize = 52
        case ..<0x20400: fixedSize = 64
        case ..<0x20500: fixedSize = 88
        case ..<0x20600: fixedSize = 96
        default: fixedSize = 108
        }
        _ = try blob.checkedRange(at: 0, length: fixedSize, boundary: boundary)
        let flags = try blob.uint32(at: 12, order: .bigEndian, boundary: boundary)
        let hashOffset = try blob.uint32AsInt(
            at: 16, order: .bigEndian, boundary: .hashSlots, ifUnrepresentable: .invalidOffset
        )
        let identifierOffset = try blob.uint32AsInt(
            at: 20, order: .bigEndian, boundary: .identifier, ifUnrepresentable: .invalidOffset
        )
        let specialCount = try blob.uint32AsInt(at: 24, order: .bigEndian, boundary: .hashSlots)
        let codeCount = try blob.uint32AsInt(at: 28, order: .bigEndian, boundary: .hashSlots)
        let codeLimit = try blob.uint32(at: 32, order: .bigEndian, boundary: boundary)
        let hashSize = Int(try blob.uint8(at: 36, boundary: .hashSlots))
        let hashType = MachOHashType(rawValue: try blob.uint8(at: 37, boundary: .hashSlots))
        let platform = try blob.uint8(at: 38, boundary: boundary)
        let pageSize = try blob.uint8(at: 39, boundary: .hashSlots)
        let spare2 = try blob.uint32(at: 40, order: .bigEndian, boundary: boundary)
        let spare3 = version >= 0x20300
            ? try blob.uint32(at: 52, order: .bigEndian, boundary: boundary) : 0
        guard spare2 == 0, spare3 == 0 else {
            throw MachOParsingError(.malformedCodeDirectory, at: boundary)
        }
        guard hashSize > 0, hashSize <= 48,
              hashType.expectedByteCount == nil || hashType.expectedByteCount == hashSize,
              pageSize <= 30 else {
            throw MachOParsingError(.malformedCodeDirectory, at: .hashSlots)
        }
        guard specialCount <= maximumSpecialSlots,
              codeCount <= maximumCodeSlots else {
            throw MachOParsingError(.resourceLimitExceeded, at: .hashSlots)
        }
        guard hashOffset >= fixedSize, hashOffset <= blob.count else {
            throw MachOParsingError(.invalidOffset, at: .hashSlots)
        }
        let specialBytes = specialCount * hashSize  // bounded by 64 * 48
        guard specialBytes <= hashOffset - fixedSize,
              codeCount <= (blob.count - hashOffset) / hashSize else {
            throw MachOParsingError(.invalidLength, at: .hashSlots)
        }
        let hashesStart = hashOffset - specialBytes
        let hashesLength = specialBytes + codeCount * hashSize  // <= blob.count
        let allHashes = try blob.checkedRange(at: hashesStart, length: hashesLength, boundary: .hashSlots)
        let codeHashes = try blob.checkedRange(at: hashOffset, length: codeCount * hashSize, boundary: .hashSlots)

        let (identifier, identifierRange) = try text(
            in: blob, at: identifierOffset, before: hashesStart,
            after: fixedSize, boundary: .identifier
        )
        var occupied = [identifierRange]
        let teamOffset: Int? = version >= 0x20200
            ? try blob.uint32AsInt(
                at: 48, order: .bigEndian, boundary: .teamIdentifier, ifUnrepresentable: .invalidOffset
            ) : nil
        let team: String?
        if let offset = teamOffset, offset != 0 {
            let (value, range) = try text(
                in: blob, at: offset, before: hashesStart,
                after: fixedSize, boundary: .teamIdentifier
            )
            team = value
            occupied.append(range)
        } else {
            team = nil
        }
        let extendedLimit: UInt64? = version >= 0x20300
            ? try blob.uint64(at: 56, order: .bigEndian, boundary: boundary) : nil
        let effectiveLimit = extendedLimit.flatMap { $0 == 0 ? nil : $0 } ?? UInt64(codeLimit)
        if let signatureOffset, effectiveLimit > UInt64(signatureOffset) {
            throw MachOParsingError(.malformedCodeDirectory, at: boundary)
        }
        let segment: MachOExecutableSegment?
        if version >= 0x20400 {
            segment = MachOExecutableSegment(
                base: try blob.uint64(at: 64, order: .bigEndian, boundary: boundary),
                limit: try blob.uint64(at: 72, order: .bigEndian, boundary: boundary),
                flags: try blob.uint64(at: 80, order: .bigEndian, boundary: boundary)
            )
        } else {
            segment = nil
        }
        let runtime: UInt32? = version >= 0x20500
            ? try blob.uint32(at: 88, order: .bigEndian, boundary: boundary) : nil

        let scatter: MachOScatterTable?
        if version >= 0x20100 {
            let offset = try blob.uint32AsInt(
                at: 44, order: .bigEndian, boundary: .scatter, ifUnrepresentable: .invalidOffset
            )
            scatter = offset == 0 ? nil : try scatterTable(
                in: blob, at: offset, after: fixedSize, before: hashesStart, codeCount: codeCount
            )
            if let scatter = scatter { occupied.append(scatter.fileRange) }
        } else {
            scatter = nil
        }
        // The page-coverage fields must agree even with scatter metadata.
        // Zero is the unpaged form (one slot if there is covered data).
        let expected: UInt64
        if pageSize == 0 {
            expected = effectiveLimit == 0 ? 0 : 1
        } else {
            guard effectiveLimit > 0 else {
                throw MachOParsingError(.malformedCodeDirectory, at: .hashSlots)
            }
            let pageBytes = UInt64(1) << pageSize
            expected = effectiveLimit / pageBytes + (effectiveLimit % pageBytes == 0 ? 0 : 1)
        }
        guard expected == UInt64(codeCount) else {
            throw MachOParsingError(.malformedCodeDirectory, at: .hashSlots)
        }

        let preEncryptHashes: Range<Int>?
        if version >= 0x20500 {
            let offset = try blob.uint32AsInt(
                at: 92, order: .bigEndian, boundary: .preEncryptHashes, ifUnrepresentable: .invalidOffset
            )
            if offset != 0 {
                guard offset >= fixedSize, codeCount > 0 else {
                    throw MachOParsingError(.invalidOffset, at: .preEncryptHashes)
                }
                preEncryptHashes = try blob.checkedRange(
                    at: offset, length: codeCount * hashSize,
                    boundary: .preEncryptHashes, ifTooLong: .invalidLength
                )
                if let range = preEncryptHashes { occupied.append(range) }
            } else {
                preEncryptHashes = nil
            }
        } else {
            preEncryptHashes = nil
        }

        let linkage: MachOLinkage?
        if version >= 0x20600 {
            let hash = try blob.uint8(at: 96, boundary: .linkage)
            let application = try blob.uint8(at: 97, boundary: .linkage)
            let subtype = try blob.uint16(at: 98, order: .bigEndian, boundary: .linkage)
            let offset = try blob.uint32AsInt(
                at: 100, order: .bigEndian, boundary: .linkage, ifUnrepresentable: .invalidOffset
            )
            let length = try blob.uint32AsInt(
                at: 104, order: .bigEndian, boundary: .linkage, ifUnrepresentable: .invalidLength
            )
            guard (offset == 0) == (length == 0) else {
                throw MachOParsingError(.invalidLength, at: .linkage)
            }
            let dataRange: Range<Int>?
            if length > 0 {
                guard offset >= fixedSize else {
                    throw MachOParsingError(.invalidOffset, at: .linkage)
                }
                dataRange = try blob.checkedRange(
                    at: offset, length: length, boundary: .linkage, ifTooLong: .invalidLength
                )
                if let range = dataRange { occupied.append(range) }
            } else {
                dataRange = nil
            }
            linkage = MachOLinkage(hashType: hash, applicationType: application,
                                   applicationSubtype: subtype, dataRange: dataRange)
        } else {
            linkage = nil
        }
        for (index, range) in occupied.enumerated() {
            guard !range.overlaps(allHashes),
                  !occupied[..<index].contains(where: { $0.overlaps(range) }) else {
                throw MachOParsingError(.malformedCodeDirectory, at: boundary)
            }
        }

        var specialSlots: [MachOSpecialHashSlot] = []
        specialSlots.reserveCapacity(specialCount)
        if specialCount > 0 {
            for number in 1...specialCount {
                let position = hashOffset - number * hashSize
                let slot = try blob.view(at: position, length: hashSize, boundary: .hashSlots)
                let hash = try blob.data(at: position, length: hashSize, boundary: .hashSlots)
                var nonzero = false
                for byte in 0..<hashSize {
                    if try slot.uint8(at: byte, boundary: .hashSlots) != 0 { nonzero = true; break }
                }
                specialSlots.append(MachOSpecialHashSlot(
                    slotNumber: -number, kind: MachOSpecialHashKind(slotNumber: number),
                    hashRange: slot.fileRange, hash: hash, hasNonzeroBytes: nonzero
                ))
            }
        }
        var codeHashValues: [Data] = []
        codeHashValues.reserveCapacity(codeCount)
        for index in 0..<codeCount {
            let position = hashOffset + index * hashSize
            codeHashValues.append(try blob.data(at: position, length: hashSize, boundary: .hashSlots))
        }
        return MachOCodeDirectory(
            version: version, flags: flags, identifier: identifier, teamIdentifier: team,
            hashOffset: hashOffset, hashType: hashType, hashSize: hashSize, platform: platform,
            pageSizeExponent: pageSize, codeSlotCount: codeCount, specialSlotCount: specialCount,
            codeLimit: codeLimit, codeLimit64: extendedLimit, codeHashesRange: codeHashes,
            codeHashes: codeHashValues, specialSlots: specialSlots, scatter: scatter, executableSegment: segment,
            runtime: runtime, preEncryptHashesRange: preEncryptHashes, linkage: linkage
        )
    }

    private static func text(
        in blob: BoundedBinaryReader,
        at offset: Int,
        before end: Int,
        after header: Int,
        boundary: MachOParsingError.Boundary
    ) throws -> (String, Range<Int>) {
        guard offset >= header, offset < end else {
            throw MachOParsingError(.invalidOffset, at: boundary)
        }
        let available = min(maximumIdentifierBytes + 1, end - offset)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(available, maximumIdentifierBytes))
        for index in 0..<available {
            let byte = try blob.uint8(at: offset + index, boundary: boundary)
            if byte == 0 {
                guard !bytes.isEmpty, let decoded = String(bytes: bytes, encoding: .utf8) else {
                    throw MachOParsingError(.malformedCodeDirectory, at: boundary)
                }
                let range = try blob.checkedRange(at: offset, length: index + 1, boundary: boundary)
                return (decoded, range)
            }
            bytes.append(byte)
        }
        throw MachOParsingError(
            available > maximumIdentifierBytes ? .resourceLimitExceeded : .malformedCodeDirectory,
            at: boundary
        )
    }

    private static func scatterTable(
        in blob: BoundedBinaryReader,
        at offset: Int,
        after header: Int,
        before hashes: Int,
        codeCount: Int
    ) throws -> MachOScatterTable {
        guard offset >= header, offset < hashes else {
            throw MachOParsingError(.invalidOffset, at: .scatter)
        }
        var records: [MachOScatterRecord] = []
        var position = offset
        var totalPages: UInt64 = 0
        while true {
            guard position <= hashes, 24 <= hashes - position else {
                throw MachOParsingError(.malformedCodeDirectory, at: .scatter)
            }
            _ = try blob.checkedRange(at: position, length: 24, boundary: .scatter)
            let count = try blob.uint32(at: position, order: .bigEndian, boundary: .scatter)
            if count == 0 {
                let range = try blob.checkedRange(
                    at: offset, length: position + 24 - offset, boundary: .scatter
                )
                return MachOScatterTable(relativeOffset: offset, fileRange: range, records: records)
            }
            guard records.count < maximumScatterRecords else {
                throw MachOParsingError(.resourceLimitExceeded, at: .scatter)
            }
            totalPages += UInt64(count) // at most 4,096 UInt32 counts
            guard totalPages <= UInt64(codeCount) else {
                throw MachOParsingError(.malformedCodeDirectory, at: .scatter)
            }
            let reserved = try blob.uint64(at: position + 16, order: .bigEndian, boundary: .scatter)
            guard reserved == 0 else {
                throw MachOParsingError(.malformedCodeDirectory, at: .scatter)
            }
            records.append(MachOScatterRecord(
                pageCount: count,
                firstPage: try blob.uint32(at: position + 4, order: .bigEndian, boundary: .scatter),
                targetOffset: try blob.uint64(at: position + 8, order: .bigEndian, boundary: .scatter),
                reserved: reserved
            ))
            position += 24 // always within hashes <= the bounded blob length
        }
    }
}
