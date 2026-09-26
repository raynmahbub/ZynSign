import Foundation

/// How a load command names a library.
enum MachODylibLoadKind: String, CaseIterable, Hashable {
    /// `LC_LOAD_DYLIB`: required at launch.
    case required
    /// `LC_LOAD_WEAK_DYLIB`: optional; the binary runs without it.
    case weak
    /// `LC_REEXPORT_DYLIB`: its symbols are offered as this binary's own.
    case reexport
    /// `LC_LAZY_LOAD_DYLIB`: loaded when first used.
    case lazy
    /// `LC_LOAD_UPWARD_DYLIB`: a library that depends back on this one.
    case upward
    /// `LC_ID_DYLIB`: this library's own identity, not a dependency.
    case identity

    init?(commandType: UInt32) {
        switch commandType {
        case MachOLoadCommandCode.loadDylib: self = .required
        case MachOLoadCommandCode.loadWeakDylib: self = .weak
        case MachOLoadCommandCode.reexportDylib: self = .reexport
        case MachOLoadCommandCode.lazyLoadDylib: self = .lazy
        case MachOLoadCommandCode.loadUpwardDylib: self = .upward
        case MachOLoadCommandCode.idDylib: self = .identity
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .required: return "Required"
        case .weak: return "Optional (weak)"
        case .reexport: return "Re-exported"
        case .lazy: return "Lazy"
        case .upward: return "Upward"
        case .identity: return "Own identity"
        }
    }

    var explanation: String {
        switch self {
        case .required: return "The binary cannot start unless this library loads."
        case .weak: return "The binary still starts when this library is missing; features that need it are skipped."
        case .reexport: return "This binary passes the library's symbols on to its own clients."
        case .lazy: return "The library is loaded the first time one of its symbols is used."
        case .upward: return "An upward link: the library also depends on this binary."
        case .identity: return "The install name other binaries use to link against this library."
        }
    }
}

/// One library reference decoded from a `dylib_command`.
struct MachODylibReference: Equatable, Hashable {
    let kind: MachODylibLoadKind
    /// The install name exactly as recorded, after control characters are
    /// replaced for display.
    let installName: String
    let currentVersion: MachOPackedVersion
    let compatibilityVersion: MachOPackedVersion
    let timestamp: UInt32
}

/// An `LC_BUILD_VERSION` record.
struct MachOBuildVersion: Equatable, Hashable {
    let platform: MachOPlatform
    let minimumOS: MachOPackedVersion
    let sdk: MachOPackedVersion
    let tools: [MachOBuildTool]
}

/// An `LC_VERSION_MIN_*` record: the older form of the build version.
struct MachOMinimumVersion: Equatable, Hashable {
    let platform: MachOPlatform
    let version: MachOPackedVersion
    let sdk: MachOPackedVersion
}

/// An `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64` record.
struct MachOEncryptionInfo: Equatable, Hashable {
    /// Where the protected range begins, relative to the slice.
    let cryptOffset: UInt32
    /// How many bytes the protected range covers.
    let cryptSize: UInt32
    /// The encryption system in use. Zero means the range is not encrypted in
    /// this file.
    let cryptID: UInt32

    /// Whether the protected range is encrypted in this file.
    var isEncrypted: Bool { cryptID != 0 }

    /// Whether the command describes a range at all.
    var describesRange: Bool { cryptSize > 0 }
}

/// A `linkedit_data_command`: data located in the `__LINKEDIT` segment.
struct MachOLinkEditDataReference: Equatable, Hashable {
    let dataOffset: UInt32
    let dataSize: UInt32
}

/// An `LC_DYLD_INFO` / `LC_DYLD_INFO_ONLY` record: the sizes of the classic
/// dynamic-linker information streams.
struct MachODyldInfo: Equatable, Hashable {
    let rebaseSize: UInt32
    let bindSize: UInt32
    let weakBindSize: UInt32
    let lazyBindSize: UInt32
    let exportSize: UInt32
}

/// An `LC_SYMTAB` record.
struct MachOSymbolTableInfo: Equatable, Hashable {
    let symbolCount: UInt32
    let stringTableSize: UInt32
}

/// An `LC_DYSYMTAB` record, reduced to its counts.
struct MachODynamicSymbolTableInfo: Equatable, Hashable {
    let localSymbolCount: UInt32
    let externalSymbolCount: UInt32
    let undefinedSymbolCount: UInt32
    let indirectSymbolCount: UInt32
}

/// One section of a segment, as the explorer shows it.
struct MachOSectionSummary: Equatable, Hashable, Identifiable {
    let segmentName: String
    let name: String
    let size: UInt64
    let fileOffset: UInt64
    let virtualAddress: UInt64
    let type: UInt32

    var id: String { "\(segmentName),\(name),\(fileOffset)" }
    var typeName: String { MachOSectionTypeName.name(for: type) }
    var isZeroFill: Bool { type == 0x1 || type == 0xC || type == 0x12 }

    init(section: MachOSection) {
        self.segmentName = MachOText.fixedName(section.segmentName)
        self.name = MachOText.fixedName(section.name)
        self.size = section.size
        self.fileOffset = section.fileOffset
        self.virtualAddress = section.virtualAddress
        self.type = section.flags & MachOSectionType.mask
    }
}

