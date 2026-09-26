import Foundation

/// Reads Mach-O header facts from a bounded prefix.
///
/// The full parser requires a complete image, including a signature region
/// that usually sits at the end of a large executable. The explorer must not
/// load that image to answer architecture, file type, load-command count,
/// encryption, and signature-command presence. Those facts live in the header
/// and the load commands, which sit at the start of a thin image and at the
/// start of each slice that fits in the prefix.
///
/// A universal slice whose header lies past the prefix is still named from
/// the fat table, with encryption and signature reported as not in the
/// preview. Nothing here executes code, computes a hash, or decides that a
/// signature is valid.
enum MachOPrefixInspector {

    private static let encryptionInfo: UInt32 = 0x21
    private static let encryptionInfo64: UInt32 = 0x2C
    private static let codeSignature: UInt32 = 0x1D
    private static let maximumArchitectures = 64
    private static let maximumLoadCommands = 4_096

    /// Inspects `prefix`. Returns `nil` when the leading bytes are not a
    /// Mach-O or universal header. A matching magic with a short header still
    /// returns a report whose slices say the rest was not in the preview.
    static func inspect(
        prefix: Data,
        declaredByteCount: Int?,
        checksumVerified: Bool
    ) -> ExplorerMachOReport? {
        let bytes = [UInt8](prefix)
        guard bytes.count >= 4, let encoding = magic(in: bytes) else { return nil }
        switch encoding {
        case .thin(let order, let headerMagic):
            let slice = parseSlice(
                bytes,
                at: 0,
                order: order,
                headerMagic: headerMagic,
                index: 0,
                fallbackArchitecture: nil
            )
            return ExplorerMachOReport(
                container: .thin,
                slices: [slice],
                declaredByteCount: declaredByteCount,
                inspectedPrefixByteCount: bytes.count,
                checksumVerified: checksumVerified
            )
        case .universal(let order, let recordSize):
            let slices = parseUniversal(bytes, order: order, recordSize: recordSize)
            return ExplorerMachOReport(
                container: .universal,
                slices: slices,
                declaredByteCount: declaredByteCount,
                inspectedPrefixByteCount: bytes.count,
                checksumVerified: checksumVerified
            )
        }
    }

    // MARK: - Magic

    private enum Encoding {
        case thin(MachOByteOrder, MachOHeaderMagic)
        case universal(MachOByteOrder, Int)
    }

    private static func magic(in bytes: [UInt8]) -> Encoding? {
        guard let raw = readUInt32(bytes, at: 0, order: .bigEndian) else { return nil }
        switch raw {
        case 0xFEEDFACE: return .thin(.bigEndian, .mach32)
        case 0xCEFAEDFE: return .thin(.littleEndian, .mach32)
        case 0xFEEDFACF: return .thin(.bigEndian, .mach64)
        case 0xCFFAEDFE: return .thin(.littleEndian, .mach64)
        case 0xCAFEBABE: return .universal(.bigEndian, 20)
        case 0xBEBAFECA: return .universal(.littleEndian, 20)
        case 0xCAFEBABF: return .universal(.bigEndian, 32)
        case 0xBFBAFECA: return .universal(.littleEndian, 32)
        default: return nil
        }
    }

    // MARK: - Universal

