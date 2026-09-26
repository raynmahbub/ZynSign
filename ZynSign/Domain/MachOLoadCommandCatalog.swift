import Foundation

/// The explorer group a Mach-O load command belongs to.
///
/// The grouping is a presentation vocabulary chosen for people reading a
/// binary, not a format rule: the format itself has no categories. Every
/// command ZynSign does not recognise lands in `other`, so nothing a binary
/// declares is hidden by the grouping.
enum MachOLoadCommandCategory: String, CaseIterable, Hashable {
    case executable
    case libraries
    case security
    case metadata
    case linking
    case other

    /// The group's heading.
    var displayName: String {
        switch self {
        case .executable: return "Executable"
        case .libraries: return "Libraries"
        case .security: return "Security"
        case .metadata: return "Metadata"
        case .linking: return "Linking"
        case .other: return "Other"
        }
    }

    /// The SF Symbol shown beside the group.
    var systemImage: String {
        switch self {
        case .executable: return "cpu"
        case .libraries: return "books.vertical"
        case .security: return "lock.shield"
        case .metadata: return "tag"
        case .linking: return "link"
        case .other: return "questionmark.square.dashed"
        }
    }

    /// One plain-language sentence describing what the group holds.
    var explanation: String {
        switch self {
        case .executable:
            return "How the file is laid out in memory and where it starts running."
        case .libraries:
            return "The libraries and frameworks this binary loads, and where the loader looks for them."
        case .security:
            return "The code signature and App Store encryption records."
        case .metadata:
            return "Build identity: platform, minimum OS, SDK, and the build's unique identifier."
        case .linking:
            return "Tables the dynamic linker and debugging tools use: symbols, fixups, and exports."
        case .other:
            return "Commands ZynSign does not recognise. They are listed so nothing the binary declares is hidden."
        }
    }
}

/// Load-command type codes ZynSign names, as published in Apple's
/// `<mach-o/loader.h>`.
///
/// The high bit (`requiresDynamicLinker`, `LC_REQ_DYLD`) is part of the code
/// for the commands that carry it; it is kept in the constants so a code read
/// from a binary compares exactly.
enum MachOLoadCommandCode {
    static let requiresDynamicLinker: UInt32 = 0x8000_0000

    static let segment: UInt32 = 0x1
    static let symbolTable: UInt32 = 0x2
    static let thread: UInt32 = 0x4
    static let unixThread: UInt32 = 0x5
    static let dynamicSymbolTable: UInt32 = 0xB
    static let loadDylib: UInt32 = 0xC
    static let idDylib: UInt32 = 0xD
    static let loadDylinker: UInt32 = 0xE
    static let idDylinker: UInt32 = 0xF
    static let preboundDylib: UInt32 = 0x10
    static let routines: UInt32 = 0x11
    static let subFramework: UInt32 = 0x12
    static let subUmbrella: UInt32 = 0x13
    static let subClient: UInt32 = 0x14
    static let subLibrary: UInt32 = 0x15
    static let twoLevelHints: UInt32 = 0x16
    static let prebindChecksum: UInt32 = 0x17
    static let loadWeakDylib: UInt32 = 0x18 | requiresDynamicLinker
    static let segment64: UInt32 = 0x19
    static let routines64: UInt32 = 0x1A
    static let uuid: UInt32 = 0x1B
    static let runPath: UInt32 = 0x1C | requiresDynamicLinker
    static let codeSignature: UInt32 = 0x1D
    static let segmentSplitInfo: UInt32 = 0x1E
    static let reexportDylib: UInt32 = 0x1F | requiresDynamicLinker
    static let lazyLoadDylib: UInt32 = 0x20
    static let encryptionInfo: UInt32 = 0x21
    static let dyldInfo: UInt32 = 0x22
    static let dyldInfoOnly: UInt32 = 0x22 | requiresDynamicLinker
    static let loadUpwardDylib: UInt32 = 0x23 | requiresDynamicLinker
    static let versionMinMacOS: UInt32 = 0x24
    static let versionMinIPhoneOS: UInt32 = 0x25
    static let functionStarts: UInt32 = 0x26
    static let dyldEnvironment: UInt32 = 0x27
    static let main: UInt32 = 0x28 | requiresDynamicLinker
    static let dataInCode: UInt32 = 0x29
    static let sourceVersion: UInt32 = 0x2A
    static let dylibCodeSigningRequirements: UInt32 = 0x2B
    static let encryptionInfo64: UInt32 = 0x2C
    static let linkerOption: UInt32 = 0x2D
    static let linkerOptimizationHint: UInt32 = 0x2E
    static let versionMinTVOS: UInt32 = 0x2F
    static let versionMinWatchOS: UInt32 = 0x30
    static let note: UInt32 = 0x31
    static let buildVersion: UInt32 = 0x32
    static let dyldExportsTrie: UInt32 = 0x33 | requiresDynamicLinker
    static let dyldChainedFixups: UInt32 = 0x34 | requiresDynamicLinker
    static let fileSetEntry: UInt32 = 0x35 | requiresDynamicLinker
    static let atomInfo: UInt32 = 0x36

