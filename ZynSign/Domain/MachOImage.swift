import Foundation

/// A structural view of a Mach-O file. Offsets and ranges in this model are
/// absolute byte positions in the supplied input unless named `relativeOffset`.
/// No field is evidence that a signature verifies or that the code can run.
struct MachOImage: Equatable {
    enum Container: Equatable {
        case thin(MachOSlice)
        case universal(MachOUniversal)
    }

    let container: Container

    /// All slices in container order; callers must choose an architecture
    /// explicitly rather than treating the first one as authoritative.
    var slices: [MachOSlice] {
        switch container {
        case .thin(let slice): return [slice]
        case .universal(let universal): return universal.slices
        }
    }

    func slice(at index: Int) -> MachOSlice? {
        let all = slices
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }
}

enum MachOByteOrder: Equatable {
    case littleEndian
    case bigEndian
}

enum MachOWordSize: Equatable {
    case bits32
    case bits64
}

enum MachOHeaderMagic: UInt32, Equatable {
    case mach32 = 0xFEEDFACE
    case mach64 = 0xFEEDFACF
}

enum MachOUniversalMagic: UInt32, Equatable {
    case fat32 = 0xCAFEBABE
    case fat64 = 0xCAFEBABF
}

/// CPU families with established Mach-O values. Subtypes, including arm64e
/// and their capability bits, are preserved verbatim, not interpreted as a
/// device-compatibility or signing decision.
enum MachOCPU: Equatable {
    case arm
    case arm64
    case x86
    case x86_64
    case other(Int32)

    init(rawValue: Int32) {
        switch rawValue {
        case 12: self = .arm
        case 0x0100_000C: self = .arm64
        case 7: self = .x86
        case 0x0100_0007: self = .x86_64
        default: self = .other(rawValue)
        }
    }
}

/// A fat/universal table record. The range is an independently delimited
/// slice in the input; alignment is the exponent declared by that record.
struct MachOArchitecture: Equatable {
    let cpu: MachOCPU
    let cpuSubtype: Int32
    let fileRange: Range<Int>
    let alignmentExponent: UInt32
    let reserved: UInt32?
}

struct MachOUniversal: Equatable {
    let magic: MachOUniversalMagic
    let byteOrder: MachOByteOrder
    let architectures: [MachOArchitecture]
    let slices: [MachOSlice]

    var architectureCount: Int { architectures.count }
}

struct MachOHeader: Equatable {
    let magic: MachOHeaderMagic
    let byteOrder: MachOByteOrder
    let cpu: MachOCPU
    let cpuSubtype: Int32
    let fileType: UInt32
    let loadCommandCount: Int
    let loadCommandsSize: Int
    let flags: UInt32
    /// Present only for a 64-bit header. No semantics are assigned to it.
    let reserved: UInt32?

    var wordSize: MachOWordSize { magic == .mach64 ? .bits64 : .bits32 }
}

/// One independently inspected Mach-O image, either the entire thin input or
/// a slice named by a fat table entry. Load-command and signature ranges
/// cannot leave `fileRange`.
struct MachOSlice: Equatable {
    let fileRange: Range<Int>
    let header: MachOHeader
    let loadCommands: [MachOLoadCommand]
    let embeddedSignature: MachOEmbeddedSignature?
}

struct MachOLoadCommand: Equatable {
    let type: UInt32
    let fileRange: Range<Int>

    var isCodeSignature: Bool { type == 0x1D }
    var size: Int { fileRange.count }
}

struct MachOCodeSignatureCommand: Equatable {
    let commandRange: Range<Int>
    /// Offset from the start of the containing *slice*, not the fat file.
    let dataOffset: Int
    let dataSize: Int
    let fileRange: Range<Int>
}

struct MachOEmbeddedSignature: Equatable {
    let command: MachOCodeSignatureCommand
    let superBlob: MachOSuperBlob
}

/// The declared SuperBlob length may be shorter than the load command's
/// reserved region. Neither trailing bytes nor indexed blob contents are
/// authenticated by parsing them.
struct MachOSuperBlob: Equatable {
    let magic: UInt32
    let fileRange: Range<Int>
    let entries: [MachOSignatureEntry]

    var length: Int { fileRange.count }
    var count: Int { entries.count }
}