    private static func parseUniversal(_ bytes: [UInt8], order: MachOByteOrder, recordSize: Int) -> [ExplorerMachOSlice] {
        guard let rawCount = readUInt32(bytes, at: 4, order: order),
              let count = Int(exactly: rawCount),
              count > 0 else {
            return []
        }
        let limited = min(count, maximumArchitectures)
        var slices: [ExplorerMachOSlice] = []
        slices.reserveCapacity(limited)
        for index in 0..<limited {
            let position = 8 + index * recordSize
            guard position + recordSize <= bytes.count,
                  let cpuRaw = readInt32(bytes, at: position, order: order),
                  let subtype = readInt32(bytes, at: position + 4, order: order) else {
                break
            }
            let offset: Int?
            if recordSize == 32 {
                offset = readUInt64(bytes, at: position + 8, order: order).flatMap { Int(exactly: $0) }
            } else {
                offset = readUInt32(bytes, at: position + 8, order: order).flatMap { Int(exactly: $0) }
            }
            let architecture = architectureName(cpu: MachOCPU(rawValue: cpuRaw), subtype: subtype)
            if let offset, offset >= 0, offset < bytes.count {
                let sliceEncoding = magic(at: offset, in: bytes)
                if case .thin(let sliceOrder, let headerMagic)? = sliceEncoding {
                    slices.append(parseSlice(
                        bytes,
                        at: offset,
                        order: sliceOrder,
                        headerMagic: headerMagic,
                        index: index,
                        fallbackArchitecture: architecture
                    ))
                    continue
                }
            }
            slices.append(unreadableSlice(index: index, architectureName: architecture))
        }
        return slices
    }