    /// The codes whose payload names a library by install name.
    static let dylibReferences: Set<UInt32> = [
        loadDylib, loadWeakDylib, reexportDylib, lazyLoadDylib, loadUpwardDylib, idDylib,
    ]

    /// The codes whose payload is a `linkedit_data_command`: an offset and a
    /// size locating data in the `__LINKEDIT` segment.
    static let linkEditDataReferences: Set<UInt32> = [
        codeSignature, segmentSplitInfo, functionStarts, dataInCode,
        dylibCodeSigningRequirements, linkerOptimizationHint, dyldExportsTrie,
        dyldChainedFixups, atomInfo,
    ]
}

/// What ZynSign knows about one load-command type: its published name, a
/// friendly title, its explorer group, and what it is for.
struct MachOLoadCommandDescriptor: Equatable, Hashable {

    /// The type code exactly as read from the binary.
    let type: UInt32

    /// The published constant name, for example `LC_LOAD_DYLIB`. For an
    /// unrecognised code, the code in hexadecimal.
    let name: String

    /// A short, friendly title, for example "Load Library".
    let title: String

    /// The explorer group.
    let category: MachOLoadCommandCategory

    /// One or two plain-language sentences describing the command's purpose.
    let purpose: String

    /// Whether the type is one ZynSign recognises.
    let isRecognized: Bool

    /// Whether the code carries the `LC_REQ_DYLD` bit: the dynamic linker
    /// must understand this command to load the binary.
    var requiresDynamicLinker: Bool {
        type & MachOLoadCommandCode.requiresDynamicLinker != 0
    }

    /// The type code as hexadecimal text, for advanced details.
    var typeCodeText: String {
        MachOHexadecimal.text(UInt64(type))
    }
}

/// The catalog of load-command descriptors.
///
/// Recognition is a naming convenience, never a filter: an unrecognised code
/// still produces a descriptor, named by its value and placed in `other`.
enum MachOLoadCommandCatalog {

    /// The descriptor for `type`.
    static func descriptor(for type: UInt32) -> MachOLoadCommandDescriptor {
        if let known = table[type] {
            return known
        }
        return MachOLoadCommandDescriptor(
            type: type,
            name: MachOHexadecimal.text(UInt64(type)),
            title: "Unrecognized Command",
            category: .other,
            purpose: "ZynSign does not recognise this command type. It is listed with its size so that nothing the binary declares is hidden.",
            isRecognized: false
        )
    }

    /// Every recognised descriptor, in type-code order.
    static var recognizedDescriptors: [MachOLoadCommandDescriptor] {
        table.values.sorted { ($0.type & 0x7FFF_FFFF) < ($1.type & 0x7FFF_FFFF) }
    }

