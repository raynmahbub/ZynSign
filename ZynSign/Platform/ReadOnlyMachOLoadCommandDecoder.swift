import Foundation

/// Bounded, read-only decoding of Mach-O load-command payloads.
///
/// The structural parser (`ReadOnlyMachOParser`) establishes each command's
/// type and range and decodes only the segments and the code-signature
/// command. This decoder reads the remaining payloads — library names,
/// search paths, the build UUID and version, the entry point, the encryption
/// record, linker tables — for inspection.
///
/// Every read goes through `BoundedBinaryReader`, confined to the command's
/// own range, so a field can never be read from outside the command it
/// belongs to. Strings are read only when NUL-terminated inside the command
/// and are bounded in length. A payload that cannot be decoded is reported as
/// `.malformed` on its own command; the remaining commands still decode. The
/// decoder writes nothing, loads nothing, and draws no conclusion about
/// whether a named library exists or loads.
struct ReadOnlyMachOLoadCommandDecoder: MachOLoadCommandDecoding {

    /// The longest name ZynSign reads from one command, in bytes.
    static let maximumStringBytes = 4_096

    /// The most tools one build-version record may list.
    static let maximumBuildTools = 32

    init() {}

    func decodeLoadCommands(of slice: MachOSlice, in bytes: Data) -> [MachODecodedLoadCommand] {
        let order = slice.header.byteOrder
        var segmentsByCommandStart: [Int: (segment: MachOSegment, index: Int)] = [:]
        for (index, segment) in slice.segments.enumerated() {
            segmentsByCommandStart[segment.commandRange.lowerBound] = (segment, index)
        }
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [MachODecodedLoadCommand] in
            let reader = BoundedBinaryReader(bytes: raw)
            var decoded: [MachODecodedLoadCommand] = []
            decoded.reserveCapacity(slice.loadCommands.count)
            for (index, command) in slice.loadCommands.enumerated() {
                let payload: MachOLoadCommandPayload
                if command.type == MachOLoadCommandCode.segment || command.type == MachOLoadCommandCode.segment64 {
                    if let match = segmentsByCommandStart[command.fileRange.lowerBound] {
                        payload = .segment(MachOSegmentSummary(segment: match.segment, index: match.index))
                    } else {
                        payload = .malformed(.segmentNotEstablished)
                    }
                } else {
                    payload = Self.decodePayload(
                        type: command.type,
                        range: command.fileRange,
                        reader: reader,
                        order: order
                    )
                }
                decoded.append(MachODecodedLoadCommand(
                    index: index,
                    type: command.type,
                    fileRange: command.fileRange,
                    payload: payload
                ))
            }
            return decoded
        }
    }

    // MARK: - Payloads

    private static func decodePayload(
        type: UInt32,
        range: Range<Int>,
        reader: BoundedBinaryReader,
        order: MachOByteOrder
    ) -> MachOLoadCommandPayload {
        do {
            let command = try reader.view(at: range.lowerBound, length: range.count, boundary: .loadCommands)
            return try decode(type: type, command: command, order: order)
        } catch let issue as DecodingIssue {
            return .malformed(issue.issue)
        } catch {
            // Every other failure comes from a checked read that left the
            // command's own range.
            return .malformed(.fieldsExceedCommand)
        }
    }

    private static func decode(
        type: UInt32,
        command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload {
        typealias Code = MachOLoadCommandCode
        if let kind = MachODylibLoadKind(commandType: type) {
            return try decodeDylib(kind: kind, in: command, order: order)
        }
        if Code.linkEditDataReferences.contains(type) {
            return try decodeLinkEditData(in: command, order: order)
        }
        if let payload = try decodeStringCommand(type: type, in: command, order: order) {
            return payload
        }
        if let payload = try decodeVersionCommand(type: type, in: command, order: order) {
            return payload
        }
        return try decodeOtherCommand(type: type, in: command, order: order)
    }

    private static func decodeDylib(
        kind: MachODylibLoadKind,
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload {
        // struct dylib_command: cmd, cmdsize, { name offset, timestamp,
        // current_version, compatibility_version }.
        let nameOffset = try readUInt32(at: 8, from: command, order: order)
        return .dylib(MachODylibReference(
            kind: kind,
            installName: try string(in: command, at: nameOffset, fixedSize: 24),
            currentVersion: MachOPackedVersion(rawValue: try readUInt32(at: 16, from: command, order: order)),
            compatibilityVersion: MachOPackedVersion(rawValue: try readUInt32(at: 20, from: command, order: order)),
            timestamp: try readUInt32(at: 12, from: command, order: order)
        ))
    }

    private static func decodeLinkEditData(
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload {
        .linkEditData(MachOLinkEditDataReference(
            dataOffset: try readUInt32(at: 8, from: command, order: order),
            dataSize: try readUInt32(at: 12, from: command, order: order)
        ))
    }

    private static func decodeStringCommand(
        type: UInt32,
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload? {
        typealias Code = MachOLoadCommandCode
        switch type {
        case Code.loadDylinker, Code.idDylinker:
            let value = try string(in: command, at: readUInt32(at: 8, from: command, order: order), fixedSize: 12)
            return .dynamicLinker(value)
        case Code.runPath:
            let value = try string(in: command, at: readUInt32(at: 8, from: command, order: order), fixedSize: 12)
            return .runPath(value)
        case Code.dyldEnvironment:
            let value = try string(in: command, at: readUInt32(at: 8, from: command, order: order), fixedSize: 12)
            return .environment(value)
        default:
            return nil
        }
    }

    private static func decodeVersionCommand(
        type: UInt32,
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload? {
        typealias Code = MachOLoadCommandCode
        switch type {
        case Code.buildVersion:
            return .buildVersion(try buildVersion(in: command, order: order))
        case Code.versionMinIPhoneOS, Code.versionMinMacOS, Code.versionMinTVOS, Code.versionMinWatchOS:
            return .minimumVersion(try minimumVersion(type: type, in: command, order: order))
        default:
            return nil
        }
    }

    private static func buildVersion(
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOBuildVersion {
        let toolCount = try readUInt32(at: 20, from: command, order: order)
        guard toolCount <= UInt32(maximumBuildTools) else {
            throw DecodingIssue(issue: .tooManyEntries)
        }
        var tools: [MachOBuildTool] = []
        tools.reserveCapacity(Int(toolCount))
        for index in 0..<Int(toolCount) {
            let base = 24 + index * 8
            tools.append(MachOBuildTool(
                tool: try readUInt32(at: base, from: command, order: order),
                version: MachOPackedVersion(rawValue: try readUInt32(at: base + 4, from: command, order: order))
            ))
        }
        return MachOBuildVersion(
            platform: MachOPlatform(rawValue: try readUInt32(at: 8, from: command, order: order)),
            minimumOS: MachOPackedVersion(rawValue: try readUInt32(at: 12, from: command, order: order)),
            sdk: MachOPackedVersion(rawValue: try readUInt32(at: 16, from: command, order: order)),
            tools: tools
        )
    }

    private static func minimumVersion(
        type: UInt32,
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOMinimumVersion {
        typealias Code = MachOLoadCommandCode
        let platform: MachOPlatform
        switch type {
        case Code.versionMinMacOS: platform = .macOS
        case Code.versionMinTVOS: platform = .tvOS
        case Code.versionMinWatchOS: platform = .watchOS
        default: platform = .iOS
        }
        return MachOMinimumVersion(
            platform: platform,
            version: MachOPackedVersion(rawValue: try readUInt32(at: 8, from: command, order: order)),
            sdk: MachOPackedVersion(rawValue: try readUInt32(at: 12, from: command, order: order))
        )
    }

    private static func decodeOtherCommand(
        type: UInt32,
        in command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> MachOLoadCommandPayload {
        typealias Code = MachOLoadCommandCode
        switch type {
        case Code.uuid:
            let bytes = try command.data(at: 8, length: 16, boundary: .loadCommands)
            return .uuid(uuidText(bytes))
        case Code.sourceVersion:
            return .sourceVersion(MachOSourceVersion(rawValue: try readUInt64(at: 8, from: command, order: order)))
        case Code.main:
            return .entryPoint(
                offset: try readUInt64(at: 8, from: command, order: order),
                stackSize: try readUInt64(at: 16, from: command, order: order)
            )
        case Code.encryptionInfo, Code.encryptionInfo64:
            return .encryption(MachOEncryptionInfo(
                cryptOffset: try readUInt32(at: 8, from: command, order: order),
                cryptSize: try readUInt32(at: 12, from: command, order: order),
                cryptID: try readUInt32(at: 16, from: command, order: order)
            ))
        case Code.dyldInfo, Code.dyldInfoOnly:
            // struct dyld_info_command: five (offset, size) pairs from byte 8.
            return .dyldInfo(MachODyldInfo(
                rebaseSize: try readUInt32(at: 12, from: command, order: order),
                bindSize: try readUInt32(at: 20, from: command, order: order),
                weakBindSize: try readUInt32(at: 28, from: command, order: order),
                lazyBindSize: try readUInt32(at: 36, from: command, order: order),
                exportSize: try readUInt32(at: 44, from: command, order: order)
            ))
        case Code.symbolTable:
            return .symbolTable(MachOSymbolTableInfo(
                symbolCount: try readUInt32(at: 12, from: command, order: order),
                stringTableSize: try readUInt32(at: 20, from: command, order: order)
            ))
        case Code.dynamicSymbolTable:
            return .dynamicSymbolTable(MachODynamicSymbolTableInfo(
                localSymbolCount: try readUInt32(at: 12, from: command, order: order),
                externalSymbolCount: try readUInt32(at: 20, from: command, order: order),
                undefinedSymbolCount: try readUInt32(at: 28, from: command, order: order),
                indirectSymbolCount: try readUInt32(at: 60, from: command, order: order)
            ))
        case Code.linkerOption:
            return .linkerOptions(count: try readUInt32(at: 8, from: command, order: order))
        case Code.note:
            let owner = try command.data(at: 8, length: 16, boundary: .loadCommands)
            return .note(
                owner: MachOText.fixedName([UInt8](owner)),
                offset: try readUInt64(at: 24, from: command, order: order),
                size: try readUInt64(at: 32, from: command, order: order)
            )
        default:
            return .opaque
        }
    }

    private static func readUInt32(
        at offset: Int,
        from command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> UInt32 {
        try command.uint32(at: offset, order: order, boundary: .loadCommands)
    }

    private static func readUInt64(
        at offset: Int,
        from command: BoundedBinaryReader,
        order: MachOByteOrder
    ) throws -> UInt64 {
        try command.uint64(at: offset, order: order, boundary: .loadCommands)
    }

    // MARK: - Strings

    /// Reads an `lc_str`: a NUL-terminated string at `offset` from the start
    /// of the command. The string must begin after the command's fixed
    /// fields and end, with its terminator, inside the command.
    private static func string(in command: BoundedBinaryReader, at offset: UInt32, fixedSize: Int) throws -> String {
        guard let start = Int(exactly: offset), start >= fixedSize, start < command.count else {
            throw DecodingIssue(issue: .invalidStringOffset)
        }
        let available = min(command.count - start, maximumStringBytes + 1)
        let bytes = try command.data(at: start, length: available, boundary: .loadCommands)
        guard let terminator = bytes.firstIndex(of: 0) else {
            throw DecodingIssue(issue: .unterminatedString)
        }
        let text = String(decoding: bytes[bytes.startIndex..<terminator], as: UTF8.self)
        return MachOText.sanitized(text, limit: maximumStringBytes)
    }

    private static func uuidText(_ bytes: Data) -> String {
        let hex = MachOHexadecimal.bytes(bytes).uppercased()
        let characters = Array(hex)
        guard characters.count == 32 else { return hex }
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { String(characters[$0]) }.joined(separator: "-")
    }

    private struct DecodingIssue: Error {
        let issue: MachOLoadCommandDecodingIssue
    }
}