    private static func magic(at offset: Int, in bytes: [UInt8]) -> Encoding? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let slice = Array(bytes[offset...])
        return magic(in: slice)
    }

    // MARK: - Slice

    private static func parseSlice(
        _ bytes: [UInt8],
        at offset: Int,
        order: MachOByteOrder,
        headerMagic: MachOHeaderMagic,
        index: Int,
        fallbackArchitecture: String?
    ) -> ExplorerMachOSlice {
        let headerSize = headerMagic == .mach64 ? 32 : 28
        guard offset >= 0,
              offset + headerSize <= bytes.count,
              let cpuRaw = readInt32(bytes, at: offset + 4, order: order),
              let subtype = readInt32(bytes, at: offset + 8, order: order),
              let fileType = readUInt32(bytes, at: offset + 12, order: order),
              let rawCount = readUInt32(bytes, at: offset + 16, order: order),
              let rawSize = readUInt32(bytes, at: offset + 20, order: order),
              let commandCount = Int(exactly: rawCount),
              let commandsSize = Int(exactly: rawSize),
              commandCount >= 0,
              commandsSize >= 0 else {
            return unreadableSlice(index: index, architectureName: fallbackArchitecture ?? "Unknown")
        }
        let architecture = architectureName(cpu: MachOCPU(rawValue: cpuRaw), subtype: subtype)
        var encryption = ExplorerEncryptionStatus.commandAbsent
        var signature = ExplorerSignaturePresence.commandAbsent
        var fullyRead = true
        let commandsEnd = offset + headerSize + commandsSize
        if commandsEnd > bytes.count || commandCount > maximumLoadCommands {
            fullyRead = false
        }
        var cursor = offset + headerSize
        var readCommands = 0
        let limit = min(commandCount, maximumLoadCommands)
        let scanEnd = min(commandsEnd, bytes.count)
        while readCommands < limit && cursor + 8 <= scanEnd {
            guard let type = readUInt32(bytes, at: cursor, order: order),
                  let sizeRaw = readUInt32(bytes, at: cursor + 4, order: order),
                  let size = Int(exactly: sizeRaw) else {
                fullyRead = false
                break
            }
            if size < 8 {
                fullyRead = false
                break
            }
            let commandEnd = cursor + size
            if commandEnd > scanEnd || commandEnd > commandsEnd {
                fullyRead = false
                notePartialCommand(
                    type: type,
                    at: cursor,
                    bytes: bytes,
                    order: order,
                    encryption: &encryption,
                    signature: &signature
                )
                break
            }
            noteCommand(
                type: type,
                size: size,
                at: cursor,
                bytes: bytes,
                order: order,
                encryption: &encryption,
                signature: &signature
            )
            cursor = commandEnd
            readCommands += 1
        }
        if readCommands < commandCount || cursor != commandsEnd {
            fullyRead = false
        }
        if !fullyRead {
            if encryption == .commandAbsent { encryption = .unreadable }
            if signature == .commandAbsent { signature = .unreadable }
        }
        return ExplorerMachOSlice(
            index: index,
            architectureName: architecture,
            fileTypeName: fileTypeName(fileType),
            loadCommandCount: commandCount,
            encryption: encryption,
            signature: signature,
            commandsFullyRead: fullyRead
        )
    }

    private static func noteCommand(
        type: UInt32,
        size: Int,
        at cursor: Int,
        bytes: [UInt8],
        order: MachOByteOrder,
        encryption: inout ExplorerEncryptionStatus,
        signature: inout ExplorerSignaturePresence
    ) {
        if type == codeSignature {
            signature = .commandPresent
        }
        guard type == encryptionInfo || type == encryptionInfo64, size >= 20,
              let cryptid = readUInt32(bytes, at: cursor + 16, order: order) else {
            return
        }
        record(cryptid: cryptid, into: &encryption)
    }

    private static func notePartialCommand(
        type: UInt32,
        at cursor: Int,
        bytes: [UInt8],
        order: MachOByteOrder,
        encryption: inout ExplorerEncryptionStatus,
        signature: inout ExplorerSignaturePresence
    ) {
        if type == codeSignature {
            signature = .commandPresent
        }
        guard type == encryptionInfo || type == encryptionInfo64,
              cursor + 20 <= bytes.count,
              let cryptid = readUInt32(bytes, at: cursor + 16, order: order) else {
            return
        }
        record(cryptid: cryptid, into: &encryption)
    }

    private static func record(cryptid: UInt32, into encryption: inout ExplorerEncryptionStatus) {
        if cryptid != 0 {
            encryption = .encrypted(cryptid: cryptid)
        } else if encryption != .encrypted(cryptid: 0) {
            if case .encrypted = encryption { return }
            encryption = .notEncrypted
        }
    }

    private static func unreadableSlice(index: Int, architectureName: String) -> ExplorerMachOSlice {
        ExplorerMachOSlice(
            index: index,
            architectureName: architectureName,
            fileTypeName: "Not in preview",
            loadCommandCount: 0,
            encryption: .unreadable,
            signature: .unreadable,
            commandsFullyRead: false
        )
    }

    // MARK: - Names

    static func architectureName(cpu: MachOCPU, subtype: Int32) -> String {
        let bits = subtype & 0x00FF_FFFF
        switch cpu {
        case .arm64:
            return bits == 2 ? "arm64e" : "arm64"
        case .arm:
            switch bits {
            case 9: return "armv7"
            case 11: return "armv7s"
            case 6: return "armv6"
            default: return "arm"
            }
        case .x86_64:
            return "x86_64"
        case .x86:
            return "i386"
        case .other(let raw):
            return "cpu \(raw)"
        }
    }

    static func fileTypeName(_ type: UInt32) -> String {
        switch type {
        case 0x1: return "Object"
        case 0x2: return "Executable"
        case 0x3: return "Fixed VM library"
        case 0x4: return "Core"
        case 0x5: return "Preload"
        case 0x6: return "Dynamic library"
        case 0x7: return "Dynamic linker"
        case 0x8: return "Bundle"
        case 0x9: return "Dynamic library stub"
        case 0xA: return "dSYM"
        case 0xB: return "Kernel extension"
        default: return "File type \(type)"
        }
    }

    // MARK: - Bytes

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, order: MachOByteOrder) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        switch order {
        case .littleEndian:
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        case .bigEndian:
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int, order: MachOByteOrder) -> Int32? {
        readUInt32(bytes, at: offset, order: order).map { Int32(bitPattern: $0) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int, order: MachOByteOrder) -> UInt64? {
        guard let low = readUInt32(bytes, at: order == .littleEndian ? offset : offset + 4, order: order),
              let high = readUInt32(bytes, at: order == .littleEndian ? offset + 4 : offset, order: order) else {
            return nil
        }
        return (UInt64(high) << 32) | UInt64(low)
    }
}
