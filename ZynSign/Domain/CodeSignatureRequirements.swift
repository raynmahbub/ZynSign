import Foundation

/// Structured failures at the code-signing requirements boundary.
///
/// Requirements data is untrusted input: framing is validated with explicit
/// integer, offset, and count checks before any byte is retained, and the
/// failure cases name the check that refused without carrying blob contents.
enum RequirementsError: Error, Equatable {
    /// The presented bytes were empty.
    case emptyInput
    /// The blob magic was not the expected value.
    case invalidMagic(expected: UInt32, actual: UInt32)
    /// A declared length was inconsistent with the bytes available.
    case invalidLength
    /// A declared offset fell outside the blob, preceded the index, or
    /// overlapped another entry's range.
    case invalidOffset
    /// The entry count exceeded the supported bound.
    case invalidEntryCount
    /// Two entries claimed the same requirement kind.
    case duplicateEntryKind(UInt32)
    /// A checked arithmetic step overflowed.
    case integerOverflow
    /// A configured resource bound was exceeded.
    case resourceLimitExceeded
    /// The caller asked to embed a requirements value that carries no
    /// embeddable set (for example one whose framing was malformed).
    case notEmbeddable
    /// An entry structure this model does not represent.
    case unsupportedStructure

    /// Maps a bounded-reader failure at this boundary into this vocabulary.
    static func from(_ error: MachOParsingError) -> RequirementsError {
        switch error.reason {
        case .invalidOffset: return .invalidOffset
        case .invalidLength, .truncatedInput: return .invalidLength
        case .resourceLimitExceeded: return .resourceLimitExceeded
        default: return .unsupportedStructure
        }
    }
}

/// A requirement kind from the documented `SecRequirementType` set.
///
/// **Verified (Apple open-source `CSCommon.h`, libsecurity_codesigning):**
/// the requirement-set index uses these numeric kinds — host = 1, guest = 2,
/// designated = 3, library = 4, plugin = 5. An unrecognized numeric kind is
/// preserved as `.other` and reported through the disposition rather than
/// rejected: preservation is honest, interpretation would be invention.
enum RequirementKind: Equatable, Hashable {
    case host
    case guest
    case designated
    case library
    case plugin
    case other(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 1: self = .host
        case 2: self = .guest
        case 3: self = .designated
        case 4: self = .library
        case 5: self = .plugin
        default: self = .other(rawValue)
        }
    }

    var rawValue: UInt32 {
        switch self {
        case .host: return 1
        case .guest: return 2
        case .designated: return 3
        case .library: return 4
        case .plugin: return 5
        case .other(let value): return value
        }
    }
}

/// One framed requirement inside a requirements set.
///
/// The expression bytes — the requirement language program — are preserved
/// exactly and are **not interpreted**. The requirement expression language
/// (opcodes defined in Apple's `requirement.h`) is outside this
/// implementation's verified specification coverage, so no semantic claim is
/// made about any expression, including one ZynSign re-embeds byte for byte.
struct FramedRequirement: Equatable, Hashable {

    static let magic: UInt32 = 0xFADE0C00
    static let headerLength = 8

    /// The requirement's expression program bytes, exactly as presented.
    let expressionBytes: Data

    init(expressionBytes: Data) throws {
        guard expressionBytes.count <= RequirementsSet.maximumSerializedLength - Self.headerLength else {
            throw RequirementsError.resourceLimitExceeded
        }
        self.expressionBytes = expressionBytes
    }

    var serializedLength: Int { Self.headerLength + expressionBytes.count }

    /// The complete header-inclusive requirement blob bytes.
    func serializedBytes() throws -> Data {
        let length = serializedLength
        guard let encodedLength = UInt32(exactly: length) else {
            throw RequirementsError.integerOverflow
        }
        var writer = CheckedBinaryWriter(maximumLength: length)
        try writer.appendUInt32BigEndian(Self.magic)
        try writer.appendUInt32BigEndian(encodedLength)
        try writer.appendData(expressionBytes)
        guard writer.count == length else { throw RequirementsError.invalidLength }
        return writer.data
    }

