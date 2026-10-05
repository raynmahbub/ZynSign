import Foundation

extension ReadOnlyMachOParser {
    private struct UniversalArchitectureTable {
        let records: BoundedBinaryReader
        let count: Int
        let recordSize: Int
        let endOffset: Int
    }

    static func universal(
        in reader: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder
    ) throws -> MachOUniversal {
        let table = try universalArchitectureTable(in: reader, magic: magic, order: order)
        let architectures = try readArchitectures(
            from: table,
            in: reader,
            magic: magic,
            order: order
        )
        let slices = try readUniversalSlices(in: reader, architectures: architectures)
        return MachOUniversal(magic: magic, byteOrder: order, architectures: architectures, slices: slices)
    }

    private static func universalArchitectureTable(
        in reader: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder
    ) throws -> UniversalArchitectureTable {
        let rawCount = try reader.uint32(at: 4, order: order, boundary: .architectureTable)
        guard let count = Int(exactly: rawCount), count > 0 else {
            throw MachOParsingError(.malformedHeader, at: .architectureTable)
        }
        guard count <= maximumArchitectures else {
            throw MachOParsingError(.resourceLimitExceeded, at: .architectureTable)
        }
        // The count is bounded above, so neither product nor addition can overflow.
        let recordSize = magic == .fat64 ? 32 : 20
        let tableLength = count * recordSize
        let endOffset = 8 + tableLength
        let records = try reader.view(at: 8, length: tableLength, boundary: .architectureTable)
        return UniversalArchitectureTable(
            records: records,
            count: count,
            recordSize: recordSize,
            endOffset: endOffset
        )
    }

    private static func readArchitectures(
        from table: UniversalArchitectureTable,
        in reader: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder
    ) throws -> [MachOArchitecture] {
        var architectures: [MachOArchitecture] = []
        architectures.reserveCapacity(table.count)
        for index in 0..<table.count {
            do {
                let architecture = try readArchitecture(
                    at: index,
                    from: table,
                    in: reader,
                    magic: magic,
                    order: order,
                    preceding: architectures
                )
                architectures.append(architecture)
            } catch let error as MachOParsingError {
                throw error.inArchitecture(index)
            }
        }
        return architectures
    }

    private static func readArchitecture(
        at index: Int,
        from table: UniversalArchitectureTable,
        in reader: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder,
        preceding: [MachOArchitecture]
    ) throws -> MachOArchitecture {
        let position = index * table.recordSize
        let records = table.records
        let cpu = MachOCPU(rawValue: try records.int32(
            at: position,
            order: order,
            boundary: .architectureTable
        ))
        let subtype = try records.int32(
            at: position + 4,
            order: order,
            boundary: .architectureTable
        )
        let fields = try architectureFields(at: position, in: records, magic: magic, order: order)
        guard let offset = Int(exactly: fields.offset) else {
            throw MachOParsingError(.invalidOffset, at: .architectureSlice)
        }
        guard let size = Int(exactly: fields.size), size > 0 else {
            throw MachOParsingError(.invalidLength, at: .architectureSlice)
        }
        guard fields.alignmentExponent <= 30 else {
            throw MachOParsingError(.invalidLength, at: .architectureTable)
        }
        let alignment = 1 << Int(fields.alignmentExponent)
        guard offset >= table.endOffset, offset % alignment == 0 else {
            throw MachOParsingError(.invalidOffset, at: .architectureSlice)
        }
        let range = try reader.checkedRange(
            at: offset,
            length: size,
            boundary: .architectureSlice,
            ifTooLong: .invalidLength
        )
        guard !preceding.contains(where: { $0.fileRange.overlaps(range) }) else {
            throw MachOParsingError(.invalidOffset, at: .architectureSlice)
        }
        return MachOArchitecture(
            cpu: cpu,
            cpuSubtype: subtype,
            fileRange: range,
            alignmentExponent: fields.alignmentExponent,
            reserved: fields.reserved
        )
    }

    private struct ArchitectureFields {
        let offset: UInt64
        let size: UInt64
        let alignmentExponent: UInt32
        let reserved: UInt32?
    }

    private static func architectureFields(
        at position: Int,
        in records: BoundedBinaryReader,
        magic: MachOUniversalMagic,
        order: MachOByteOrder
    ) throws -> ArchitectureFields {
        if magic == .fat64 {
            return ArchitectureFields(
                offset: try records.uint64(at: position + 8, order: order, boundary: .architectureTable),
                size: try records.uint64(at: position + 16, order: order, boundary: .architectureTable),
                alignmentExponent: try records.uint32(at: position + 24, order: order, boundary: .architectureTable),
                reserved: try records.uint32(at: position + 28, order: order, boundary: .architectureTable)
            )
        }
        return ArchitectureFields(
            offset: UInt64(try records.uint32(at: position + 8, order: order, boundary: .architectureTable)),
            size: UInt64(try records.uint32(at: position + 12, order: order, boundary: .architectureTable)),
            alignmentExponent: try records.uint32(at: position + 16, order: order, boundary: .architectureTable),
            reserved: nil
        )
    }

