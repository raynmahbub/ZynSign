import Foundation

// Human-readable names for the values a Mach-O header, its load commands, and
// its code signature carry. Every name here is a rendering of a value read
// from the binary; none of them is a conclusion about what the binary does.

// MARK: - Architecture

/// A named CPU architecture: the family and subtype a slice declares, turned
/// into the name developers use (`arm64`, `arm64e`, `x86_64`).
struct MachOArchitectureName: Equatable {

    /// The CPU family the slice declares.
    let cpu: MachOCPU

    /// The declared subtype, including the capability bits in its top byte.
    let cpuSubtype: Int32

    /// The subtype without its capability bits.
    var subtypeValue: Int32 { cpuSubtype & 0x00FF_FFFF }

    /// The capability bits: the top byte of the subtype.
    var capabilityBits: UInt8 { UInt8(truncatingIfNeeded: UInt32(bitPattern: cpuSubtype) >> 24) }

    /// Whether this is `arm64e`, the pointer-authentication architecture.
    var isARM64E: Bool { cpu == .arm64 && subtypeValue == 2 }

    /// Whether an `arm64e` slice declares the versioned pointer-authentication
    /// ABI (`CPU_SUBTYPE_PTRAUTH_ABI`).
    var declaresPointerAuthenticationABI: Bool {
        isARM64E && capabilityBits & 0x80 != 0
    }

    /// The pointer-authentication ABI version an `arm64e` slice declares.
    var pointerAuthenticationABIVersion: Int? {
        guard declaresPointerAuthenticationABI else { return nil }
        return Int(capabilityBits & 0x0F)
    }

    /// Whether the architecture runs on current iPhone and iPad hardware.
    var isAppleDeviceArchitecture: Bool { cpu == .arm64 }

    /// The developer-facing name, for example `arm64e`.
    var name: String {
        switch cpu {
        case .arm64:
            switch subtypeValue {
            case 0: return "arm64"
            case 1: return "arm64 (v8)"
            case 2: return "arm64e"
            default: return "arm64 (subtype \(subtypeValue))"
            }
        case .arm:
            switch subtypeValue {
            case 6: return "armv6"
            case 9: return "armv7"
            case 10: return "armv7f"
            case 11: return "armv7s"
            case 12: return "armv7k"
            case 13: return "armv8"
            case 14: return "armv6m"
            case 15: return "armv7m"
            case 16: return "armv7em"
            default: return "arm (subtype \(subtypeValue))"
            }
        case .x86_64:
            return subtypeValue == 8 ? "x86_64h" : "x86_64"
        case .x86:
            return "i386"
        case .other(let value):
            return "CPU type \(value)"
        }
    }

    /// The CPU family's published constant name.
    var cpuTypeName: String {
        switch cpu {
        case .arm64: return "CPU_TYPE_ARM64"
        case .arm: return "CPU_TYPE_ARM"
        case .x86_64: return "CPU_TYPE_X86_64"
        case .x86: return "CPU_TYPE_X86"
        case .other: return "Unrecognized CPU type"
        }
    }

    /// The subtype's published constant name, when ZynSign knows it.
    var cpuSubtypeName: String {
        switch cpu {
        case .arm64:
            switch subtypeValue {
            case 0: return "CPU_SUBTYPE_ARM64_ALL"
            case 1: return "CPU_SUBTYPE_ARM64_V8"
            case 2: return "CPU_SUBTYPE_ARM64E"
            default: return "Unrecognized subtype"
            }
        case .x86_64:
            return subtypeValue == 8 ? "CPU_SUBTYPE_X86_64_H" : "CPU_SUBTYPE_X86_64_ALL"
        case .x86:
            return "CPU_SUBTYPE_I386_ALL"
        case .arm:
            return subtypeValue == 9 ? "CPU_SUBTYPE_ARM_V7" : (subtypeValue == 11 ? "CPU_SUBTYPE_ARM_V7S" : "ARM subtype")
        case .other:
            return "Unrecognized subtype"
        }
    }

    /// A plain-language explanation of the architecture.
    var explanation: String {
        switch cpu {
        case .arm64:
            if isARM64E {
                return "64-bit Apple silicon with pointer authentication, the architecture of system software on recent devices."
            }
            return "64-bit Apple silicon, the architecture every current iPhone and iPad runs."
        case .arm:
            return "32-bit ARM. Current iOS versions no longer run 32-bit code."
        case .x86_64:
            return "64-bit Intel, used by Mac apps and the iOS Simulator on Intel Macs. It does not run on iPhone or iPad."
        case .x86:
            return "32-bit Intel, a legacy simulator architecture. It does not run on iPhone or iPad."
        case .other:
            return "A CPU family ZynSign does not recognise."
        }
    }

