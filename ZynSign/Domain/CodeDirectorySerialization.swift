import Foundation

/// Calculated locations inside one serialized CodeDirectory. Offsets are
/// relative to the CodeDirectory blob, as required by the format.
struct CodeDirectoryLayout: Equatable, Hashable {
    let magic: UInt32
    let version: CodeDirectoryVersion
    let length: Int
    let headerLength: Int
    let identifierOffset: Int
    let teamIdentifierOffset: Int?
    let specialHashesOffset: Int
    let hashOffset: Int
    let codeHashesOffset: Int
    let specialSlotCount: Int
    let codeSlotCount: Int
    let hashSize: Int

    var specialHashesRange: Range<Int> {
        specialHashesOffset..<hashOffset
    }

    var codeHashesRange: Range<Int> {
        codeHashesOffset..<length
    }

    func validate() throws {
        guard magic == CodeDirectory.magic else {
            throw CodeDirectoryError.invalidMagic(magic)
        }
        if case .unsupported(let rawVersion) = version {
            throw CodeDirectoryError.unsupportedVersion(rawVersion)
        }
        guard length >= headerLength,
              length >= 0,
              headerLength > 0,
              version.headerLength == headerLength,
              length <= CodeDirectory.maximumSerializedLength,
              identifierOffset >= headerLength,
              specialHashesOffset >= 0,
              specialHashesOffset >= identifierOffset,
              hashOffset >= 0,
              hashOffset >= specialHashesOffset,
              codeHashesOffset == hashOffset,
              length >= codeHashesOffset else {
            throw CodeDirectoryError.invalidOffset(.hashOffset)
        }
        guard specialSlotCount >= 0, codeSlotCount >= 0, hashSize > 0 else {
            throw CodeDirectoryError.invalidSlotCount
        }
        guard specialSlotCount <= CodeDirectory.maximumSpecialSlots,
              codeSlotCount <= CodeDirectory.maximumCodeSlots else {
            throw CodeDirectoryError.resourceLimitExceeded
        }
        let (specialLength, specialOverflow) = specialSlotCount.multipliedReportingOverflow(by: hashSize)
        let (codeLength, codeOverflow) = codeSlotCount.multipliedReportingOverflow(by: hashSize)
        guard !specialOverflow, !codeOverflow,
              specialHashesRange.count == specialLength,
              codeHashesRange.count == codeLength else {
            throw CodeDirectoryError.integerOverflow
        }
        guard specialHashesRange.lowerBound >= headerLength,
              specialHashesRange.upperBound <= length,
              codeHashesRange.lowerBound >= headerLength,
              codeHashesRange.upperBound <= length else {
            throw CodeDirectoryError.invalidLength
        }
        if let teamIdentifierOffset {
            guard teamIdentifierOffset >= headerLength,
                  teamIdentifierOffset < specialHashesOffset else {
                throw CodeDirectoryError.invalidOffset(.teamIdentifier)
            }
        }
    }
}

/// Serialized CodeDirectory bytes together with the independently calculated
/// structural metadata used by later SuperBlob construction.
struct CodeDirectorySerialization: Equatable, Hashable {
    let bytes: Data
    let layout: CodeDirectoryLayout

    func validate() throws {
        try layout.validate()
        guard bytes.count == layout.length else {
            throw CodeDirectoryError.invalidLength
        }
    }
}

/// Deterministic serializer for the construction-supported CodeDirectory
/// versions. It emits no SuperBlob, CMS, Mach-O load command, or padding
/// beyond the format's NUL-terminated strings and contiguous hash array.
struct CodeDirectorySerializer {
    init() {}

