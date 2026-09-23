@testable import ZynSign

/// Tiny hand-assembled test bytes, not signed binaries. These records encode
/// just the published headers and enough dummy hash bytes to inspect ranges;
/// none of the hash values or payloads is cryptographically meaningful.
enum MachOFixtures {
    static let arm64: Int32 = 0x0100_000C
    static let x86_64: Int32 = 0x0100_0007

    static func number(_ value: UInt64, width: Int, order: MachOByteOrder) -> [UInt8] {
        let shifts = (0..<width).map { $0 * 8 }
        let positions = order == .bigEndian ? Array(shifts.reversed()) : shifts
        return positions.map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    static func put(_ value: UInt64, width: Int = 4, at offset: Int,
                    in bytes: inout [UInt8], order: MachOByteOrder = .bigEndian) {
        bytes.replaceSubrange(offset..<(offset + width), with: number(value, width: width, order: order))
    }

    static func command(_ type: UInt32, size: Int = 8,
                        order: MachOByteOrder = .littleEndian) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        put(UInt64(type), at: 0, in: &bytes, order: order)
        put(UInt64(size), at: 4, in: &bytes, order: order)
        return bytes
    }

    static func thin(
        wordSize: MachOWordSize = .bits64,
        order: MachOByteOrder = .littleEndian,
        cpu: Int32 = arm64,
        subtype: Int32 = 0,
        commands: [[UInt8]] = [],
        headerPadding: [UInt8] = [],
        payload: [UInt8] = []
    ) -> [UInt8] {
        let headerSize = wordSize == .bits64 ? 32 : 28
        var bytes = [UInt8](repeating: 0, count: headerSize)
        let magic: UInt32 = wordSize == .bits64 ? 0xFEEDFACF : 0xFEEDFACE
        put(UInt64(magic), at: 0, in: &bytes, order: order)
        put(UInt64(UInt32(bitPattern: cpu)), at: 4, in: &bytes, order: order)
        put(UInt64(UInt32(bitPattern: subtype)), at: 8, in: &bytes, order: order)
        put(2, at: 12, in: &bytes, order: order) // MH_EXECUTE
        put(UInt64(commands.count), at: 16, in: &bytes, order: order)
        put(UInt64(commands.reduce(0) { $0 + $1.count }), at: 20, in: &bytes, order: order)
        put(0x20, at: 24, in: &bytes, order: order)
        for command in commands { bytes.append(contentsOf: command) }
        bytes.append(contentsOf: headerPadding)
        bytes.append(contentsOf: payload)
        return bytes
    }

    static func signedThin(
        _ signature: [UInt8], wordSize: MachOWordSize = .bits64,
        order: MachOByteOrder = .littleEndian,
        cpu: Int32 = arm64, subtype: Int32 = 0
    ) -> [UInt8] {
        let headerSize = wordSize == .bits64 ? 32 : 28
        var commandBytes = command(0x1D, size: 16, order: order)
        put(UInt64(headerSize + 16), at: 8, in: &commandBytes, order: order)
        put(UInt64(signature.count), at: 12, in: &commandBytes, order: order)
        return thin(wordSize: wordSize, order: order, cpu: cpu, subtype: subtype,
                    commands: [commandBytes], payload: signature)
    }