    /// The raw numeric CPU type.
    var rawCPUType: Int32 {
        switch cpu {
        case .arm: return 12
        case .arm64: return 0x0100_000C
        case .x86: return 7
        case .x86_64: return 0x0100_0007
        case .other(let value): return value
        }
    }
}

// MARK: - File type

/// The kind of file a Mach-O header declares (`MH_EXECUTE`, `MH_DYLIB`, …).
enum MachOFileKind: Equatable, Hashable {
    case object
    case executable
    case fixedVirtualMemoryLibrary
    case core
    case preloaded
    case dynamicLibrary
    case dynamicLinker
    case bundle
    case dynamicLibraryStub
    case debugSymbols
    case kernelExtension
    case fileSet
    case unknown(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0x1: self = .object
        case 0x2: self = .executable
        case 0x3: self = .fixedVirtualMemoryLibrary
        case 0x4: self = .core
        case 0x5: self = .preloaded
        case 0x6: self = .dynamicLibrary
        case 0x7: self = .dynamicLinker
        case 0x8: self = .bundle
        case 0x9: self = .dynamicLibraryStub
        case 0xA: self = .debugSymbols
        case 0xB: self = .kernelExtension
        case 0xC: self = .fileSet
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: UInt32 {
        switch self {
        case .object: return 0x1
        case .executable: return 0x2
        case .fixedVirtualMemoryLibrary: return 0x3
        case .core: return 0x4
        case .preloaded: return 0x5
        case .dynamicLibrary: return 0x6
        case .dynamicLinker: return 0x7
        case .bundle: return 0x8
        case .dynamicLibraryStub: return 0x9
        case .debugSymbols: return 0xA
        case .kernelExtension: return 0xB
        case .fileSet: return 0xC
        case .unknown(let value): return value
        }
    }

    var displayName: String {
        switch self {
        case .object: return "Object File"
        case .executable: return "Executable"
        case .fixedVirtualMemoryLibrary: return "Fixed VM Library"
        case .core: return "Core File"
        case .preloaded: return "Preloaded Executable"
        case .dynamicLibrary: return "Dynamic Library"
        case .dynamicLinker: return "Dynamic Linker"
        case .bundle: return "Bundle"
        case .dynamicLibraryStub: return "Library Stub"
        case .debugSymbols: return "Debug Symbols"
        case .kernelExtension: return "Kernel Extension"
        case .fileSet: return "File Set"
        case .unknown(let value): return "Unknown (\(value))"
        }
    }

    /// The published constant name.
    var constantName: String {
        switch self {
        case .object: return "MH_OBJECT"
        case .executable: return "MH_EXECUTE"
        case .fixedVirtualMemoryLibrary: return "MH_FVMLIB"
        case .core: return "MH_CORE"
        case .preloaded: return "MH_PRELOAD"
        case .dynamicLibrary: return "MH_DYLIB"
        case .dynamicLinker: return "MH_DYLINKER"
        case .bundle: return "MH_BUNDLE"
        case .dynamicLibraryStub: return "MH_DYLIB_STUB"
        case .debugSymbols: return "MH_DSYM"
        case .kernelExtension: return "MH_KEXT_BUNDLE"
        case .fileSet: return "MH_FILESET"
        case .unknown: return "Unrecognized"
        }
    }

    var explanation: String {
        switch self {
        case .executable:
            return "A program the system can launch, such as an app's main executable or an extension."
        case .dynamicLibrary:
            return "A library loaded into other programs at run time, such as the binary inside a framework."
        case .bundle:
            return "Code loaded explicitly by a host program, such as a plug-in."
        case .object:
            return "An intermediate compiler output that is not normally shipped in an app."
        case .debugSymbols:
            return "Debug information only; it carries no runnable code."
        default:
            return "A Mach-O file kind that is unusual inside an iOS app."
        }
    }
}

// MARK: - Flags

/// One named bit in a flag field.
struct MachOFlagDescription: Equatable, Hashable, Identifiable {
    let mask: UInt64
    let name: String
    let explanation: String

    var id: UInt64 { mask }
}

/// A flag field broken into the bits ZynSign names and the bits it does not.
struct MachODecodedFlags: Equatable {
    let raw: UInt64
    let known: [MachOFlagDescription]
    let unknownBits: UInt64

