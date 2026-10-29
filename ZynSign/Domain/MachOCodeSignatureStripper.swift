import Foundation

/// Removes an embedded code signature from one thin Mach-O image.
///
/// Re-signing a package that already carries a signature needs the old one
/// gone first: the signature occupies the end of `__LINKEDIT`, its load command
/// is inside the hashed region, and a signer that appends on top of it produces
/// a file with two signature regions and a CodeDirectory that hashes the first.
/// Re-signing therefore starts by stripping, never by overwriting: the old
/// region has to be gone before the new one is planned.
///
/// What the strip does, and why each part matters:
///
/// - the `LC_CODE_SIGNATURE` command is removed and every later command is
///   moved down by its 16 bytes, with the vacated bytes zeroed. Byte offsets of
///   everything else in the file are untouched, so segment file offsets stay
///   valid;
/// - the file is truncated at the signature's offset, dropping the SuperBlob
///   and the trailing padding the previous signer reserved;
/// - `__LINKEDIT`'s file size is reduced to end where the signature began. A
///   segment that claims more file than the file has is a structural fault, and
///   the loader refuses it before any signature is examined.
///
/// Fat (universal) containers are handled by taking them apart: every slice is
/// stripped as a standalone thin image and the container is rebuilt from the
/// results, because a universal file is a table of offsets and stripping one
/// slice in place would leave every later slice pointing at the wrong bytes.
struct MachOCodeSignatureStripper {

    /// A strip that cannot be performed on these bytes.
    enum Failure: Error, Equatable {
        /// Not a Mach-O image or a fat container in a byte order this build reads.
        case unsupportedForm
        /// A header or load-command table that does not describe a Mach-O image.
        case malformedImage
        /// The signature region a command declares does not lie inside the file.
        case invalidSignatureRegion
        /// A stripped image would still exceed the reader's bound.
        case resultingImageTooLarge
    }

    /// The reader's bound on an image it will hold in memory, matching the rest
    /// of the Mach-O layer.
    static let maximumImageByteCount = 512 * 1_024 * 1_024

    private static let codeSignatureCommand: UInt32 = 0x1D
    private static let segment64Command: UInt32 = 0x19
    private static let segment32Command: UInt32 = 0x1
    private static let pageBytes = 16 * 1_024

