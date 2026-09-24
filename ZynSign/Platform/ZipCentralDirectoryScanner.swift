import Foundation

/// One entry as read from a ZIP container's central directory.
///
/// The record pairs the domain-facing description of the entry with the
/// container details needed to reach its content later. Nothing here is
/// trusted: every size, offset, and name came from the archive itself and is
/// re-checked against the file's bounds before it is used.
struct ZipCentralDirectoryRecord: Equatable {

    /// The domain-facing description of the entry.
    let entry: ArchiveEntry

    /// The container's encoding for the entry's content.
    let compressionMethod: UInt16

    /// Where the entry's local header begins, in bytes from the start of the
    /// container.
    let localHeaderOffset: Int

    /// The checksum the container records for the entry's expanded content.
    let checksum: UInt32

    /// Whether the container marks the entry as encrypted.
    let isEncrypted: Bool
}

/// Reads the entry table of a ZIP container without expanding any of it.
///
/// The scanner reads only the structures that describe the container — its
/// end-of-central-directory record and its central directory — and produces
/// one domain entry per record. Entry content is never read here, and nothing
/// is written anywhere: inspecting a package costs a few bounded reads at the
/// end of the file plus one pass over its central directory, whatever the
/// package contains.
///
/// Reading is mediated by a caller-supplied closure rather than a file handle,
/// so the parsing rules can be exercised against synthetic bytes without a
/// filesystem.
///
/// Scope is deliberately partial. This is a read-only inspector, not a ZIP
/// implementation: it does not write, update, span, or decrypt containers, and
/// it supports the two content encodings application packages use — stored and
/// deflate — reporting anything else as unsupported rather than guessing.
enum ZipCentralDirectoryScanner {