/// One segment, as the explorer shows it. Built from the bounded parser's
/// own segment record, so the explorer and the parser agree by construction.
struct MachOSegmentSummary: Equatable, Hashable, Identifiable {
    let index: Int
    let name: String
    let fileOffset: UInt64
    let fileSize: UInt64
    let virtualAddress: UInt64
    let virtualSize: UInt64
    let initialProtection: MachOMemoryProtection
    let maximumProtection: MachOMemoryProtection
    let flags: UInt32
    let sections: [MachOSectionSummary]

    var id: Int { index }

    init(segment: MachOSegment, index: Int) {
        self.index = index
        self.name = MachOText.fixedName(segment.name.rawBytes)
        self.fileOffset = segment.fileOffset
        self.fileSize = segment.fileSize
        self.virtualAddress = segment.virtualMemoryAddress
        self.virtualSize = segment.virtualMemorySize
        self.initialProtection = MachOMemoryProtection(rawValue: segment.initialProtection)
        self.maximumProtection = MachOMemoryProtection(rawValue: segment.maximumProtection)
        self.flags = segment.flags
        self.sections = segment.sections.map(MachOSectionSummary.init(section:))
    }

    /// A plain-language explanation for the well-known segment names.
    var explanation: String {
        switch name {
        case "__PAGEZERO": return "A guard region at address zero that catches null-pointer accesses. It occupies no space in the file."
        case "__TEXT": return "The executable code and read-only data."
        case "__DATA_CONST": return "Data that becomes read-only after the loader prepares it."
        case "__DATA": return "Writable data such as global variables."
        case "__DATA_DIRTY": return "Writable data the system expects to change early."
        case "__AUTH", "__AUTH_CONST": return "Pointers protected by pointer authentication."
        case "__OBJC_RO": return "Read-only Objective-C metadata."
        case "__LINKEDIT": return "Tables for the loader, the symbol table, and the code signature."
        default: return "A segment this binary defines."
        }
    }
}

/// Why one load command's payload could not be decoded. The command itself
/// stays listed with its type and size.
enum MachOLoadCommandDecodingIssue: String, Equatable, Hashable {
    case fieldsExceedCommand
    case invalidStringOffset
    case unterminatedString
    case tooManyEntries
    case segmentNotEstablished

    var explanation: String {
        switch self {
        case .fieldsExceedCommand:
            return "The command's fields extend past the size it declares."
        case .invalidStringOffset:
            return "The command points to a name outside its own bytes."
        case .unterminatedString:
            return "The command's name is not terminated inside the command."
        case .tooManyEntries:
            return "The command declares more entries than ZynSign reads."
        case .segmentNotEstablished:
            return "The segment was not established by the structural parser."
        }
    }
}

/// The decoded payload of one load command.
///
/// Payload decoding is descriptive: a decoded library name is what the binary
/// records, not evidence that the library exists or loads, and a decoded
/// encryption record is what the binary declares about itself.
enum MachOLoadCommandPayload: Equatable {
    case segment(MachOSegmentSummary)
    case dylib(MachODylibReference)
    case dynamicLinker(String)
    case runPath(String)
    case environment(String)
    case uuid(String)
    case buildVersion(MachOBuildVersion)
    case minimumVersion(MachOMinimumVersion)
    case sourceVersion(MachOSourceVersion)
    case entryPoint(offset: UInt64, stackSize: UInt64)
    case encryption(MachOEncryptionInfo)
    case linkEditData(MachOLinkEditDataReference)
    case dyldInfo(MachODyldInfo)
    case symbolTable(MachOSymbolTableInfo)
    case dynamicSymbolTable(MachODynamicSymbolTableInfo)
    case linkerOptions(count: UInt32)
    case note(owner: String, offset: UInt64, size: UInt64)
    /// A command whose payload ZynSign lists but does not decode.
    case opaque
    /// A command whose payload could not be decoded safely.
    case malformed(MachOLoadCommandDecodingIssue)
}

/// One load command with its decoded payload.
struct MachODecodedLoadCommand: Equatable, Identifiable {

    /// The command's position in the header, from zero.
    let index: Int

    /// The type code exactly as recorded.
    let type: UInt32

    /// The command's bytes, as an absolute range in the parsed file.
    let fileRange: Range<Int>

    /// The decoded payload.
    let payload: MachOLoadCommandPayload

    var id: Int { index }

    /// The declared command size, in bytes.
    var size: Int { fileRange.count }

    /// What ZynSign knows about the command's type.
    var descriptor: MachOLoadCommandDescriptor {
        MachOLoadCommandCatalog.descriptor(for: type)
    }
}

/// The boundary through which load-command payloads are decoded.
///
/// The structural parser records only each command's type and range, plus
/// the segments and the code-signature command it needs for signing. The
/// decoder reads the remaining payloads on request, from the same bytes the
/// slice was parsed from, with the same bounded reads. It is read-only and
/// total: a payload that cannot be decoded is reported as `.malformed` on its
/// own command, and every other command still decodes.
protocol MachOLoadCommandDecoding {

    /// Decodes every load command of `slice`.
    ///
    /// - Parameters:
    ///   - slice: A slice parsed from `bytes`.
    ///   - bytes: The exact bytes the slice was parsed from.
    func decodeLoadCommands(of slice: MachOSlice, in bytes: Data) -> [MachODecodedLoadCommand]
}