    /// Parses one requirement blob at `offset` inside `reader`, returning the
    /// parsed value and its byte range relative to the reader's view.
    static func parse(
        at offset: Int,
        in reader: BoundedBinaryReader
    ) throws -> (requirement: FramedRequirement, range: Range<Int>) {
        let magic = try reader.uint32(at: offset, order: .bigEndian, boundary: .signatureBlob)
        guard magic == Self.magic else {
            throw RequirementsError.invalidMagic(expected: Self.magic, actual: magic)
        }
        let length = try reader.uint32AsInt(at: offset + 4, order: .bigEndian, boundary: .signatureBlob)
        guard length >= Self.headerLength else { throw RequirementsError.invalidLength }
        let range = try reader.checkedRange(
            at: offset,
            length: length,
            boundary: .signatureBlob,
            ifTooLong: .invalidLength
        )
        let expressionBytes = try reader.data(
            at: offset + Self.headerLength,
            length: length - Self.headerLength,
            boundary: .signatureBlob,
            ifTooLong: .invalidLength
        )
        return (try FramedRequirement(expressionBytes: expressionBytes), range)
    }
}

/// One entry of a requirements set: a kind and its framed requirement.
struct RequirementsSetEntry: Equatable, Hashable {
    let kind: RequirementKind
    let requirement: FramedRequirement

    init(kind: RequirementKind, requirement: FramedRequirement) {
        self.kind = kind
        self.requirement = requirement
    }
}

/// A requirements set: the blob whose digest occupies CodeDirectory special
/// slot 2.
///
/// Format evidence:
///
/// - **Verified (Apple open-source headers).** `cs_blobs.h` / `cscdefs.h`
///   define `CSMAGIC_REQUIREMENTS = 0xFADE0C01` ("Requirements vector") and
///   `CSMAGIC_REQUIREMENT = 0xFADE0C00` ("single Requirement blob"), and the
///   generic blob-index layout used by the SuperBlob: magic, length, count,
///   then `count` entries of (type, offset) with offsets relative to the
///   containing blob.
/// - **Verified (Apple open-source `CSCommon.h`).** The index entry types are
///   the `SecRequirementType` kinds named in `RequirementKind`.
/// - **ZynSign policy.** Entries serialize in ascending kind order, packed
///   without padding, and entry ranges must not overlap. Whether Apple's
///   signer always emits an ascending, non-overlapping index is not asserted:
///   parse accepts any in-bounds, non-overlapping order, and serialization
///   re-emits deterministically.
struct RequirementsSet: Equatable, Hashable {

    static let magic: UInt32 = 0xFADE0C01
    static let headerLength = 12
    static let maximumEntries = 128
    static let maximumSerializedLength = SignatureSuperBlob.maximumSerializedLength

    /// The entries, kept in ascending kind order.
    let entries: [RequirementsSetEntry]

    init(entries: [RequirementsSetEntry]) throws {
        guard entries.count <= Self.maximumEntries else {
            throw RequirementsError.invalidEntryCount
        }
        let sorted = entries.sorted { $0.kind.rawValue < $1.kind.rawValue }
        var previous: UInt32?
        for entry in sorted {
            if previous == entry.kind.rawValue {
                throw RequirementsError.duplicateEntryKind(entry.kind.rawValue)
            }
            previous = entry.kind.rawValue
        }
        self.entries = sorted
        _ = try layout()
    }

    /// The planned byte layout of the serialized set.
    struct Layout: Equatable {
        let length: Int
        let entryOffsets: [Int]

        /// The first byte after the (magic, length, count, index) header.
        var indexEnd: Int { RequirementsSet.headerLength + entryOffsets.count * 8 }
    }