    /// Scans a container and returns its entry table in container order.
    ///
    /// - Parameters:
    ///   - fileSize: The container's size in bytes.
    ///   - limits: The resource policy to apply. Scanning stops once the entry
    ///     count exceeds `limits.maximumEntryCount`, so the returned table can
    ///     be one entry longer than the policy allows and is then reported as
    ///     exceeding it rather than being scanned to completion.
    ///   - read: Produces the requested bytes, or fails.
    static func scan(
        fileSize: Int,
        limits: ArchiveLimits,
        read: (Int, Int) throws -> [UInt8]
    ) throws -> [ZipCentralDirectoryRecord] {
        guard fileSize >= endOfCentralDirectorySize else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The file is smaller than the smallest possible ZIP archive."
            )
        }

        let searchLength = min(fileSize, endOfCentralDirectorySize + maximumCommentLength)
        let searchStart = fileSize - searchLength
        let tail = try read(searchStart, searchLength)
        guard tail.count == searchLength else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The end of the archive could not be read."
            )
        }
        guard let endOffset = locateEndOfCentralDirectory(in: tail) else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "No ZIP end-of-central-directory record was found."
            )
        }

        let location = try centralDirectoryLocation(
            recordCount: Int(ZipField.uint16(tail, endOffset + 10)),
            directorySize: Int(ZipField.uint32(tail, endOffset + 12)),
            directoryOffset: Int(ZipField.uint32(tail, endOffset + 16)),
            endRecordOffsetInFile: searchStart + endOffset,
            fileSize: fileSize,
            read: read
        )

        return try readCentralDirectory(
            location: location,
            limits: limits,
            read: read
        )
    }

    // MARK: - Constants

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndLocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndRecordSignature: UInt32 = 0x0606_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50

    private static let endOfCentralDirectorySize = 22
    private static let zip64LocatorSize = 20
    private static let zip64RecordSize = 56
    private static let centralDirectoryRecordSize = 46
    private static let maximumCommentLength = 65_535
    private static let zip64ExtraFieldTag: UInt16 = 0x0001
    private static let zip64Placeholder32: UInt32 = 0xFFFF_FFFF

    // MARK: - Structure location

    /// Finds the end-of-central-directory signature, scanning backwards so
    /// that a trailing comment cannot hide it and a stray occurrence inside a
    /// comment is preferred only when nothing later exists.
    private static func locateEndOfCentralDirectory(in tail: [UInt8]) -> Int? {
        var offset = tail.count - endOfCentralDirectorySize
        while offset >= 0 {
            if ZipField.uint32(tail, offset) == endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private struct DirectoryLocation {
        let recordCount: Int
        let offset: Int
        let size: Int
    }

    /// Resolves where the central directory begins, preferring the ZIP64
    /// structures when a container carries them and falling back to the
    /// ordinary fields when it does not.
    private static func centralDirectoryLocation(
        recordCount: Int,
        directorySize: Int,
        directoryOffset: Int,
        endRecordOffsetInFile: Int,
        fileSize: Int,
        read: (Int, Int) throws -> [UInt8]
    ) throws -> DirectoryLocation {
        let ordinaryLocation = DirectoryLocation(
            recordCount: recordCount,
            offset: directoryOffset,
            size: directorySize
        )

        // A saturated field is how a container announces ZIP64 addressing, but
        // it is also the ordinary value a large non-ZIP64 container records.
        // The ZIP64 structures are therefore used when they are present and
        // skipped when they are not, rather than being demanded.
        guard endRecordOffsetInFile >= zip64LocatorSize else {
            return try validatedLocation(ordinaryLocation, fileSize: fileSize)
        }
        let locator = try read(endRecordOffsetInFile - zip64LocatorSize, zip64LocatorSize)
        guard locator.count == zip64LocatorSize,
              ZipField.uint32(locator, 0) == zip64EndLocatorSignature else {
            return try validatedLocation(ordinaryLocation, fileSize: fileSize)
        }
        guard let recordOffset = Int(exactly: ZipField.uint64(locator, 8)),
              recordOffset >= 0,
              recordOffset + zip64RecordSize <= fileSize else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's ZIP64 record lies outside the file."
            )
        }
        let record = try read(recordOffset, zip64RecordSize)
        guard record.count == zip64RecordSize,
              ZipField.uint32(record, 0) == zip64EndRecordSignature else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's ZIP64 record is not readable."
            )
        }
        guard let extendedRecordCount = Int(exactly: ZipField.uint64(record, 32)),
              let extendedSize = Int(exactly: ZipField.uint64(record, 40)),
              let extendedOffset = Int(exactly: ZipField.uint64(record, 48)) else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's ZIP64 record declares sizes this platform cannot address."
            )
        }
        return try validatedLocation(
            DirectoryLocation(
                recordCount: extendedRecordCount,
                offset: extendedOffset,
                size: extendedSize
            ),
            fileSize: fileSize
        )
    }

    private static func validatedLocation(
        _ location: DirectoryLocation,
        fileSize: Int
    ) throws -> DirectoryLocation {
        guard location.recordCount >= 0,
              location.offset >= 0,
              location.size >= 0,
              location.offset + location.size <= fileSize else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's central directory does not lie within the file."
            )
        }
        return location
    }

    // MARK: - Central directory

    private static func readCentralDirectory(
        location: DirectoryLocation,
        limits: ArchiveLimits,
        read: (Int, Int) throws -> [UInt8]
    ) throws -> [ZipCentralDirectoryRecord] {
        var records: [ZipCentralDirectoryRecord] = []
        var position = location.offset
        let end = location.offset + location.size

        while position + centralDirectoryRecordSize <= end {
            let header = try read(position, centralDirectoryRecordSize)
            guard header.count == centralDirectoryRecordSize else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive's central directory is truncated."
                )
            }
            guard ZipField.uint32(header, 0) == centralDirectorySignature else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive's central directory holds a record with an unrecognized signature."
                )
            }

            let versionMadeBy = ZipField.uint16(header, 4)
            let flags = ZipField.uint16(header, 8)
            let compressionMethod = ZipField.uint16(header, 10)
            let checksum = ZipField.uint32(header, 16)
            var compressedSize = Int(ZipField.uint32(header, 20))
            var uncompressedSize = Int(ZipField.uint32(header, 24))
            let nameLength = Int(ZipField.uint16(header, 28))
            let extraLength = Int(ZipField.uint16(header, 30))
            let commentLength = Int(ZipField.uint16(header, 32))
            let externalAttributes = ZipField.uint32(header, 38)
            var localHeaderOffset = Int(ZipField.uint32(header, 42))

            let variableLength = nameLength + extraLength + commentLength
            guard position + centralDirectoryRecordSize + variableLength <= end else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive's central directory is truncated."
                )
            }
            var variable: [UInt8] = []
            if variableLength > 0 {
                variable = try read(position + centralDirectoryRecordSize, variableLength)
            }
            guard variable.count == variableLength else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive's central directory is truncated."
                )
            }
            let nameBytes = Array(variable[0..<nameLength])
            let extraBytes = Array(variable[nameLength..<(nameLength + extraLength)])
            position += centralDirectoryRecordSize + variableLength

            if ZipField.uint32(header, 24) == zip64Placeholder32
                || ZipField.uint32(header, 20) == zip64Placeholder32
                || ZipField.uint32(header, 42) == zip64Placeholder32 {
                applyZip64Sizes(
                    extraBytes,
                    uncompressedSize: &uncompressedSize,
                    compressedSize: &compressedSize,
                    localHeaderOffset: &localHeaderOffset,
                    uncompressedIsExtended: ZipField.uint32(header, 24) == zip64Placeholder32,
                    compressedIsExtended: ZipField.uint32(header, 20) == zip64Placeholder32,
                    offsetIsExtended: ZipField.uint32(header, 42) == zip64Placeholder32
                )
            }

            let decodedName = String(bytes: nameBytes, encoding: .utf8)
            let kind = entryKind(
                versionMadeBy: versionMadeBy,
                externalAttributes: externalAttributes,
                nameEndsWithSeparator: decodedName?.hasSuffix("/") ?? false
            )
            let entry = makeEntry(
                nameBytes: nameBytes,
                decodedName: decodedName,
                kind: kind,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                unixMode: recordedUnixMode(
                    versionMadeBy: versionMadeBy,
                    externalAttributes: externalAttributes
                ),
                limits: limits
            )

            records.append(
                ZipCentralDirectoryRecord(
                    entry: entry,
                    compressionMethod: compressionMethod,
                    localHeaderOffset: localHeaderOffset,
                    checksum: checksum,
                    isEncrypted: (flags & 0x0001) != 0
                )
            )

            if records.count > limits.maximumEntryCount {
                break
            }
        }

        return records
    }

    /// Applies the ZIP64 extra field's extended sizes, which appear only for
    /// the fields whose ordinary counterparts are saturated and always in the
    /// same order.
    private static func applyZip64Sizes(
        _ extraBytes: [UInt8],
        uncompressedSize: inout Int,
        compressedSize: inout Int,
        localHeaderOffset: inout Int,
        uncompressedIsExtended: Bool,
        compressedIsExtended: Bool,
        offsetIsExtended: Bool
    ) {
        let values = zip64Values(in: extraBytes)
        var next = 0
        func takeValue() -> Int? {
            guard next < values.count, let value = Int(exactly: values[next]) else { return nil }
            next += 1
            return value
        }
        if uncompressedIsExtended, let value = takeValue() { uncompressedSize = value }
        if compressedIsExtended, let value = takeValue() { compressedSize = value }
        if offsetIsExtended, let value = takeValue() { localHeaderOffset = value }
    }

    private static func zip64Values(in extraBytes: [UInt8]) -> [UInt64] {
        var values: [UInt64] = []
        var position = 0
        while position + 4 <= extraBytes.count {
            let tag = ZipField.uint16(extraBytes, position)
            let size = Int(ZipField.uint16(extraBytes, position + 2))
            let dataStart = position + 4
            guard size >= 0, dataStart + size <= extraBytes.count else { break }
            if tag == zip64ExtraFieldTag {
                var field = dataStart
                while field + 8 <= dataStart + size {
                    values.append(ZipField.uint64(extraBytes, field))
                    field += 8
                }
            }
            position = dataStart + size
        }
        return values
    }

    // MARK: - Entry construction

    private static func makeEntry(
        nameBytes: [UInt8],
        decodedName: String?,
        kind: ArchiveEntryKind,
        uncompressedSize: Int,
        compressedSize: Int,
        unixMode: UInt16?,
        limits: ArchiveLimits
    ) -> ArchiveEntry {
        guard nameBytes.count <= limits.maximumEntryNameLength else {
            return ArchiveEntry(
                rejectedName: "<entry name of \(nameBytes.count) bytes exceeds the accepted limit of \(limits.maximumEntryNameLength)>",
                kind: kind,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                unixMode: unixMode
            )
        }
        guard let decodedName = decodedName else {
            return ArchiveEntry(
                rejectedName: "<entry name is not valid text>",
                kind: kind,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                unixMode: unixMode
            )
        }
        guard let path = ArchivePath(rawValue: decodedName) else {
            return ArchiveEntry(
                rejectedName: decodedName,
                kind: kind,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                unixMode: unixMode
            )
        }
        return ArchiveEntry(
            path: path,
            kind: kind,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            unixMode: unixMode
        )
    }

    /// The Unix file-type and permission bits the container records, when it
    /// records any: a Unix host system with a nonzero mode. Anything else —
    /// another host, or a zero mode that carries no information — yields no
    /// mode, and kind detection falls back to the naming convention as before.
    private static func recordedUnixMode(
        versionMadeBy: UInt16,
        externalAttributes: UInt32
    ) -> UInt16? {
        guard versionMadeBy >> 8 == 3 else {
            return nil
        }
        let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
        if mode == 0 {
            return nil
        }
        return mode
    }

    /// Determines an entry's kind from the type information the container
    /// records, falling back to the naming convention when it records none.
    private static func entryKind(
        versionMadeBy: UInt16,
        externalAttributes: UInt32,
        nameEndsWithSeparator: Bool
    ) -> ArchiveEntryKind {
        let hostSystem = versionMadeBy >> 8
        if hostSystem == 3 {
            let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
            let typeBits = mode & 0o170000
            if typeBits != 0 {
                switch typeBits {
                case 0o040000: return .directory
                case 0o100000: return .regularFile
                case 0o120000: return .symbolicLink
                default: return .unsupported
                }
            }
        } else if hostSystem == 0, (externalAttributes & 0x10) != 0 {
            return .directory
        }
        return nameEndsWithSeparator ? .directory : .regularFile
    }
}

/// Little-endian field reads over a byte buffer.
///
/// Out-of-range reads return zero rather than trapping: a hostile container
/// may describe structures that do not fit the bytes it actually carries, and
/// the caller's own bounds checks decide what that means. Parsing must never
/// be able to crash the process.
enum ZipField {

    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}
