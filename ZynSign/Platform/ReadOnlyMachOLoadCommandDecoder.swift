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
        func u32(_ offset: Int) throws -> UInt32 {
            try command.uint32(at: offset, order: order, boundary: .loadCommands)
        }
        func u64(_ offset: Int) throws -> UInt64 {
            try command.uint64(at: offset, order: order, boundary: .loadCommands)
        }

        if let kind = MachODylibLoadKind(commandType: type) {
            // struct dylib_command: cmd, cmdsize, { name offset, timestamp,
            // current_version, compatibility_version }.
            let nameOffset = try u32(8)
            let reference = MachODylibReference(
                kind: kind,
                installName: try string(in: command, at: nameOffset, fixedSize: 24),
                currentVersion: MachOPackedVersion(rawValue: try u32(16)),
                compatibilityVersion: MachOPackedVersion(rawValue: try u32(20)),
                timestamp: try u32(12)
            )
            return .dylib(reference)
        }
        if Code.linkEditDataReferences.contains(type) {
            return .linkEditData(MachOLinkEditDataReference(dataOffset: try u32(8), dataSize: try u32(12)))
        }

        switch type {
        case Code.loadDylinker, Code.idDylinker:
            return .dynamicLinker(try string(in: command, at: try u32(8), fixedSize: 12))
        case Code.runPath:
            return .runPath(try string(in: command, at: try u32(8), fixedSize: 12))
        case Code.dyldEnvironment:
            return .environment(try string(in: command, at: try u32(8), fixedSize: 12))
        case Code.uuid:
            let bytes = try command.data(at: 8, length: 16, boundary: .loadCommands)
            return .uuid(uuidText(bytes))
        case Code.buildVersion:
            // struct build_version_command: cmd, cmdsize, platform, minos,
            // sdk, ntools, then ntools × { tool, version }.
            let toolCount = try u32(20)
            guard toolCount <= UInt32(maximumBuildTools) else {
                throw DecodingIssue(issue: .tooManyEntries)
            }
            var tools: [MachOBuildTool] = []
            tools.reserveCapacity(Int(toolCount))
            for index in 0..<Int(toolCount) {
                let base = 24 + index * 8
                tools.append(MachOBuildTool(
                    tool: try u32(base),
                    version: MachOPackedVersion(rawValue: try u32(base + 4))
                ))
            }
            return .buildVersion(MachOBuildVersion(
                platform: MachOPlatform(rawValue: try u32(8)),
                minimumOS: MachOPackedVersion(rawValue: try u32(12)),
                sdk: MachOPackedVersion(rawValue: try u32(16)),
                tools: tools
            ))
        case Code.versionMinIPhoneOS, Code.versionMinMacOS, Code.versionMinTVOS, Code.versionMinWatchOS:
            let platform: MachOPlatform
            switch type {
            case Code.versionMinMacOS: platform = .macOS
            case Code.versionMinTVOS: platform = .tvOS
            case Code.versionMinWatchOS: platform = .watchOS
            default: platform = .iOS
            }
            return .minimumVersion(MachOMinimumVersion(
                platform: platform,
                version: MachOPackedVersion(rawValue: try u32(8)),
                sdk: MachOPackedVersion(rawValue: try u32(12))
            ))
        case Code.sourceVersion:
            return .sourceVersion(MachOSourceVersion(rawValue: try u64(8)))
        case Code.main:
            return .entryPoint(offset: try u64(8), stackSize: try u64(16))
        case Code.encryptionInfo, Code.encryptionInfo64:
            return .encryption(MachOEncryptionInfo(
                cryptOffset: try u32(8),
                cryptSize: try u32(12),
                cryptID: try u32(16)
            ))
        case Code.dyldInfo, Code.dyldInfoOnly:
            // struct dyld_info_command: five (offset, size) pairs from byte 8.
            return .dyldInfo(MachODyldInfo(
                rebaseSize: try u32(12),
                bindSize: try u32(20),
                weakBindSize: try u32(28),
                lazyBindSize: try u32(36),
                exportSize: try u32(44)
            ))
        case Code.symbolTable:
            return .symbolTable(MachOSymbolTableInfo(symbolCount: try u32(12), stringTableSize: try u32(20)))
        case Code.dynamicSymbolTable:
            return .dynamicSymbolTable(MachODynamicSymbolTableInfo(
                localSymbolCount: try u32(12),
                externalSymbolCount: try u32(20),
                undefinedSymbolCount: try u32(28),
                indirectSymbolCount: try u32(60)
            ))
        case Code.linkerOption:
            return .linkerOptions(count: try u32(8))
        case Code.note:
            let owner = try command.data(at: 8, length: 16, boundary: .loadCommands)
            return .note(
                owner: MachOText.fixedName([UInt8](owner)),
                offset: try u64(24),
                size: try u64(32)
            )
        default:
            return .opaque
        }
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