    static func decode(_ raw: UInt64, using table: [MachOFlagDescription]) -> MachODecodedFlags {
        var remaining = raw
        var known: [MachOFlagDescription] = []
        for flag in table where raw & flag.mask == flag.mask && flag.mask != 0 {
            known.append(flag)
            remaining &= ~flag.mask
        }
        return MachODecodedFlags(raw: raw, known: known, unknownBits: remaining)
    }

    /// The known names joined for a single line, or "None".
    var summary: String {
        if known.isEmpty && unknownBits == 0 { return "None" }
        var parts = known.map(\.name)
        if unknownBits != 0 {
            parts.append("other bits \(MachOHexadecimal.text(unknownBits))")
        }
        return parts.joined(separator: ", ")
    }
}

/// The Mach-O header flags (`MH_*`) ZynSign names.
enum MachOHeaderFlagTable {
    static let flags: [MachOFlagDescription] = [
        MachOFlagDescription(mask: 0x1, name: "No undefined references",
                             explanation: "Every symbol the binary uses is defined somewhere it links against."),
        MachOFlagDescription(mask: 0x4, name: "Dynamically linked",
                             explanation: "The binary is prepared by the dynamic linker when it loads."),
        MachOFlagDescription(mask: 0x80, name: "Two-level namespace",
                             explanation: "Each imported symbol is bound to the library it came from, which prevents name clashes."),
        MachOFlagDescription(mask: 0x2000, name: "Subsections via symbols",
                             explanation: "Code sections can be split at symbol boundaries for dead-code stripping."),
        MachOFlagDescription(mask: 0x8000, name: "Defines weak symbols",
                             explanation: "The binary exports symbols that others may override."),
        MachOFlagDescription(mask: 0x10000, name: "Uses weak symbols",
                             explanation: "The binary imports symbols that may be overridden."),
        MachOFlagDescription(mask: 0x20000, name: "Executable stack allowed",
                             explanation: "The binary asks for an executable stack, which weakens memory protection."),
        MachOFlagDescription(mask: 0x100000, name: "No re-exported libraries",
                             explanation: "The library re-exports nothing from its dependencies."),
        MachOFlagDescription(mask: 0x200000, name: "Position independent (PIE)",
                             explanation: "The program is loaded at a random address each launch, which hardens it against attacks."),
        MachOFlagDescription(mask: 0x400000, name: "Dead-strippable library",
                             explanation: "The linker may drop this library when nothing uses it."),
        MachOFlagDescription(mask: 0x800000, name: "Thread-local variables",
                             explanation: "The binary uses thread-local storage."),
        MachOFlagDescription(mask: 0x1000000, name: "No heap execution",
                             explanation: "The binary asks that its heap never be executable."),
        MachOFlagDescription(mask: 0x2000000, name: "App extension safe",
                             explanation: "The code avoids APIs that are unavailable to app extensions."),
        MachOFlagDescription(mask: 0x8000000, name: "Simulator support",
                             explanation: "The binary is marked as supporting the simulator."),
        MachOFlagDescription(mask: 0x80000000, name: "In shared cache",
                             explanation: "The library lives in the system's shared cache."),
    ]

    static func decode(_ flags: UInt32) -> MachODecodedFlags {
        MachODecodedFlags.decode(UInt64(flags), using: self.flags)
    }
}

/// The CodeDirectory flags (`CS_*`) ZynSign names.
enum CodeDirectoryFlagTable {
    static let adHoc: UInt32 = 0x2
    static let runtime: UInt32 = 0x10000
    static let linkerSigned: UInt32 = 0x20000

    static let flags: [MachOFlagDescription] = [
        MachOFlagDescription(mask: 0x2, name: "Ad-hoc",
                             explanation: "Signed without a certificate: the signature binds the code but names no signer."),
        MachOFlagDescription(mask: 0x100, name: "Hard",
                             explanation: "The process must not load pages that are invalid."),
        MachOFlagDescription(mask: 0x200, name: "Kill",
                             explanation: "The process is terminated if its signature becomes invalid."),
        MachOFlagDescription(mask: 0x400, name: "Check expiration",
                             explanation: "The signing certificate's expiration is enforced."),
        MachOFlagDescription(mask: 0x800, name: "Restrict",
                             explanation: "Restricts how other processes may interact with this one."),
        MachOFlagDescription(mask: 0x1000, name: "Enforcement",
                             explanation: "Code-signing enforcement is required."),
        MachOFlagDescription(mask: 0x2000, name: "Library validation",
                             explanation: "Only libraries signed by the same team or by Apple may be loaded."),
        MachOFlagDescription(mask: 0x10000, name: "Hardened runtime",
                             explanation: "Runtime protections apply unless an entitlement relaxes them."),
        MachOFlagDescription(mask: 0x20000, name: "Linker-signed",
                             explanation: "The signature was added automatically by the linker at build time, not by a signing step."),
    ]