    private static let table: [UInt32: MachOLoadCommandDescriptor] = {
        typealias Code = MachOLoadCommandCode
        let entries: [(UInt32, String, String, MachOLoadCommandCategory, String)] = [
            (Code.segment, "LC_SEGMENT", "Segment (32-bit)", .executable,
             "Maps a region of the file into memory, such as code or data, with its memory protections."),
            (Code.segment64, "LC_SEGMENT_64", "Segment", .executable,
             "Maps a region of the file into memory, such as code (__TEXT) or data (__DATA), with its memory protections."),
            (Code.main, "LC_MAIN", "Entry Point", .executable,
             "Marks where the program starts running once the system has loaded it."),
            (Code.unixThread, "LC_UNIXTHREAD", "Initial Thread State", .executable,
             "The older way of naming where a program starts: an initial register state."),
            (Code.thread, "LC_THREAD", "Thread State", .executable,
             "A thread's register state, mostly found in core files."),
            (Code.loadDylinker, "LC_LOAD_DYLINKER", "Dynamic Linker", .executable,
             "Names the dynamic linker that loads this binary and its libraries, normally /usr/lib/dyld."),
            (Code.idDylinker, "LC_ID_DYLINKER", "Dynamic Linker Identity", .executable,
             "Identifies this file as a dynamic linker."),
            (Code.routines, "LC_ROUTINES", "Initialization Routine (32-bit)", .executable,
             "A legacy library initialization routine."),
            (Code.routines64, "LC_ROUTINES_64", "Initialization Routine", .executable,
             "A legacy library initialization routine."),
            (Code.fileSetEntry, "LC_FILESET_ENTRY", "File Set Entry", .executable,
             "One member of a file set, a container format used by kernel collections."),

            (Code.loadDylib, "LC_LOAD_DYLIB", "Load Library", .libraries,
             "Declares a library that must be present for this binary to run."),
            (Code.loadWeakDylib, "LC_LOAD_WEAK_DYLIB", "Load Optional Library", .libraries,
             "Declares an optional library; the binary still runs when it is missing."),
            (Code.reexportDylib, "LC_REEXPORT_DYLIB", "Re-export Library", .libraries,
             "Declares a library whose symbols this binary offers as its own."),
            (Code.lazyLoadDylib, "LC_LAZY_LOAD_DYLIB", "Lazily Loaded Library", .libraries,
             "Declares a library that is loaded only when first used."),
            (Code.loadUpwardDylib, "LC_LOAD_UPWARD_DYLIB", "Upward Library", .libraries,
             "Declares a library that in turn depends on this one."),
            (Code.idDylib, "LC_ID_DYLIB", "Library Identity", .libraries,
             "Gives this library its own install name and versions; other binaries refer to it by that name."),
            (Code.runPath, "LC_RPATH", "Library Search Path", .libraries,
             "Adds a folder the loader searches when a library path begins with @rpath."),
            (Code.preboundDylib, "LC_PREBOUND_DYLIB", "Prebound Library", .libraries,
             "A legacy record of libraries this binary was prebound against."),
            (Code.subFramework, "LC_SUB_FRAMEWORK", "Umbrella Membership", .libraries,
             "Names the umbrella framework this library belongs to."),
            (Code.subUmbrella, "LC_SUB_UMBRELLA", "Sub-umbrella", .libraries,
             "Names a sub-umbrella framework re-exported by this umbrella."),
            (Code.subClient, "LC_SUB_CLIENT", "Allowed Client", .libraries,
             "Names a client that may link directly against this sub-framework."),
            (Code.subLibrary, "LC_SUB_LIBRARY", "Sub-library", .libraries,
             "Names a sub-library re-exported by this umbrella."),

            (Code.codeSignature, "LC_CODE_SIGNATURE", "Code Signature", .security,
             "Points to the embedded code signature, which records a hash of every page of code and who signed it."),
            (Code.encryptionInfo, "LC_ENCRYPTION_INFO", "Encryption Info (32-bit)", .security,
             "Describes the range protected by App Store encryption and whether it is encrypted in this file."),
            (Code.encryptionInfo64, "LC_ENCRYPTION_INFO_64", "Encryption Info", .security,
             "Describes the range protected by App Store encryption and whether it is encrypted in this file."),
            (Code.dylibCodeSigningRequirements, "LC_DYLIB_CODE_SIGN_DRS", "Library Signing Requirements", .security,
             "A legacy record of the designated requirements of linked libraries."),

            (Code.uuid, "LC_UUID", "Build UUID", .metadata,
             "A unique identifier for this build, used to match crash reports and debug symbols to the binary."),
            (Code.buildVersion, "LC_BUILD_VERSION", "Build Version", .metadata,
             "States the platform, the minimum OS version, and the SDK the binary was built for."),
            (Code.versionMinIPhoneOS, "LC_VERSION_MIN_IPHONEOS", "Minimum iOS Version", .metadata,
             "States the minimum iOS version and SDK, in the older form that predates Build Version."),
            (Code.versionMinMacOS, "LC_VERSION_MIN_MACOSX", "Minimum macOS Version", .metadata,
             "States the minimum macOS version and SDK, in the older form that predates Build Version."),
            (Code.versionMinTVOS, "LC_VERSION_MIN_TVOS", "Minimum tvOS Version", .metadata,
             "States the minimum tvOS version and SDK, in the older form that predates Build Version."),
            (Code.versionMinWatchOS, "LC_VERSION_MIN_WATCHOS", "Minimum watchOS Version", .metadata,
             "States the minimum watchOS version and SDK, in the older form that predates Build Version."),
            (Code.sourceVersion, "LC_SOURCE_VERSION", "Source Version", .metadata,
             "The source version the build was produced from, when the project set one."),
            (Code.note, "LC_NOTE", "Note", .metadata,
             "Arbitrary data recorded by a tool, identified by an owner name."),

            (Code.symbolTable, "LC_SYMTAB", "Symbol Table", .linking,
             "Locates the symbol table: the names of functions and variables in the binary."),
            (Code.dynamicSymbolTable, "LC_DYSYMTAB", "Dynamic Symbol Table", .linking,
             "Organises the symbol table into local, exported, and imported symbols for dynamic linking."),
            (Code.dyldInfo, "LC_DYLD_INFO", "Dynamic Linker Info", .linking,
             "Locates the rebase, binding, and export information the dynamic linker uses to prepare the binary."),
            (Code.dyldInfoOnly, "LC_DYLD_INFO_ONLY", "Dynamic Linker Info", .linking,
             "Locates the rebase, binding, and export information the dynamic linker uses to prepare the binary."),
            (Code.dyldChainedFixups, "LC_DYLD_CHAINED_FIXUPS", "Chained Fixups", .linking,
             "Locates the modern chained fixups the dynamic linker applies to pointers at load time."),
            (Code.dyldExportsTrie, "LC_DYLD_EXPORTS_TRIE", "Exported Symbols", .linking,
             "Locates the table of symbols this binary makes available to others."),
            (Code.functionStarts, "LC_FUNCTION_STARTS", "Function Starts", .linking,
             "Locates a compact list of where each function begins, used by debuggers and crash tools."),
            (Code.dataInCode, "LC_DATA_IN_CODE", "Data in Code", .linking,
             "Marks data tables embedded inside code, so tools do not treat them as instructions."),
            (Code.segmentSplitInfo, "LC_SEGMENT_SPLIT_INFO", "Segment Split Info", .linking,
             "Information that lets the system's shared cache builder relocate segments."),
            (Code.linkerOption, "LC_LINKER_OPTION", "Linker Options", .linking,
             "Linker flags embedded by the compiler, for example to link frameworks automatically."),
            (Code.linkerOptimizationHint, "LC_LINKER_OPTIMIZATION_HINT", "Linker Optimization Hints", .linking,
             "Hints the linker used to optimise instruction sequences."),
            (Code.dyldEnvironment, "LC_DYLD_ENVIRONMENT", "Linker Environment", .linking,
             "An environment setting the dynamic linker applies when loading this binary."),
            (Code.twoLevelHints, "LC_TWOLEVEL_HINTS", "Two-level Namespace Hints", .linking,
             "Legacy lookup hints for the two-level namespace."),
            (Code.prebindChecksum, "LC_PREBIND_CKSUM", "Prebinding Checksum", .linking,
             "A legacy checksum used by prebinding."),
            (Code.atomInfo, "LC_ATOM_INFO", "Atom Info", .linking,
             "Layout information recorded by the linker."),
        ]
        var table: [UInt32: MachOLoadCommandDescriptor] = [:]
        for (type, name, title, category, purpose) in entries {
            table[type] = MachOLoadCommandDescriptor(
                type: type,
                name: name,
                title: title,
                category: category,
                purpose: purpose,
                isRecognized: true
            )
        }
        return table
    }()
}

/// Hexadecimal rendering for advanced details. Presentation of a value, never
/// a substitute for it.
enum MachOHexadecimal {

    /// `0x`-prefixed uppercase hexadecimal, for example `0x80000028`.
    static func text(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    /// Lowercase hexadecimal of every byte, for digests shown in advanced
    /// details, optionally shortened with an ellipsis.
    static func bytes(_ data: Data, limit: Int? = nil) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        let count = limit.map { min($0, data.count) } ?? data.count
        text.reserveCapacity(count * 2 + 1)
        for byte in data.prefix(count) {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        if count < data.count {
            text.append("…")
        }
        return text
    }
}