    func layout() throws -> Layout {
        var cursor = Self.headerLength + entries.count * 8
        var offsets: [Int] = []
        offsets.reserveCapacity(entries.count)
        for entry in entries {
            let length = entry.requirement.serializedLength
            let (end, overflow) = cursor.addingReportingOverflow(length)
            guard !overflow, UInt32(exactly: end) != nil else {
                throw RequirementsError.integerOverflow
            }
            guard end <= Self.maximumSerializedLength else {
                throw RequirementsError.resourceLimitExceeded
            }
            offsets.append(cursor)
            cursor = end
        }
        return Layout(length: cursor, entryOffsets: offsets)
    }

    /// Serializes the set to exact, deterministic bytes.
    func serialized() throws -> Data {
        let layout = try layout()
        guard let encodedLength = UInt32(exactly: layout.length) else {
            throw RequirementsError.integerOverflow
        }
        var writer = CheckedBinaryWriter(maximumLength: layout.length)
        try writer.appendUInt32BigEndian(Self.magic)
        try writer.appendUInt32BigEndian(encodedLength)
        try writer.appendUInt32BigEndian(UInt32(entries.count))
        for (entry, offset) in zip(entries, layout.entryOffsets) {
            try writer.appendUInt32BigEndian(entry.kind.rawValue)
            try writer.appendUInt32BigEndian(UInt32(offset))
        }
        for entry in entries {
            try writer.appendData(entry.requirement.serializedBytes())
        }
        guard writer.count == layout.length else {
            throw RequirementsError.invalidLength
        }
        return writer.data
    }

    /// Parses an existing requirements-set blob.
    ///
    /// Framing is validated completely: magic, self-consistent length, entry
    /// count bound, in-bounds non-overlapping entry offsets after the index,
    /// unique kinds, and each entry's own framed requirement header.
    /// Expression bytes are preserved exactly and never interpreted. The
    /// returned disposition records which entry kinds, if any, fall outside
    /// the established set.
    static func parse(_ bytes: Data) throws -> CodeSigningRequirements {
        guard !bytes.isEmpty else { throw RequirementsError.emptyInput }
        guard bytes.count <= maximumSerializedLength else {
            throw RequirementsError.resourceLimitExceeded
        }
        let entries: [RequirementsSetEntry]
        do {
            entries = try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> [RequirementsSetEntry] in
                let reader = BoundedBinaryReader(bytes: raw)
                let magic = try reader.uint32(at: 0, order: .bigEndian, boundary: .signatureBlob)
                guard magic == Self.magic else {
                    throw RequirementsError.invalidMagic(expected: Self.magic, actual: magic)
                }
                let length = try reader.uint32AsInt(at: 4, order: .bigEndian, boundary: .signatureBlob)
                guard length == bytes.count, length >= Self.headerLength else {
                    throw RequirementsError.invalidLength
                }
                let count = try reader.uint32AsInt(at: 8, order: .bigEndian, boundary: .signatureBlob)
                guard count <= maximumEntries else { throw RequirementsError.invalidEntryCount }
                let indexEnd = Self.headerLength + count * 8
                guard indexEnd <= length else { throw RequirementsError.invalidLength }

                var kinds: [UInt32] = []
                var offsets: [Int] = []
                kinds.reserveCapacity(count)
                offsets.reserveCapacity(count)
                for index in 0..<count {
                    let kind = try reader.uint32(
                        at: Self.headerLength + index * 8,
                        order: .bigEndian,
                        boundary: .signatureBlob
                    )
                    let offset = try reader.uint32AsInt(
                        at: Self.headerLength + index * 8 + 4,
                        order: .bigEndian,
                        boundary: .signatureBlob
                    )
                    kinds.append(kind)
                    offsets.append(offset)
                }

                // Every entry blob must start after the index and carry its
                // own valid frame; ranges must not overlap.
                var ranges: [Range<Int>] = []
                ranges.reserveCapacity(count)
                var seenKinds: Set<UInt32> = []
                var parsedEntries: [RequirementsSetEntry] = []
                parsedEntries.reserveCapacity(count)
                for (kind, offset) in zip(kinds, offsets) {
                    guard offset >= indexEnd else { throw RequirementsError.invalidOffset }
                    let (requirement, range) = try FramedRequirement.parse(at: offset, in: reader)
                    ranges.append(range)
                    guard seenKinds.insert(kind).inserted else {
                        throw RequirementsError.duplicateEntryKind(kind)
                    }
                    parsedEntries.append(RequirementsSetEntry(kind: RequirementKind(rawValue: kind), requirement: requirement))
                }
                let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
                for index in 1..<sortedRanges.count {
                    guard sortedRanges[index - 1].upperBound <= sortedRanges[index].lowerBound else {
                        throw RequirementsError.invalidOffset
                    }
                }
                return parsedEntries
            }
        } catch let error as MachOParsingError {
            throw RequirementsError.from(error)
        }
        let set = try RequirementsSet(entries: entries)
        let unknownKinds = set.entries.compactMap { entry -> UInt32? in
            if case .other(let value) = entry.kind { return value }
            return nil
        }
        if unknownKinds.isEmpty {
            return CodeSigningRequirements(disposition: .presentAndParsed, set: set)
        }
        return CodeSigningRequirements(disposition: .presentButUnsupported(unknownKinds), set: set)
    }
}