    static func decode(_ flags: UInt32) -> MachODecodedFlags {
        MachODecodedFlags.decode(UInt64(flags), using: self.flags)
    }
}

/// The executable-segment flags (`CS_EXECSEG_*`) ZynSign names.
enum ExecutableSegmentFlagTable {
    static let flags: [MachOFlagDescription] = [
        MachOFlagDescription(mask: 0x1, name: "Main binary",
                             explanation: "This is the main executable of its process."),
        MachOFlagDescription(mask: 0x10, name: "Allow unsigned pages",
                             explanation: "Unsigned pages are allowed, usually for debugging."),
        MachOFlagDescription(mask: 0x20, name: "Debugger",
                             explanation: "The process may debug others."),
        MachOFlagDescription(mask: 0x40, name: "JIT",
                             explanation: "The process may generate code at run time."),
        MachOFlagDescription(mask: 0x80, name: "Skip library validation",
                             explanation: "Library validation is skipped for this process."),
        MachOFlagDescription(mask: 0x100, name: "Can load by CDHash",
                             explanation: "The process may load code identified by CDHash."),
        MachOFlagDescription(mask: 0x200, name: "Can execute by CDHash",
                             explanation: "The process may execute code identified by CDHash."),
    ]

    static func decode(_ flags: UInt64) -> MachODecodedFlags {
        MachODecodedFlags.decode(flags, using: self.flags)
    }
}

// MARK: - Hash types

extension MachOHashType {

    /// The name of the hash a CodeDirectory declares.
    var displayName: String {
        switch self {
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha256Truncated: return "SHA-256 (truncated to 20 bytes)"
        case .sha384: return "SHA-384"
        case .other(let value): return "Unrecognized (\(value))"
        }
    }

    /// The digest algorithm that produces this hash, when ZynSign computes it.
    var digestAlgorithm: DigestAlgorithm? {
        switch self {
        case .sha1: return .sha1
        case .sha256, .sha256Truncated: return .sha256
        case .sha384: return .sha384
        case .other: return nil
        }
    }

    /// Whether the algorithm is considered weak on its own. SHA-1 remains in
    /// the format for compatibility, but modern signatures pair or replace it.
    var isLegacy: Bool {
        self == .sha1
    }
}

// MARK: - Versions

/// A version packed as `xxxx.yy.zz` in 32 bits, the form Mach-O uses for
/// library, OS, and SDK versions.
struct MachOPackedVersion: Equatable, Hashable, Comparable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var major: Int { Int(rawValue >> 16) }
    var minor: Int { Int((rawValue >> 8) & 0xFF) }
    var patch: Int { Int(rawValue & 0xFF) }

