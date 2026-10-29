import Foundation

/// A universal ("fat") Mach-O container, taken apart into its slices and put
/// back together.
///
/// Every mutation path in this build is thin: the writer appends one signature
/// region to one image, the stripper removes one command table from one image.
/// A universal container is a *table* of images, so it cannot be mutated in
/// place — any change to a slice moves every later slice. That is why the
/// universal paths start here: split, mutate each slice as a standalone thin
/// image, rebuild.
///
/// **What this type refuses.**
///
/// - a file that is not a fat container (a thin image belongs on the thin
///   paths; wrapping one as a single-slice container would invent a table);
/// - a table that does not fit the file, a slice outside the file, or two
///   slices that overlap — the format is positional, so an overlap is two
///   answers for the same byte;
/// - two records naming the same architecture, because "which one is the arm64
///   slice" would then have no answer;
/// - a slice whose bytes are not themselves a Mach-O image;
/// - more than `maximumSliceCount` records, or any container past the bound.
///
/// **What rebuilding preserves.** Record width (32-bit for `0xCAFEBABE`,
/// 64-bit for `0xCAFEBABF`), each slice's declared alignment exponent, and
/// slice order. What it cannot preserve is padding *content*: alignment bytes
/// are written as zero, which is what a signer does and what the loader
/// expects.
///
/// This is structure, not signing: no digest is computed and no signature is
/// judged. A rebuilt container is byte-valid, not accepted by anything.
struct MachOUniversalFile {

    /// A container this type will not take apart or rebuild.
    enum Failure: Error, Equatable {
        /// The bytes are not a fat container.
        case notAUniversalContainer
        /// The header, the table, or the declared slice ranges do not describe
        /// a file that exists.
        case malformedContainer
        /// Two records name the same architecture, or two ranges overlap.
        case ambiguousSlices
        /// A slice's bytes are not a Mach-O image.
        case unsupportedSlice
        /// The container, or one slice, exceeds the configured bound.
        case resourceLimitExceeded
        /// A rebuilt 32-bit container would need an offset it cannot address.
        case offsetOverflow
    }

    /// One architecture's bytes, exactly as they appeared in the container.
    struct Slice: Equatable {
        /// The declared architecture, in container order.
        let cpu: MachOCPU
        let cpuSubtype: Int32
        /// The alignment exponent the record declares. Preserved on rebuild.
        let alignmentExponent: UInt32
        /// The slice's bytes, copied out of the container.
        let bytes: Data

        /// The key that must be unique across a container.
        var architectureKey: String { "\(cpu.rawValue)-\(cpuSubtype)" }
    }

    /// The most slices one container may carry. Apple ships at most a handful;
    /// a larger table is malformed or hostile.
    static let maximumSliceCount = 16

    /// The largest container this type will hold, matching the rest of the
    /// Mach-O layer's in-memory bound.
    static let maximumContainerByteCount = 512 * 1_024 * 1_024

    /// The widest alignment exponent honoured on rebuild. Reserving more than a
    /// megabyte of padding per slice is never a legitimate layout.
    static let maximumAlignmentExponent: UInt32 = 20

    let magic: MachOUniversalMagic
    let slices: [Slice]

    /// Whether a rebuild writes 64-bit table records.
    var usesWideRecords: Bool { magic == .fat64 }

    // MARK: - Taking apart