    private static func readUniversalSlices(
        in reader: BoundedBinaryReader,
        architectures: [MachOArchitecture]
    ) throws -> [MachOSlice] {
        var slices: [MachOSlice] = []
        slices.reserveCapacity(architectures.count)
        for (index, architecture) in architectures.enumerated() {
            do {
                let parsed = try readUniversalSlice(architecture, in: reader)
                slices.append(parsed)
            } catch let error as MachOParsingError {
                throw error.inArchitecture(index)
            }
        }
        return slices
    }

    private static func readUniversalSlice(
        _ architecture: MachOArchitecture,
        in reader: BoundedBinaryReader
    ) throws -> MachOSlice {
        let sliceReader = try reader.view(
            at: architecture.fileRange.lowerBound,
            length: architecture.fileRange.count,
            boundary: .architectureSlice
        )
        guard case .thin(let sliceMagic, let sliceOrder) = try magic(in: sliceReader) else {
            throw MachOParsingError(.unsupportedFormat, at: .architectureSlice)
        }
        let parsed = try slice(in: sliceReader, magic: sliceMagic, order: sliceOrder)
        guard parsed.header.cpu == architecture.cpu,
              parsed.header.cpuSubtype == architecture.cpuSubtype else {
            throw MachOParsingError(.malformedHeader, at: .architectureSlice)
        }
        return parsed
    }

    private struct SliceHeaderContext {
        let header: MachOHeader
        let commands: BoundedBinaryReader
        let headerSize: Int
        let alignment: Int
    }

    private struct ParsedLoadCommands {
        let loadCommands: [MachOLoadCommand]
        let segments: [MachOSegment]
        let signatureCommand: MachOCodeSignatureCommand?
    }

    private struct ParsedLoadCommand {
        let loadCommand: MachOLoadCommand
        let size: Int
        let segment: MachOSegment?
        let signature: MachOCodeSignatureCommand?
    }

    static func slice(
        in reader: BoundedBinaryReader,
        magic: MachOHeaderMagic,
        order: MachOByteOrder
    ) throws -> MachOSlice {
        let context = try sliceHeaderContext(in: reader, magic: magic, order: order)
        let parsed = try readLoadCommands(in: reader, context: context, order: order)
        let signature = try readEmbeddedSignature(parsed.signatureCommand, in: reader)
        return MachOSlice(
            fileRange: reader.fileRange,
            header: context.header,
            loadCommands: parsed.loadCommands,
            segments: parsed.segments,
            firstFileBackedContentOffset: firstFileBackedContentOffset(in: parsed.segments),
            embeddedSignature: signature
        )
    }

    private static func sliceHeaderContext(
        in reader: BoundedBinaryReader,
        magic: MachOHeaderMagic,
        order: MachOByteOrder
    ) throws -> SliceHeaderContext {
        let headerSize = magic == .mach64 ? 32 : 28
        _ = try reader.checkedRange(at: 0, length: headerSize, boundary: .header)
        let rawCommandCount = try reader.uint32(at: 16, order: order, boundary: .header)
        let rawCommandsSize = try reader.uint32(at: 20, order: order, boundary: .header)
        guard let commandCount = Int(exactly: rawCommandCount),
              let commandsSize = Int(exactly: rawCommandsSize) else {
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
            magic: magic,
            byteOrder: order,
            cpu: MachOCPU(rawValue: try reader.int32(at: 4, order: order, boundary: .header)),
            cpuSubtype: try reader.int32(at: 8, order: order, boundary: .header),
            fileType: try reader.uint32(at: 12, order: order, boundary: .header),
            loadCommandCount: commandCount,
            loadCommandsSize: commandsSize,
            flags: try reader.uint32(at: 24, order: order, boundary: .header),
            reserved: magic == .mach64 ? try reader.uint32(at: 28, order: order, boundary: .header) : nil
        )
        let commands = try reader.view(
            at: headerSize,
            length: commandsSize,
            boundary: .loadCommands
        )
        return SliceHeaderContext(
            header: header,
            commands: commands,
            headerSize: headerSize,
            alignment: alignment
        )
    }

    private static func readLoadCommands(
        in reader: BoundedBinaryReader,
        context: SliceHeaderContext,
        order: MachOByteOrder
    ) throws -> ParsedLoadCommands {
        var loadCommands: [MachOLoadCommand] = []
        loadCommands.reserveCapacity(context.header.loadCommandCount)
        var segments: [MachOSegment] = []
        segments.reserveCapacity(context.header.loadCommandCount)
        var signatureCommand: MachOCodeSignatureCommand?
        var cursor = 0
        for _ in 0..<context.header.loadCommandCount {
            let parsed = try readLoadCommand(
                at: cursor,
                in: context.commands,
                slice: reader,
                context: context,
                order: order,
                hasSignatureCommand: signatureCommand != nil
            )
            loadCommands.append(parsed.loadCommand)
            if let segment = parsed.segment {
                segments.append(segment)
            }
            if let signature = parsed.signature {
                signatureCommand = signature
            }
            cursor += parsed.size  // size <= commands.count - cursor
        }
        guard cursor == context.commands.count else {
            throw MachOParsingError(.invalidLoadCommand, at: .loadCommands)
        }
        return ParsedLoadCommands(
            loadCommands: loadCommands,
            segments: segments,
            signatureCommand: signatureCommand
        )
    }