    /// `13.1` or `13.1.2`; the patch component is omitted when zero.
    var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func < (lhs: MachOPackedVersion, rhs: MachOPackedVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The source version packed as `A.B.C.D.E` in 64 bits (24.10.10.10.10).
struct MachOSourceVersion: Equatable, Hashable, CustomStringConvertible {
    let rawValue: UInt64

    var isSet: Bool { rawValue != 0 }

    var description: String {
        let a = rawValue >> 40
        let b = (rawValue >> 30) & 0x3FF
        let c = (rawValue >> 20) & 0x3FF
        let d = (rawValue >> 10) & 0x3FF
        let e = rawValue & 0x3FF
        var parts = [String(a), String(b)]
        if c != 0 || d != 0 || e != 0 { parts.append(String(c)) }
        if d != 0 || e != 0 { parts.append(String(d)) }
        if e != 0 { parts.append(String(e)) }
        return parts.joined(separator: ".")
    }
}

// MARK: - Platforms and tools

/// The platform a build-version record names.
enum MachOPlatform: Equatable, Hashable {
    case macOS
    case iOS
    case tvOS
    case watchOS
    case bridgeOS
    case macCatalyst
    case iOSSimulator
    case tvOSSimulator
    case watchOSSimulator
    case driverKit
    case visionOS
    case visionOSSimulator
    case unknown(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 1: self = .macOS
        case 2: self = .iOS
        case 3: self = .tvOS
        case 4: self = .watchOS
        case 5: self = .bridgeOS
        case 6: self = .macCatalyst
        case 7: self = .iOSSimulator
        case 8: self = .tvOSSimulator
        case 9: self = .watchOSSimulator
        case 10: self = .driverKit
        case 11: self = .visionOS
        case 12: self = .visionOSSimulator
        default: self = .unknown(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .tvOS: return "tvOS"
        case .watchOS: return "watchOS"
        case .bridgeOS: return "bridgeOS"
        case .macCatalyst: return "Mac Catalyst"
        case .iOSSimulator: return "iOS Simulator"
        case .tvOSSimulator: return "tvOS Simulator"
        case .watchOSSimulator: return "watchOS Simulator"
        case .driverKit: return "DriverKit"
        case .visionOS: return "visionOS"
        case .visionOSSimulator: return "visionOS Simulator"
        case .unknown(let value): return "Platform \(value)"
        }
    }

    var isSimulator: Bool {
        switch self {
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator, .visionOSSimulator: return true
        default: return false
        }
    }
}

/// One tool a build-version record lists.
struct MachOBuildTool: Equatable, Hashable {
    let tool: UInt32
    let version: MachOPackedVersion

    var name: String {
        switch tool {
        case 1: return "Clang"
        case 2: return "Swift"
        case 3: return "ld"
        case 4: return "LLD"
        case 1024: return "Metal"
        default: return "Tool \(tool)"
        }
    }
}

// MARK: - Memory protection and sections

/// A segment's memory protection (`VM_PROT_*`).
struct MachOMemoryProtection: Equatable, Hashable, CustomStringConvertible {
    let rawValue: UInt32

    var isReadable: Bool { rawValue & 0x1 != 0 }
    var isWritable: Bool { rawValue & 0x2 != 0 }
    var isExecutable: Bool { rawValue & 0x4 != 0 }

    /// `r-x` style, the notation developers read.
    var description: String {
        (isReadable ? "r" : "-") + (isWritable ? "w" : "-") + (isExecutable ? "x" : "-")
    }

    /// The protection in words, for VoiceOver and explanations.
    var spokenDescription: String {
        var parts: [String] = []
        if isReadable { parts.append("read") }
        if isWritable { parts.append("write") }
        if isExecutable { parts.append("execute") }
        return parts.isEmpty ? "no access" : parts.joined(separator: ", ")
    }
}

/// Section types (`S_*`, the low byte of a section's flags) ZynSign names.
enum MachOSectionTypeName {
    static func name(for type: UInt32) -> String {
        switch type {
        case 0x0: return "Regular"
        case 0x1: return "Zero-filled"
        case 0x2: return "C strings"
        case 0x3: return "4-byte literals"
        case 0x4: return "8-byte literals"
        case 0x5: return "Literal pointers"
        case 0x6: return "Non-lazy symbol pointers"
        case 0x7: return "Lazy symbol pointers"
        case 0x8: return "Symbol stubs"
        case 0x9: return "Initializer pointers"
        case 0xA: return "Terminator pointers"
        case 0xB: return "Coalesced"
        case 0xC: return "Large zero-filled"
        case 0xD: return "Interposing"
        case 0xE: return "16-byte literals"
        case 0xF: return "DTrace object format"
        case 0x10: return "Lazy library symbol pointers"
        case 0x11: return "Thread-local regular"
        case 0x12: return "Thread-local zero-filled"
        case 0x13: return "Thread-local variables"
        case 0x14: return "Thread-local variable pointers"
        case 0x15: return "Thread-local initializers"
        case 0x16: return "Initializer offsets"
        default: return "Type \(type)"
        }
    }
}

// MARK: - Text

/// Turns untrusted bytes from a binary into displayable text.
enum MachOText {

    /// Decodes a fixed-width, NUL-padded name (segment and section names).
    static func fixedName(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return sanitized(String(decoding: trimmed, as: UTF8.self), limit: 32)
    }

    /// Replaces control characters and bounds the length, so a hostile
    /// binary cannot inject layout-breaking or misleading text.
    static func sanitized(_ value: String, limit: Int) -> String {
        let cleaned = String(value.map { $0.isControlCharacter ? "\u{FFFD}" : $0 })
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }
}

private extension Character {
    var isControlCharacter: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.value == 0x7F
        }
    }
}