    /// Bytes with no signature. An image that carries none is returned as it
    /// was, so the caller can strip unconditionally.
    static func stripSignature(from image: Data) throws -> Data {
        guard !image.isEmpty else { throw Failure.malformedImage }
        guard image.count <= maximumImageByteCount else { throw Failure.resultingImageTooLarge }
        // A fat container is a table of slices, not an image: strip each slice
        // as its own file, then rebuild the table around the new sizes.
        if isUniversalContainer(image) {
            return try stripUniversalContainer(image)
        }
        var bytes = [UInt8](image)

        let magic = readUInt32(bytes, at: 0)
        let headerSize: Int
        let wordSize: Int
        switch magic {
        case MachOHeaderMagic.mach64.rawValue: headerSize = 32; wordSize = 8
        case MachOHeaderMagic.mach32.rawValue: headerSize = 28; wordSize = 4
        default:
            // 0xCAFEBABE and 0xBEBAFECA are fat containers; anything else is
            // not a Mach-O image at all.
            throw Failure.unsupportedForm
        }
        guard bytes.count >= headerSize else { throw Failure.malformedImage }

        let commandCount = Int(readUInt32(bytes, at: 16))
        let commandBytes = Int(readUInt32(bytes, at: 20))
        let commandsEnd = headerSize + commandBytes
        guard commandsEnd <= bytes.count else { throw Failure.malformedImage }

        var signatureCommandOffset: Int?
        var signatureOffset = 0
        var signatureSize = 0
        var linkEdit: (command: Int, fileOffset: UInt64, fileSize: UInt64)?
        var cursor = headerSize
        for _ in 0..<commandCount {
            guard cursor + 8 <= commandsEnd else { throw Failure.malformedImage }
            let command = readUInt32(bytes, at: cursor)
            let size = Int(readUInt32(bytes, at: cursor + 4))
            guard size >= 8, cursor + size <= commandsEnd else { throw Failure.malformedImage }
            switch command {
            case codeSignatureCommand:
                guard size >= 16 else { throw Failure.malformedImage }
                signatureCommandOffset = cursor
                signatureOffset = Int(readUInt32(bytes, at: cursor + 8))
                signatureSize = Int(readUInt32(bytes, at: cursor + 12))
            case segment64Command where wordSize == 8 && size >= 72:
                if segmentName(bytes, at: cursor + 8) == "__LINKEDIT" {
                    linkEdit = (cursor,
                                readUInt64(bytes, at: cursor + 40),
                                readUInt64(bytes, at: cursor + 48))
                }
            case segment32Command where wordSize == 4 && size >= 56:
                if segmentName(bytes, at: cursor + 8) == "__LINKEDIT" {
                    linkEdit = (cursor,
                                UInt64(readUInt32(bytes, at: cursor + 32)),
                                UInt64(readUInt32(bytes, at: cursor + 36)))
                }
            default:
                break
            }
            cursor += size
        }

        guard let commandOffset = signatureCommandOffset else {
            return image
        }
        guard signatureOffset >= commandsEnd,
              signatureOffset <= bytes.count,
              signatureOffset + signatureSize <= bytes.count else {
            throw Failure.invalidSignatureRegion
        }

        // Remove the command in place: everything after it moves down 16 bytes
        // and the freed tail is zeroed. Every other byte keeps its offset.
        let commandLength = 16
        if commandOffset + commandLength < commandsEnd {
            let moved = bytes[(commandOffset + commandLength)..<commandsEnd]
            bytes.replaceSubrange(commandOffset..<(commandsEnd - commandLength), with: moved)
        }
        for index in (commandsEnd - commandLength)..<commandsEnd {
            bytes[index] = 0
        }
        writeUInt32(UInt32(commandCount - 1), into: &bytes, at: 16)
        writeUInt32(UInt32(commandBytes - commandLength), into: &bytes, at: 20)

        // The signature and the padding after it are not part of the image: the
        // signature describes the bytes before it, never itself.
        bytes.removeSubrange(signatureOffset..<bytes.count)

        // `__LINKEDIT` now ends where the signature began. Its virtual size
        // keeps the same page alignment a linker would give it, because the
        // loader maps the segment and refuses a virtual size smaller than the
        // file size it must contain.
        if let linkEdit, UInt64(bytes.count) < linkEdit.fileOffset + linkEdit.fileSize {
            guard UInt64(bytes.count) >= linkEdit.fileOffset else {
                throw Failure.invalidSignatureRegion
            }
            let fileSize = UInt64(bytes.count) - linkEdit.fileOffset
            let virtualSize = max(fileSize, roundUpToPage(fileSize))
            if wordSize == 8 {
                writeUInt64(virtualSize, into: &bytes, at: linkEdit.command + 32)
                writeUInt64(fileSize, into: &bytes, at: linkEdit.command + 48)
            } else {
                writeUInt32(UInt32(truncatingIfNeeded: virtualSize), into: &bytes, at: linkEdit.command + 28)
                writeUInt32(UInt32(truncatingIfNeeded: fileSize), into: &bytes, at: linkEdit.command + 36)
            }
        }
        return Data(bytes)
    }

    /// Whether these bytes are a fat container.
    ///
    /// `readUInt32` here is little-endian and the fat magic is written
    /// big-endian, so a container spells its magic byte-swapped when read this
    /// way. A table written in the other order names no format this build
    /// reads, and is left to the unsupported-form refusal.
    private static func isUniversalContainer(_ image: Data) -> Bool {
        isUniversalMagic([UInt8](image.prefix(4)))
    }

    private static func isUniversalMagic(_ magicBytes: [UInt8]) -> Bool {
        guard magicBytes.count == 4 else { return false }
        let magic = readUInt32(magicBytes, at: 0)
        return magic == MachOUniversalMagic.fat32.rawValue.byteSwapped
            || magic == MachOUniversalMagic.fat64.rawValue.byteSwapped
    }