/// A delimited blob. Unknown index types and blob magics are kept as numbers,
/// with no claims about their payloads. Known non-CodeDirectory payloads are
/// likewise not decoded or verified.
struct MachOSignatureEntry: Equatable {
    let slotNumber: UInt32
    let slot: CodeSignatureBlobType
    let relativeOffset: Int
    let magic: UInt32
    let fileRange: Range<Int>
    let codeDirectory: MachOCodeDirectory?
}

enum MachOHashType: Equatable {
    case sha1
    case sha256
    case sha256Truncated
    case sha384
    case other(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .sha1
        case 2: self = .sha256
        case 3: self = .sha256Truncated
        case 4: self = .sha384
        default: self = .other(rawValue)
        }
    }

    var expectedByteCount: Int? {
        switch self {
        case .sha1, .sha256Truncated: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .other: return nil
        }
    }
}

enum MachOSpecialHashKind: Equatable {
    case infoPlist
    case requirements
    case codeResources
    case application
    case entitlements
    case representationSpecific
    case derEntitlements
    case launchConstraintSelf
    case launchConstraintParent
    case launchConstraintResponsible
    case libraryConstraint
    case other(Int)

    init(slotNumber: Int) {
        switch slotNumber {
        case 1: self = .infoPlist
        case 2: self = .requirements
        case 3: self = .codeResources
        case 4: self = .application
        case 5: self = .entitlements
        case 6: self = .representationSpecific
        case 7: self = .derEntitlements
        case 8: self = .launchConstraintSelf
        case 9: self = .launchConstraintParent
        case 10: self = .launchConstraintResponsible
        case 11: self = .libraryConstraint
        default: self = .other(slotNumber)
        }
    }
}

/// A negative hash slot is reserved when it lies within nSpecialSlots. Its
/// bytes may still be all zero, and nonzero bytes do not establish validity.
struct MachOSpecialHashSlot: Equatable {
    let slotNumber: Int
    let kind: MachOSpecialHashKind
    let hashRange: Range<Int>
    let hash: Data
    let hasNonzeroBytes: Bool
}

struct MachOScatterRecord: Equatable {
    let pageCount: UInt32
    let firstPage: UInt32
    let targetOffset: UInt64
    let reserved: UInt64
}

struct MachOScatterTable: Equatable {
    let relativeOffset: Int
    let fileRange: Range<Int>
    let records: [MachOScatterRecord]
}

struct MachOExecutableSegment: Equatable {
    let base: UInt64
    let limit: UInt64
    let flags: UInt64
}

struct MachOLinkage: Equatable {
    let hashType: UInt8
    let applicationType: UInt8
    let applicationSubtype: UInt16
    let dataRange: Range<Int>?
}

/// The fields supported at each version milestone are optional before that
/// milestone. A parsed hash table says only that the declared slots fit in
/// this blob; it does not establish any digest, binding or policy verdict.
struct MachOCodeDirectory: Equatable {
    let version: UInt32
    let flags: UInt32
    let identifier: String
    let teamIdentifier: String?
    let hashOffset: Int
    let hashType: MachOHashType
    let hashSize: Int
    let platform: UInt8
    /// Log2 of the page byte count; zero denotes a single, unpaged range.
    let pageSizeExponent: UInt8
    let codeSlotCount: Int
    let specialSlotCount: Int
    let codeLimit: UInt32
    let codeLimit64: UInt64?
    let codeHashesRange: Range<Int>
    /// Value-owned code-slot bytes, in non-negative slot order. The parser
    /// still makes no claim that these bytes are the correct hashes for an
    /// executable; it only preserves the declared values.
    let codeHashes: [Data]
    let specialSlots: [MachOSpecialHashSlot]
    let scatter: MachOScatterTable?
    let executableSegment: MachOExecutableSegment?
    let runtime: UInt32?
    let preEncryptHashesRange: Range<Int>?
    let linkage: MachOLinkage?

    /// A nonzero extended limit takes precedence. This is only a structural
    /// interpretation; future hashing must also account for scatter entries.
    var effectiveCodeLimit: UInt64 {
        if let extended = codeLimit64, extended != 0 { return extended }
        return UInt64(codeLimit)
    }
}