    func serialize(_ directory: CodeDirectory) throws -> CodeDirectorySerialization {
        try directory.validate()
        let layout = try makeLayout(for: directory)
        try layout.validate()

        var writer = CheckedBinaryWriter(maximumLength: CodeDirectory.maximumSerializedLength)
        let encodedLength = try writer.checkedUInt32(layout.length, field: .length)
        let encodedHashOffset = try writer.checkedUInt32(layout.hashOffset, field: .hashOffset)
        let encodedIdentifierOffset = try writer.checkedUInt32(layout.identifierOffset, field: .identifier)
        let encodedSpecialCount = try writer.checkedUInt32(directory.specialSlots.count, field: .specialHashes)
        let encodedCodeCount = try writer.checkedUInt32(directory.codeSlots.count, field: .codeHashes)
        guard let codeLimit = UInt32(exactly: directory.codeLimit),
              let hashSize = UInt8(exactly: directory.hashConfiguration.hashSize) else {
            throw CodeDirectoryError.integerOverflow
        }

        try writer.appendUInt32BigEndian(CodeDirectory.magic)
        try writer.appendUInt32BigEndian(encodedLength)
        try writer.appendUInt32BigEndian(directory.version.rawValue)
        try writer.appendUInt32BigEndian(directory.flags.rawValue)
        try writer.appendUInt32BigEndian(encodedHashOffset)
        try writer.appendUInt32BigEndian(encodedIdentifierOffset)
        try writer.appendUInt32BigEndian(encodedSpecialCount)
        try writer.appendUInt32BigEndian(encodedCodeCount)
        try writer.appendUInt32BigEndian(codeLimit)
        try writer.appendUInt8(hashSize)
        try writer.appendUInt8(directory.hashConfiguration.hashType.rawValue)
        try writer.appendUInt8(directory.platform)
        try writer.appendUInt8(directory.pageSize.exponent)
        try writer.appendUInt32BigEndian(0) // spare2

        if directory.version == .v20200 {
            try writer.appendUInt32BigEndian(0) // scatterOffset; not constructed
            let teamOffset = layout.teamIdentifierOffset ?? 0
            let encodedTeamOffset = try writer.checkedUInt32(teamOffset, field: .teamIdentifier)
            try writer.appendUInt32BigEndian(encodedTeamOffset)
        }
        guard writer.count == layout.identifierOffset else {
            throw CodeDirectoryError.invalidOffset(.identifier)
        }
        try writer.appendUTF8(directory.identifier.rawValue)
        if let teamIdentifier = directory.teamIdentifier {
            guard layout.teamIdentifierOffset == writer.count else {
                throw CodeDirectoryError.invalidOffset(.teamIdentifier)
            }
            try writer.appendUTF8(teamIdentifier.rawValue)
        }
        guard writer.count == layout.specialHashesOffset else {
            throw CodeDirectoryError.invalidOffset(.specialHashes)
        }

        // The first serialized special hash is slot -n. The model is indexed
        // positively (1 through n), so reverse it explicitly.
        for slot in directory.specialSlots.reversed() {
            if let hash = slot.hash {
                try writer.appendData(hash)
            } else {
                try writer.appendData(Data(repeating: 0, count: layout.hashSize))
            }
        }
        guard writer.count == layout.hashOffset else {
            throw CodeDirectoryError.invalidOffset(.hashOffset)
        }
        for slot in directory.codeSlots {
            try writer.appendData(slot.hash)
        }
        guard writer.count == layout.length else {
            throw CodeDirectoryError.invalidLength
        }
        let serialization = CodeDirectorySerialization(bytes: writer.data, layout: layout)
        try serialization.validate()
        return serialization
    }

    private func makeLayout(for directory: CodeDirectory) throws -> CodeDirectoryLayout {
        let headerLength = directory.version.headerLength
        guard headerLength > 0 else {
            throw CodeDirectoryError.unsupportedVersion(directory.version.rawValue)
        }
        let identifierLength = try checkedAdd(directory.identifier.rawValue.utf8.count, 1)
        let teamLength: Int
        if let teamIdentifier = directory.teamIdentifier {
            teamLength = try checkedAdd(teamIdentifier.rawValue.utf8.count, 1)
        } else {
            teamLength = 0
        }
        let identifierOffset = headerLength
        let afterIdentifier = try checkedAdd(identifierOffset, identifierLength)
        let teamOffset: Int?
        let afterStrings: Int
        if let _ = directory.teamIdentifier {
            guard directory.version.supportsTeamIdentifier else {
                throw CodeDirectoryError.unsupportedFeature(.teamIdentifier)
            }
            teamOffset = afterIdentifier
            afterStrings = try checkedAdd(afterIdentifier, teamLength)
        } else {
            teamOffset = nil
            afterStrings = afterIdentifier
        }
        let specialLength = try checkedMultiply(
            directory.specialSlots.count,
            directory.hashConfiguration.hashSize
        )
        let codeLength = try checkedMultiply(
            directory.codeSlots.count,
            directory.hashConfiguration.hashSize
        )
        let hashOffset = try checkedAdd(afterStrings, specialLength)
        let length = try checkedAdd(hashOffset, codeLength)
        guard length <= CodeDirectory.maximumSerializedLength else {
            throw CodeDirectoryError.resourceLimitExceeded
        }
        return CodeDirectoryLayout(
            magic: CodeDirectory.magic,
            version: directory.version,
            length: length,
            headerLength: headerLength,
            identifierOffset: identifierOffset,
            teamIdentifierOffset: teamOffset,
            specialHashesOffset: afterStrings,
            hashOffset: hashOffset,
            codeHashesOffset: hashOffset,
            specialSlotCount: directory.specialSlots.count,
            codeSlotCount: directory.codeSlots.count,
            hashSize: directory.hashConfiguration.hashSize
        )
    }

    private func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw CodeDirectoryError.integerOverflow }
        return value
    }

    private func checkedMultiply(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw CodeDirectoryError.integerOverflow }
        return value
    }
}

extension CodeDirectory {
    func serialize() throws -> CodeDirectorySerialization {
        try CodeDirectorySerializer().serialize(self)
    }
}
