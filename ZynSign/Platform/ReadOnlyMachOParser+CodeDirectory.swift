import Foundation

extension ReadOnlyMachOParser {
    private struct CodeDirectoryHeader {
        let version: UInt32
        let fixedSize: Int
        let flags: UInt32
        let hashOffset: Int
        let identifierOffset: Int
        let specialCount: Int
        let codeCount: Int
        let codeLimit: UInt32
        let hashSize: Int
        let hashType: MachOHashType
        let platform: UInt8
        let pageSize: UInt8
    }

    private struct CodeDirectoryHashRanges {
        let all: Range<Int>
        let code: Range<Int>
        let start: Int
    }

    private struct CodeDirectoryIdentity {
        let identifier: String
        let team: String?
        let occupiedRanges: [Range<Int>]
    }

    private struct CodeDirectoryLinkage {
        let value: MachOLinkage?
        let fileRange: Range<Int>?
    }

    static func codeDirectory(
        in blob: BoundedBinaryReader,
        signatureOffset: Int?
    ) throws -> MachOCodeDirectory {
        let header = try codeDirectoryHeader(in: blob)
        let hashes = try codeDirectoryHashRanges(in: blob, header: header)
        let identity = try codeDirectoryIdentity(in: blob, header: header, hashesStart: hashes.start)
        let limits = try codeDirectoryLimits(in: blob, header: header, signatureOffset: signatureOffset)
        let segment = try executableSegment(in: blob, header: header)
        let runtime = try runtimeVersion(in: blob, header: header)
        let scatter = try scatterTable(in: blob, header: header, hashesStart: hashes.start)
        try validateCodeSlotCoverage(header: header, effectiveLimit: limits.effective)
        let preEncryptHashes = try preEncryptHashRange(in: blob, header: header)
        let linkage = try codeDirectoryLinkage(in: blob, header: header)

        var occupied = identity.occupiedRanges
        if let range = scatter?.fileRange { occupied.append(range) }
        if let preEncryptHashes { occupied.append(preEncryptHashes) }
        if let range = linkage.fileRange { occupied.append(range) }
        try validateCodeDirectoryRanges(occupied, hashes: hashes.all)
        let specialSlots = try specialHashSlots(in: blob, header: header)
        let codeHashes = try codeHashValues(in: blob, header: header)

        return MachOCodeDirectory(
            version: header.version,
            flags: header.flags,
            identifier: identity.identifier,
            teamIdentifier: identity.team,
            hashOffset: header.hashOffset,
            hashType: header.hashType,
            hashSize: header.hashSize,
            platform: header.platform,
            pageSizeExponent: header.pageSize,
            codeSlotCount: header.codeCount,
            specialSlotCount: header.specialCount,
            codeLimit: header.codeLimit,
            codeLimit64: limits.extended,
            codeHashesRange: hashes.code,
            codeHashes: codeHashes,
            specialSlots: specialSlots,
            scatter: scatter,
            executableSegment: segment,
            runtime: runtime,
            preEncryptHashesRange: preEncryptHashes,
            linkage: linkage.value
        )
    }

    private static func codeDirectoryHeader(in blob: BoundedBinaryReader) throws -> CodeDirectoryHeader {
        let boundary: MachOParsingError.Boundary = .codeDirectory
        _ = try blob.checkedRange(at: 0, length: 12, boundary: boundary)
        let version = try blob.uint32(at: 8, order: .bigEndian, boundary: boundary)
        guard version >= 0x20001, version <= 0x20600 else {
            throw MachOParsingError(.unsupportedCodeDirectoryVersion, at: boundary, version: version)
        }
        let fixedSize = codeDirectoryFixedSize(for: version)
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
        guard specialCount <= maximumSpecialSlots, codeCount <= maximumCodeSlots else {
            throw MachOParsingError(.resourceLimitExceeded, at: .hashSlots)
        }
        guard hashOffset >= fixedSize, hashOffset <= blob.count else {
            throw MachOParsingError(.invalidOffset, at: .hashSlots)
        }
        return CodeDirectoryHeader(
            version: version,
            fixedSize: fixedSize,
            flags: flags,
            hashOffset: hashOffset,
            identifierOffset: identifierOffset,
            specialCount: specialCount,
            codeCount: codeCount,
            codeLimit: codeLimit,
            hashSize: hashSize,
            hashType: hashType,
            platform: platform,
            pageSize: pageSize
        )
    }