    /// A minimal `LC_SEGMENT_64`, sufficient for parser and append-writer
    /// layout tests. It intentionally contains no sections so the segment's
    /// file range establishes the first file-backed content boundary.
    static func segment64(
        name: String = "__LINKEDIT",
        fileOffset: UInt64,
        fileSize: UInt64,
        virtualMemorySize: UInt64,
        order: MachOByteOrder = .littleEndian
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 72)
        put(0x19, at: 0, in: &bytes, order: order)
        put(72, at: 4, in: &bytes, order: order)
        let nameBytes = Array(name.utf8.prefix(16))
        bytes.replaceSubrange(8..<(8 + nameBytes.count), with: nameBytes)
        put(virtualMemorySize, width: 8, at: 32, in: &bytes, order: order)
        put(fileOffset, width: 8, at: 40, in: &bytes, order: order)
        put(fileSize, width: 8, at: 48, in: &bytes, order: order)
        put(0, at: 64, in: &bytes, order: order)
        return bytes
    }

    /// An unsigned thin image with enough verified zero header padding and an
    /// existing `__LINKEDIT` virtual-memory reservation for append-only tests.
    static func appendableThin(
        payload: [UInt8] = Array(repeating: 0xA5, count: 32),
        headerPaddingLength: Int = 24,
        virtualMemorySize: UInt64 = 4_096,
        order: MachOByteOrder = .littleEndian
    ) -> [UInt8] {
        let fileOffset = UInt64(32 + 72 + headerPaddingLength)
        let segment = segment64(
            fileOffset: fileOffset,
            fileSize: UInt64(payload.count),
            virtualMemorySize: virtualMemorySize,
            order: order
        )
        return thin(
            wordSize: .bits64,
            order: order,
            commands: [segment],
            headerPadding: Array(repeating: 0, count: headerPaddingLength),
            payload: payload
        )
    }

    static func genericBlob(_ magic: UInt32, payload: [UInt8] = []) -> [UInt8] {
        number(UInt64(magic), width: 4, order: .bigEndian)
            + number(UInt64(8 + payload.count), width: 4, order: .bigEndian) + payload
    }

    static func superBlob(_ members: [(UInt32, [UInt8])]) -> [UInt8] {
        var bytes = number(0xFADE0CC0, width: 4, order: .bigEndian)
            + [UInt8](repeating: 0, count: 8 + members.count * 8)
        put(UInt64(members.count), at: 8, in: &bytes)
        for (index, member) in members.enumerated() {
            put(UInt64(member.0), at: 12 + index * 8, in: &bytes)
            put(UInt64(bytes.count), at: 16 + index * 8, in: &bytes)
            bytes.append(contentsOf: member.1)
        }
        put(UInt64(bytes.count), at: 4, in: &bytes)
        return bytes
    }

    static func codeDirectory(
        version: UInt32 = 0x20500,
        codeLimit: UInt32 = 48,
        extendedCodeLimit: UInt64 = 0,
        hashType: UInt8 = 2,
        hashSize: Int = 32,
        specialCount: Int = 1,
        codeCount: Int = 1,
        identifier: String = "com.example.test",
        team: String? = "EXAMPLETEAM",
        scatter: Bool = false,
        preEncrypt: Bool = false,
        linkage: [UInt8] = []
    ) -> [UInt8] {
        let fixed: Int
        switch version {
        case ..<0x20100: fixed = 44
        case ..<0x20200: fixed = 48
        case ..<0x20300: fixed = 52
        case ..<0x20400: fixed = 64
        case ..<0x20500: fixed = 88
        case ..<0x20600: fixed = 96
        default: fixed = 108
        }
        var bytes = [UInt8](repeating: 0, count: fixed)
        put(0xFADE0C02, at: 0, in: &bytes)
        put(UInt64(version), at: 8, in: &bytes)
        put(0x20000, at: 12, in: &bytes)
        put(UInt64(specialCount), at: 24, in: &bytes)
        put(UInt64(codeCount), at: 28, in: &bytes)
        put(UInt64(codeLimit), at: 32, in: &bytes)
        bytes[36] = UInt8(hashSize)
        bytes[37] = hashType
        bytes[39] = 12
        if version >= 0x20300 { put(extendedCodeLimit, width: 8, at: 56, in: &bytes) }
        if version >= 0x20400 { put(0x100, width: 8, at: 72, in: &bytes) }
        if version >= 0x20500 { put(0x0001_0000, at: 88, in: &bytes) }
        put(UInt64(bytes.count), at: 20, in: &bytes)
        bytes += Array(identifier.utf8) + [0]
        if version >= 0x20200, let team = team {
            put(UInt64(bytes.count), at: 48, in: &bytes)
            bytes += Array(team.utf8) + [0]
        }
        if version >= 0x20100, scatter {
            put(UInt64(bytes.count), at: 44, in: &bytes)
            // One page at target offset zero, then the sentinel.
            bytes += number(1, width: 4, order: .bigEndian)
                + number(0, width: 4, order: .bigEndian)
                + [UInt8](repeating: 0, count: 16)
                + [UInt8](repeating: 0, count: 24)
        }
        if version >= 0x20500, preEncrypt {
            put(UInt64(bytes.count), at: 92, in: &bytes)
            bytes += [UInt8](repeating: 0x33, count: codeCount * hashSize)
        }
        if version >= 0x20600, !linkage.isEmpty {
            bytes[96] = 2
            bytes[97] = 1
            put(2, width: 2, at: 98, in: &bytes)
            put(UInt64(bytes.count), at: 100, in: &bytes)
            put(UInt64(linkage.count), at: 104, in: &bytes)
            bytes += linkage
        }
        let hashOffset = bytes.count + specialCount * hashSize
        put(UInt64(hashOffset), at: 16, in: &bytes)
        bytes += [UInt8](repeating: 0, count: (specialCount + codeCount) * hashSize)
        if specialCount > 0 { bytes[hashOffset - hashSize] = 0xA5 } // slot -1 only
        put(UInt64(bytes.count), at: 4, in: &bytes)
        return bytes
    }

    static func fat(
        _ members: [(cpu: Int32, subtype: Int32, bytes: [UInt8])],
        magic: MachOUniversalMagic = .fat32,
        order: MachOByteOrder = .bigEndian,
        alignmentExponent: UInt32 = 2
    ) -> [UInt8] {
        let recordSize = magic == .fat64 ? 32 : 20
        var bytes = [UInt8](repeating: 0, count: 8 + members.count * recordSize)
        put(UInt64(magic.rawValue), at: 0, in: &bytes, order: order)
        put(UInt64(members.count), at: 4, in: &bytes, order: order)
        for (index, member) in members.enumerated() {
            while bytes.count % (1 << Int(alignmentExponent)) != 0 { bytes.append(0) }
            let start = 8 + index * recordSize
            put(UInt64(UInt32(bitPattern: member.cpu)), at: start, in: &bytes, order: order)
            put(UInt64(UInt32(bitPattern: member.subtype)), at: start + 4, in: &bytes, order: order)
            if magic == .fat64 {
                put(UInt64(bytes.count), width: 8, at: start + 8, in: &bytes, order: order)
                put(UInt64(member.bytes.count), width: 8, at: start + 16, in: &bytes, order: order)
                put(UInt64(alignmentExponent), at: start + 24, in: &bytes, order: order)
            } else {
                put(UInt64(bytes.count), at: start + 8, in: &bytes, order: order)
                put(UInt64(member.bytes.count), at: start + 12, in: &bytes, order: order)
                put(UInt64(alignmentExponent), at: start + 16, in: &bytes, order: order)
            }
            bytes += member.bytes
        }
        return bytes
    }
}