    /// The declared slice ranges of a canonical fat container, or `nil` when
    /// these bytes are not one. Table fields are big-endian.
    private static func universalSliceRanges(_ bytes: [UInt8]) -> [Range<Int>]? {
        guard bytes.count >= 8, isUniversalMagic(Array(bytes.prefix(4))) else { return nil }
        let magic = readUInt32(Array(bytes.prefix(4)), at: 0)
        let wide = magic == MachOUniversalMagic.fat64.rawValue.byteSwapped
        let count = Int(readBigEndianUInt32(bytes, at: 4))
        let recordWidth = wide ? 32 : 20
        guard count > 0, count <= MachOUniversalFile.maximumSliceCount,
              8 + count * recordWidth <= bytes.count else { return nil }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(count)
        for index in 0..<count {
            let record = 8 + index * recordWidth
            let offset: Int
            let size: Int
            if wide {
                offset = Int(clamping: readBigEndianUInt64(bytes, at: record + 8))
                size = Int(clamping: readBigEndianUInt64(bytes, at: record + 16))
            } else {
                offset = Int(readBigEndianUInt32(bytes, at: record + 8))
                size = Int(readBigEndianUInt32(bytes, at: record + 12))
            }
            guard size > 0, offset >= 8 + count * recordWidth,
                  size <= bytes.count - offset else { return nil }
            ranges.append(offset..<(offset + size))
        }
        return ranges
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func readBigEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    /// Strips every slice of a universal container and rebuilds the table.
    ///
    /// A slice that carries no signature is left exactly as it was, so the
    /// rebuilt container is byte-identical for it. A container that cannot be
    /// taken apart is refused with the reason the split gave, rather than
    /// half-stripped.
    private static func stripUniversalContainer(_ image: Data) throws -> Data {
        let container: MachOUniversalFile
        do {
            container = try MachOUniversalFile.split(image)
        } catch let error as MachOUniversalFile.Failure {
            switch error {
            case .resourceLimitExceeded:
                throw Failure.resultingImageTooLarge
            default:
                throw Failure.malformedImage
            }
        } catch {
            throw Failure.malformedImage
        }
        var stripped = container
        do {
            for slice in container.slices {
                let bytes = try stripSignature(from: slice.bytes)
                stripped = try stripped.replacingSlice(for: slice.architectureKey, with: bytes)
            }
            return try stripped.rebuild()
        } catch let error as Failure {
            throw error
        } catch let error as MachOUniversalFile.Failure {
            switch error {
            case .resourceLimitExceeded, .offsetOverflow:
                throw Failure.resultingImageTooLarge
            default:
                throw Failure.malformedImage
            }
        } catch {
            throw Failure.malformedImage
        }
    }

    /// Whether these bytes carry a code-signature command, in the image itself
    /// or in any slice of a universal container. Cheap enough to call on every
    /// file in a bundle before deciding to strip.
    static func carriesSignature(_ image: Data) -> Bool {
        guard image.count >= 32 else { return false }
        let bytes = [UInt8](image)
        if let ranges = universalSliceRanges(bytes) {
            return ranges.contains { carriesSignature(bytes, in: $0) }
        }
        return carriesSignature(bytes, in: 0..<bytes.count)
    }

    /// The command table of one image, read at the slice's own start.
    private static func carriesSignature(_ bytes: [UInt8], in range: Range<Int>) -> Bool {
        let start = range.lowerBound
        guard range.count >= 32 else { return false }
        let magic = readUInt32(bytes, at: start)
        let headerSize: Int
        switch magic {
        case MachOHeaderMagic.mach64.rawValue: headerSize = 32
        case MachOHeaderMagic.mach32.rawValue: headerSize = 28
        default: return false
        }
        guard start + headerSize + 8 <= range.upperBound else { return false }
        let commandCount = Int(readUInt32(bytes, at: start + 16))
        let commandBytes = Int(readUInt32(bytes, at: start + 20))
        guard headerSize + commandBytes <= range.count else { return false }
        var cursor = start + headerSize
        let end = start + headerSize + commandBytes
        for _ in 0..<commandCount {
            guard cursor + 8 <= end else { return false }
            let command = readUInt32(bytes, at: cursor)
            let size = Int(readUInt32(bytes, at: cursor + 4))
            guard size >= 8 else { return false }
            if command == codeSignatureCommand { return true }
            cursor += size
        }
        return false
    }

    // MARK: - Byte helpers

    private static func roundUpToPage(_ value: UInt64) -> UInt64 {
        guard value > 0 else { return UInt64(pageBytes) }
        let page = UInt64(pageBytes)
        return ((value + page - 1) / page) * page
    }

    private static func segmentName(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset + 16 <= bytes.count else { return "" }
        let nameBytes = bytes[offset..<(offset + 16)].prefix { $0 != 0 }
        return String(decoding: nameBytes, as: UTF8.self)
    }

    /// Every Mach-O on Apple platforms this build signs is little-endian;
    /// the magic is read in the order it is written.
    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index)))
        }
    }

    private static func writeUInt64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 8 <= bytes.count else { return }
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index)))
        }
    }
}