    private static func codeDirectoryFixedSize(for version: UInt32) -> Int {
        switch version {
        case ..<0x20100: return 44
        case ..<0x20200: return 48
        case ..<0x20300: return 52
        case ..<0x20400: return 64
        case ..<0x20500: return 88
        case ..<0x20600: return 96
        default: return 108
        }
    }

    private static func codeDirectoryHashRanges(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> CodeDirectoryHashRanges {
        let specialBytes = header.specialCount * header.hashSize
        guard specialBytes <= header.hashOffset - header.fixedSize,
              header.codeCount <= (blob.count - header.hashOffset) / header.hashSize else {
            throw MachOParsingError(.invalidLength, at: .hashSlots)
        }
        let start = header.hashOffset - specialBytes
        let length = specialBytes + header.codeCount * header.hashSize
        let all = try blob.checkedRange(at: start, length: length, boundary: .hashSlots)
        let code = try blob.checkedRange(
            at: header.hashOffset,
            length: header.codeCount * header.hashSize,
            boundary: .hashSlots
        )
        return CodeDirectoryHashRanges(all: all, code: code, start: start)
    }

    private static func codeDirectoryIdentity(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader,
        hashesStart: Int
    ) throws -> CodeDirectoryIdentity {
        let (identifier, identifierRange) = try text(
            in: blob,
            at: header.identifierOffset,
            before: hashesStart,
            after: header.fixedSize,
            boundary: .identifier
        )
        var occupiedRanges = [identifierRange]
        let teamOffset: Int? = header.version >= 0x20200
            ? try blob.uint32AsInt(
                at: 48, order: .bigEndian, boundary: .teamIdentifier, ifUnrepresentable: .invalidOffset
            ) : nil
        let team: String?
        if let offset = teamOffset, offset != 0 {
            let (value, range) = try text(
                in: blob,
                at: offset,
                before: hashesStart,
                after: header.fixedSize,
                boundary: .teamIdentifier
            )
            team = value
            occupiedRanges.append(range)
        } else {
            team = nil
        }
        return CodeDirectoryIdentity(identifier: identifier, team: team, occupiedRanges: occupiedRanges)
    }

    private static func codeDirectoryLimits(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader,
        signatureOffset: Int?
    ) throws -> (extended: UInt64?, effective: UInt64) {
        let extended: UInt64? = header.version >= 0x20300
            ? try blob.uint64(at: 56, order: .bigEndian, boundary: .codeDirectory) : nil
        let effective = extended.flatMap { $0 == 0 ? nil : $0 } ?? UInt64(header.codeLimit)
        if let signatureOffset, effective > UInt64(signatureOffset) {
            throw MachOParsingError(.malformedCodeDirectory, at: .codeDirectory)
        }
        return (extended, effective)
    }

    private static func executableSegment(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> MachOExecutableSegment? {
        guard header.version >= 0x20400 else { return nil }
        return MachOExecutableSegment(
            base: try blob.uint64(at: 64, order: .bigEndian, boundary: .codeDirectory),
            limit: try blob.uint64(at: 72, order: .bigEndian, boundary: .codeDirectory),
            flags: try blob.uint64(at: 80, order: .bigEndian, boundary: .codeDirectory)
        )
    }

    private static func runtimeVersion(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> UInt32? {
        guard header.version >= 0x20500 else { return nil }
        return try blob.uint32(at: 88, order: .bigEndian, boundary: .codeDirectory)
    }

    private static func scatterTable(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader,
        hashesStart: Int
    ) throws -> MachOScatterTable? {
        guard header.version >= 0x20100 else { return nil }
        let offset = try blob.uint32AsInt(
            at: 44, order: .bigEndian, boundary: .scatter, ifUnrepresentable: .invalidOffset
        )
        guard offset != 0 else { return nil }
        return try scatterTable(
            in: blob,
            at: offset,
            after: header.fixedSize,
            before: hashesStart,
            codeCount: header.codeCount
        )
    }

    private static func validateCodeSlotCoverage(
        header: CodeDirectoryHeader,
        effectiveLimit: UInt64
    ) throws {
        let expected: UInt64
        if header.pageSize == 0 {
            expected = effectiveLimit == 0 ? 0 : 1
        } else {
            guard effectiveLimit > 0 else {
                throw MachOParsingError(.malformedCodeDirectory, at: .hashSlots)
            }
            let pageBytes = UInt64(1) << header.pageSize
            expected = effectiveLimit / pageBytes + (effectiveLimit % pageBytes == 0 ? 0 : 1)
        }
        guard expected == UInt64(header.codeCount) else {
            throw MachOParsingError(.malformedCodeDirectory, at: .hashSlots)
        }
    }

    private static func preEncryptHashRange(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> Range<Int>? {
        guard header.version >= 0x20500 else { return nil }
        let offset = try blob.uint32AsInt(
            at: 92, order: .bigEndian, boundary: .preEncryptHashes, ifUnrepresentable: .invalidOffset
        )
        guard offset != 0 else { return nil }
        guard offset >= header.fixedSize, header.codeCount > 0 else {
            throw MachOParsingError(.invalidOffset, at: .preEncryptHashes)
        }
        return try blob.checkedRange(
            at: offset,
            length: header.codeCount * header.hashSize,
            boundary: .preEncryptHashes,
            ifTooLong: .invalidLength
        )
    }

    private static func codeDirectoryLinkage(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> CodeDirectoryLinkage {
        guard header.version >= 0x20600 else {
            return CodeDirectoryLinkage(value: nil, fileRange: nil)
        }
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
        let range: Range<Int>?
        if length > 0 {
            guard offset >= header.fixedSize else {
                throw MachOParsingError(.invalidOffset, at: .linkage)
            }
            range = try blob.checkedRange(at: offset, length: length, boundary: .linkage, ifTooLong: .invalidLength)
        } else {
            range = nil
        }
        let value = MachOLinkage(
            hashType: hash,
            applicationType: application,
            applicationSubtype: subtype,
            dataRange: range
        )
        return CodeDirectoryLinkage(value: value, fileRange: range)
    }

    private static func validateCodeDirectoryRanges(
        _ occupied: [Range<Int>],
        hashes: Range<Int>
    ) throws {
        for (index, range) in occupied.enumerated() {
            guard !range.overlaps(hashes),
                  !occupied[..<index].contains(where: { $0.overlaps(range) }) else {
                throw MachOParsingError(.malformedCodeDirectory, at: .codeDirectory)
            }
        }
    }

    private static func specialHashSlots(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> [MachOSpecialHashSlot] {
        var slots: [MachOSpecialHashSlot] = []
        slots.reserveCapacity(header.specialCount)
        if header.specialCount > 0 {
            for number in 1...header.specialCount {
                let position = header.hashOffset - number * header.hashSize
                let slot = try blob.view(at: position, length: header.hashSize, boundary: .hashSlots)
                let hash = try blob.data(at: position, length: header.hashSize, boundary: .hashSlots)
                let nonzero = try hasNonzeroByte(in: slot, count: header.hashSize)
                slots.append(MachOSpecialHashSlot(
                    slotNumber: -number,
                    kind: MachOSpecialHashKind(slotNumber: number),
                    hashRange: slot.fileRange,
                    hash: hash,
                    hasNonzeroBytes: nonzero
                ))
            }
        }
        return slots
    }

    private static func hasNonzeroByte(in slot: BoundedBinaryReader, count: Int) throws -> Bool {
        for byte in 0..<count {
            if try slot.uint8(at: byte, boundary: .hashSlots) != 0 {
                return true
            }
        }
        return false
    }

    private static func codeHashValues(
        in blob: BoundedBinaryReader,
        header: CodeDirectoryHeader
    ) throws -> [Data] {
        var values: [Data] = []
        values.reserveCapacity(header.codeCount)
        for index in 0..<header.codeCount {
            let position = header.hashOffset + index * header.hashSize
            values.append(try blob.data(at: position, length: header.hashSize, boundary: .hashSlots))
        }
        return values
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