    private static func readLoadCommand(
        at cursor: Int,
        in commands: BoundedBinaryReader,
        slice reader: BoundedBinaryReader,
        context: SliceHeaderContext,
        order: MachOByteOrder,
        hasSignatureCommand: Bool
    ) throws -> ParsedLoadCommand {
        _ = try commands.checkedRange(at: cursor, length: 8, boundary: .loadCommands)
        let type = try commands.uint32(at: cursor, order: order, boundary: .loadCommands)
        let rawSize = try commands.uint32(at: cursor + 4, order: order, boundary: .loadCommands)
        guard let size = Int(exactly: rawSize), size >= 8,
              size % context.alignment == 0, size <= commands.count - cursor else {
            throw MachOParsingError(.invalidLoadCommand, at: .loadCommands)
        }
        let commandRange = try commands.checkedRange(at: cursor, length: size, boundary: .loadCommands)
        if type == MachOLoadCommandType.codeSignature, hasSignatureCommand {
            throw MachOParsingError(.invalidLoadCommand, at: .codeSignatureCommand)
        }
        let loadCommand = MachOLoadCommand(type: type, fileRange: commandRange)
        let parsedSegment = try readSegmentIfPresent(
            type: type,
            at: cursor,
            size: size,
            in: commands,
            header: context.header,
            order: order,
            sliceLength: reader.count
        )
        let signature = try readCodeSignatureCommandIfPresent(
            type: type,
            size: size,
            cursor: cursor,
            commandRange: commandRange,
            commands: commands,
            slice: reader,
            context: context,
            order: order
        )
        return ParsedLoadCommand(
            loadCommand: loadCommand,
            size: size,
            segment: parsedSegment,
            signature: signature
        )
    }

    private static func readSegmentIfPresent(
        type: UInt32,
        at cursor: Int,
        size: Int,
        in commands: BoundedBinaryReader,
        header: MachOHeader,
        order: MachOByteOrder,
        sliceLength: Int
    ) throws -> MachOSegment? {
        guard type == MachOLoadCommandType.segment || type == MachOLoadCommandType.segment64 else {
            return nil
        }
        let command = try commands.view(at: cursor, length: size, boundary: .segment)
        return try segment(
            in: command,
            type: type,
            wordSize: header.wordSize,
            order: order,
            sliceLength: sliceLength
        )
    }

    private static func readCodeSignatureCommandIfPresent(
        type: UInt32,
        size: Int,
        cursor: Int,
        commandRange: Range<Int>,
        commands: BoundedBinaryReader,
        slice reader: BoundedBinaryReader,
        context: SliceHeaderContext,
        order: MachOByteOrder
    ) throws -> MachOCodeSignatureCommand? {
        guard type == MachOLoadCommandType.codeSignature else { return nil }
        guard size == 16 else {
            throw MachOParsingError(.invalidLoadCommand, at: .codeSignatureCommand)
        }
        let offset = try commands.uint32AsInt(
            at: cursor + 8,
            order: order,
            boundary: .codeSignatureCommand,
            ifUnrepresentable: .invalidOffset
        )
        let length = try commands.uint32AsInt(
            at: cursor + 12,
            order: order,
            boundary: .codeSignatureCommand,
            ifUnrepresentable: .invalidLength
        )
        guard length > 0 else {
            throw MachOParsingError(.invalidLength, at: .signatureRegion)
        }
        // The signature lies after load commands and its offset is slice-relative.
        guard offset >= context.headerSize + context.commands.count else {
            throw MachOParsingError(.invalidOffset, at: .signatureRegion)
        }
        let region = try reader.checkedRange(
            at: offset,
            length: length,
            boundary: .signatureRegion,
            ifTooLong: .invalidLength
        )
        return MachOCodeSignatureCommand(
            commandRange: commandRange,
            dataOffset: offset,
            dataSize: length,
            fileRange: region
        )
    }

    private static func readEmbeddedSignature(
        _ command: MachOCodeSignatureCommand?,
        in reader: BoundedBinaryReader
    ) throws -> MachOEmbeddedSignature? {
        guard let command else { return nil }
        let region = try reader.view(
            at: command.dataOffset,
            length: command.dataSize,
            boundary: .signatureRegion
        )
        return MachOEmbeddedSignature(
            command: command,
            superBlob: try superBlob(in: region, signatureOffset: command.dataOffset)
        )
    }

    private static func firstFileBackedContentOffset(in segments: [MachOSegment]) -> Int? {
        segments.compactMap { segment -> Int? in
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
    }

}