/// The requirements model consumed by the signing pipeline.
///
/// Requirements are a separate concept from entitlements, provisioning
/// profiles, certificates, the CodeDirectory, and CMS signatures, and this
/// type keeps them separate: it carries framing and disposition only, and
/// never a certificate, a profile, or an entitlement.
///
/// The disposition vocabulary covers every state the boundary can record.
/// Two of them — `generated` and `verified` — exist in the vocabulary and are
/// deliberately unreachable today: ZynSign does not synthesize a default
/// requirement for a target that supplied none, and it does not verify
/// requirement semantics. No code path fabricates either state.
struct CodeSigningRequirements: Equatable, Hashable {

    enum Disposition: Equatable, Hashable {
        /// No requirements data exists for the target.
        case absent

        /// The framing decoded and every entry uses an established kind.
        /// Expression bytes are preserved but never interpreted.
        case presentAndParsed

        /// The framing decoded, but at least one entry used a kind outside
        /// the established set. The associated values are those kind numbers.
        /// The bytes remain embeddable exactly as parsed.
        case presentButUnsupported([UInt32])

        /// Requirements bytes exist but their framing is invalid. Recorded
        /// by read-only inspection; the signing pipeline refuses to embed
        /// such a value.
        case malformed

        /// ZynSign generated this set itself. **No current code path
        /// produces this**: a default requirement is never fabricated, and
        /// an existing requirement is never silently replaced.
        case generated

        /// The set's semantics were verified against a signer's evidence.
        /// **No current code path produces this.**
        case verified
    }

    /// Whether the requirement expressions are interpreted. The requirement
    /// expression language is not implemented; this is always
    /// `notImplemented`, stated explicitly so no caller can mistake byte
    /// preservation for semantic understanding.
    enum ExpressionInterpretation: Equatable, Hashable {
        case notImplemented
    }

    let disposition: Disposition
    let set: RequirementsSet?
    let expressionInterpretation: ExpressionInterpretation

    init(disposition: Disposition, set: RequirementsSet?) {
        self.disposition = disposition
        self.set = set
        self.expressionInterpretation = .notImplemented
    }

    /// The value representing "no requirements at all".
    static let none = CodeSigningRequirements(disposition: .absent, set: nil)

    /// Whether this value carries a set whose exact bytes the pipeline can
    /// embed. Parsed dispositions qualify; `malformed` never does, and an
    /// absent value embeds nothing.
    var isEmbeddable: Bool {
        switch disposition {
        case .presentAndParsed, .presentButUnsupported, .generated:
            return set != nil
        case .absent, .malformed, .verified:
            return false
        }
    }

    /// Whether the value asks the pipeline to embed anything.
    var requiresEmbedding: Bool {
        isEmbeddable
    }
}