    /// Splits a container into its slices.
    ///
    /// - Parameter bytes: The complete fat file.
    /// - Throws: `Failure` when the container is not one this build can take
    ///   apart.
    static func split(_ bytes: Data) throws -> MachOUniversalFile {
        guard bytes.startIndex == 0 else { throw Failure.malformedContainer }
        guard bytes.count <= maximumContainerByteCount else { throw Failure.resourceLimitExceeded }
        guard bytes.count >= 8 else { throw Failure.malformedContainer }

        let raw = [UInt8](bytes)
        guard let magic = MachOUniversalMagic(rawValue: Self.readUInt32(raw, at: 0)) else {
            throw Failure.notAUniversalContainer
        }
        let count = Int(Self.readUInt32(raw, at: 4))
        guard count > 0 else { throw Failure.malformedContainer }
        guard count <= maximumSliceCount else { throw Failure.resourceLimitExceeded }

        let recordWidth = magic == .fat64 ? 32 : 20
        guard 8 + count * recordWidth <= raw.count else { throw Failure.malformedContainer }

        var slices: [Slice] = []
        var keys: Set<String> = []
        var ranges: [Range<Int>] = []
        for index in 0..<count {
            let record = 8 + index * recordWidth
            let cpu = MachOCPU(rawValue: Int32(bitPattern: Self.readUInt32(raw, at: record)))
            let subtype = Int32(bitPattern: Self.readUInt32(raw, at: record + 4))
            let offset = magic == .fat64
                ? Int(clamping: Self.readUInt64(raw, at: record + 8))
                : Int(Self.readUInt32(raw, at: record + 8))
            let size = magic == .fat64
                ? Int(clamping: Self.readUInt64(raw, at: record + 16))
                : Int(Self.readUInt32(raw, at: record + 12))
            let alignmentExponent = Self.readUInt32(
                raw, at: record + (magic == .fat64 ? 24 : 16))

            guard size > 0, offset >= 8 + count * recordWidth, size <= raw.count - offset else {
                throw Failure.malformedContainer
            }
            let range = offset..<(offset + size)
            // A slice must start where its declared alignment says it does.
            if alignmentExponent <= maximumAlignmentExponent {
                let alignment = 1 << Int(alignmentExponent)
                guard range.lowerBound % alignment == 0 else { throw Failure.malformedContainer }
            }
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw Failure.ambiguousSlices
            }
            ranges.append(range)

            let key = "\(cpu.rawValue)-\(subtype)"
            guard !keys.contains(key) else { throw Failure.ambiguousSlices }
            keys.insert(key)

            let sliceBytes = bytes.subdata(in: range)
            try Self.validateImage(sliceBytes)
            slices.append(Slice(
                cpu: cpu,
                cpuSubtype: subtype,
                alignmentExponent: alignmentExponent,
                bytes: sliceBytes
            ))
        }
        return MachOUniversalFile(magic: magic, slices: slices)
    }

    /// A slice must be a Mach-O image, or the container would name an
    /// architecture whose bytes are not one.
    ///
    /// The check is structural: a known header magic, and a load-command table
    /// that fits inside the slice. The header magic is read big-endian, which
    /// is the byte order a little-endian image spells its own magic in, so the
    /// four byte-reversed forms are the ones that identify a readable image.
    private static func validateImage(_ slice: Data) throws {
        guard slice.count >= 28 else { throw Failure.unsupportedSlice }
        let raw = [UInt8](slice)
        let magic = readUInt32(raw, at: 0)
        let headerSize: Int
        let bigEndian: Bool
        switch magic {
        case MachOHeaderMagic.mach64.rawValue:
            headerSize = 32
            bigEndian = true
        case MachOHeaderMagic.mach32.rawValue:
            headerSize = 28
            bigEndian = true
        case MachOHeaderMagic.mach64.rawValue.byteSwapped:
            headerSize = 32
            bigEndian = false
        case MachOHeaderMagic.mach32.rawValue.byteSwapped:
            headerSize = 28
            bigEndian = false
        default:
            throw Failure.unsupportedSlice
        }
        guard slice.count >= headerSize else { throw Failure.unsupportedSlice }
        let commandBytes = Int(readUInt32(raw, at: 20, bigEndian: bigEndian))
        guard commandBytes <= slice.count - headerSize else { throw Failure.unsupportedSlice }
    }

    // MARK: - Putting back together

    /// Rebuilds a container from this value's slices, in order.
    ///
    /// Each slice is copied at the next offset its own alignment exponent
    /// allows; the table sits immediately after the 8-byte header. Padding is
    /// zero. The result is a fat container, never a thin image.
    ///
    /// - Throws: `Failure.resourceLimitExceeded` when the rebuilt container
    ///   would exceed the bound, and `Failure.offsetOverflow` when a 32-bit
    ///   table cannot address a slice.
    func rebuild() throws -> Data {
        guard !slices.isEmpty else { throw Failure.malformedContainer }
        guard slices.count <= Self.maximumSliceCount else { throw Failure.resourceLimitExceeded }
        let recordWidth = usesWideRecords ? 32 : 20

        var offsets: [Int] = []
        var cursor = 8 + slices.count * recordWidth
        for slice in slices {
            let exponent = min(slice.alignmentExponent, Self.maximumAlignmentExponent)
            let alignment = 1 << Int(exponent)
            cursor = (cursor + alignment - 1) / alignment * alignment
            if !usesWideRecords, cursor > Int(UInt32.max) { throw Failure.offsetOverflow }
            guard slice.bytes.count <= Self.maximumContainerByteCount - cursor else {
                throw Failure.resourceLimitExceeded
            }
            offsets.append(cursor)
            cursor += slice.bytes.count
        }
        guard cursor <= Self.maximumContainerByteCount else { throw Failure.resourceLimitExceeded }

        var out = [UInt8](repeating: 0, count: cursor)
        Self.writeUInt32(magic.rawValue, at: 0, into: &out)
        Self.writeUInt32(UInt32(slices.count), at: 4, into: &out)
        for (index, slice) in slices.enumerated() {
            let record = 8 + index * recordWidth
            Self.writeUInt32(UInt32(bitPattern: slice.cpu.rawValue), at: record, into: &out)
            Self.writeUInt32(UInt32(bitPattern: slice.cpuSubtype), at: record + 4, into: &out)
            if usesWideRecords {
                Self.writeUInt64(UInt64(offsets[index]), at: record + 8, into: &out)
                Self.writeUInt64(UInt64(slice.bytes.count), at: record + 16, into: &out)
                Self.writeUInt32(slice.alignmentExponent, at: record + 24, into: &out)
            } else {
                Self.writeUInt32(UInt32(offsets[index]), at: record + 8, into: &out)
                Self.writeUInt32(UInt32(slice.bytes.count), at: record + 12, into: &out)
                Self.writeUInt32(slice.alignmentExponent, at: record + 16, into: &out)
            }
            out.replaceSubrange(
                offsets[index]..<(offsets[index] + slice.bytes.count),
                with: slice.bytes
            )
        }
        return Data(out)
    }

    /// The same container with one slice replaced, in its original position.
    ///
    /// - Throws: `Failure.ambiguousSlices` when no slice has that architecture,
    ///   and `Failure.unsupportedSlice` when the replacement is not an image.
    func replacingSlice(for key: String, with bytes: Data) throws -> MachOUniversalFile {
        guard let index = slices.firstIndex(where: { $0.architectureKey == key }) else {
            throw Failure.ambiguousSlices
        }
        try Self.validateImage(bytes)
        var updated = slices
        updated[index] = Slice(
            cpu: slices[index].cpu,
            cpuSubtype: slices[index].cpuSubtype,
            alignmentExponent: slices[index].alignmentExponent,
            bytes: bytes
        )
        return MachOUniversalFile(magic: magic, slices: updated)
    }

    // MARK: - Raw field access

    /// The fat format itself is big-endian; a slice's own fields are read in
    /// the order that slice's header declares.
    private static func readUInt32(_ bytes: [UInt8], at offset: Int,
                                   bigEndian: Bool = true) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        guard bigEndian else {
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func writeUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeUInt64(_ value: UInt64, at offset: Int, into bytes: inout [UInt8]) {
        guard offset >= 0, offset + 8 <= bytes.count else { return }
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> (56 - index * 8)) & 0xFF)
        }
    }
}

private extension MachOCPU {
    /// The published CPU value. `MachOCPU` carries no raw type of its own —
    /// subtypes and capability bits are preserved verbatim elsewhere — so the
    /// mapping back to the format's number lives here, beside its only use.
    var rawValue: Int32 {
        switch self {
        case .arm: return 12
        case .arm64: return 0x0100_000C
        case .x86: return 7
        case .x86_64: return 0x0100_0007
        case .other(let value): return value
        }
    }
}
