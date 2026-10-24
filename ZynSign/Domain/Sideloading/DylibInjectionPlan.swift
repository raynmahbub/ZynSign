import Foundation

/// The header facts injection needs, read by the platform parser.
///
/// Injection writes a load command into the padding between the load commands
/// and the first section. Whether that paddle exists is a property of the
/// image, so the platform layer reports the layout and this layer decides
/// whether the command fits — the decision stays testable without a file.
struct MachOHeaderLayout: Equatable, Sendable {

    /// `mach_header_64` size: 32 bytes for every image this app signs.
    let headerSize: Int
    let numberOfCommands: Int
    let sizeOfCommands: Int
    /// File offset of the first byte of section content, or `nil` when the
    /// image has no sections at all (nothing to protect, nothing to overlap).
    let firstSectionFileOffset: Int?
    /// Lowest non-zero file offset of any segment's content.
    let firstSegmentFileOffset: Int?
    let hasCodeSignatureCommand: Bool
    /// True when a `__LINKEDIT` (or last file-backed) segment command is
    /// present, so the appended signature can be covered.
    let hasLinkeditSegment: Bool

    /// Bytes between the end of the load commands and the first content.
    var headerPadding: Int {
        let candidates = [firstSectionFileOffset, firstSegmentFileOffset]
            .compactMap { $0 }
            .filter { $0 > 0 }
        guard let first = candidates.min() else { return 0 }
        return max(0, first - (headerSize + sizeOfCommands))
    }
}

/// A refusal about the image's header. Each case names the arithmetic.
enum DylibInjectionError: Error, Equatable, Hashable, Sendable {
    case invalidHeaderLayout
    case insufficientHeaderSpace(required: Int, available: Int)
    case installNameTooLong(bytes: Int)
    case missingLinkeditSegment
    case tooManyCommands(count: Int)

    var message: String {
        switch self {
        case .invalidHeaderLayout:
            return "The Mach-O header layout is inconsistent."
        case .insufficientHeaderSpace(let required, let available):
            return "The image has \(available) bytes of header padding; "
                + "\(required) are needed. Remove an injected library or choose another binary."
        case .installNameTooLong(let bytes):
            return "The install name is \(bytes) bytes; a load command path is limited to 1024."
        case .missingLinkeditSegment:
            return "The image has no file-backed segment that can cover an appended signature."
        case .tooManyCommands(let count):
            return "The image already declares \(count) load commands; that is beyond the supported limit."
        }
    }
}

/// The exact bytes injection adds, and the header facts afterwards.
struct DylibInjectionPlan: Equatable, Sendable {
    let loadCommand: Data
    let installName: String
    let isWeak: Bool
    let resultingSizeOfCommands: Int
    let remainingPadding: Int
}

enum DylibInjectionPlanner {

    static let loadDylibCommand: UInt32 = 0x0000_000C
    static let loadWeakDylibCommand: UInt32 = 0x8000_0018
    static let codeSignatureCommand: UInt32 = 0x0000_001D
    /// `sizeof(struct dylib_command)` = cmd, cmdsize, name.offset, timestamp,
    /// current_version, compatibility_version.
    static let dylibCommandSize = 24
    static let codeSignatureCommandSize = 16
    static let maximumCommands = 4_096

    /// The `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` command, little-endian,
    /// padded to eight bytes exactly as `ld` writes it.
    static func loadCommand(installName: String, isWeak: Bool) throws -> Data {
        let encoded = Array(installName.utf8) + [0]
        guard encoded.count <= 1_024 else {
            throw DylibInjectionError.installNameTooLong(bytes: encoded.count)
        }
        let padding = (8 - (dylibCommandSize + encoded.count) % 8) % 8
        let size = dylibCommandSize + encoded.count + padding
        var data = Data(capacity: size)
        appendLittleEndian(isWeak ? loadWeakDylibCommand : loadDylibCommand, to: &data)
        appendLittleEndian(UInt32(size), to: &data)
        appendLittleEndian(UInt32(dylibCommandSize), to: &data)  // name offset
        appendLittleEndian(UInt32(2), to: &data)                 // timestamp, as `ld` writes it
        appendLittleEndian(UInt32(0x1_0000), to: &data)          // current version 1.0
        appendLittleEndian(UInt32(0x1_0000), to: &data)          // compatibility 1.0
        data.append(contentsOf: encoded)
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        return data
    }

    /// Plan every command the options need, or refuse with the arithmetic.
    static func plan(for layout: MachOHeaderLayout,
                     injecting libraries: [InjectedLibrary]) throws -> [DylibInjectionPlan] {
        guard layout.headerSize > 0, layout.sizeOfCommands >= 0,
              layout.numberOfCommands >= 0,
              layout.numberOfCommands <= maximumCommands else {
            throw DylibInjectionError.invalidHeaderLayout
        }
        guard layout.hasLinkeditSegment else {
            throw DylibInjectionError.missingLinkeditSegment
        }
        var required = layout.hasCodeSignatureCommand ? 0 : codeSignatureCommandSize
        var commands: [(Data, String, Bool)] = []
        for library in libraries {
            let bytes = try loadCommand(installName: library.installName,
                                        isWeak: library.isWeak)
            required += bytes.count
            commands.append((bytes, library.installName, library.isWeak))
        }
        let available = layout.headerPadding
        guard required <= available else {
            throw DylibInjectionError.insufficientHeaderSpace(
                required: required, available: available)
        }
        // The room check counts the signature command this plan will add, so
        // the resulting table has to count it too: reporting a table 16 bytes
        // shorter than the one the writer will produce under-reports the space
        // the injection consumes.
        var running = layout.sizeOfCommands
            + (layout.hasCodeSignatureCommand ? 0 : codeSignatureCommandSize)
        return commands.map { bytes, name, weak in
            running += bytes.count
            return DylibInjectionPlan(
                loadCommand: bytes,
                installName: name,
                isWeak: weak,
                resultingSizeOfCommands: running,
                remainingPadding: available - (running - layout.sizeOfCommands)
            )
        }
    }

    /// Whether the image can take the command at all, without planning it.
    static func canInject(into layout: MachOHeaderLayout,
                          requiredBytes: Int) -> Bool {
        layout.hasLinkeditSegment && layout.headerPadding >= requiredBytes
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// Ad-hoc code-signing policy: what changes when no identity is used.
///
/// The CodeDirectory records the mode, and the SuperBlob simply has no CMS
/// slot. Naming the policy keeps "ad-hoc" from being an empty certificate
/// optional, which is how it reaches the UI as a decision with consequences.
struct AdHocSignaturePolicy: Equatable, Sendable {
    /// `CS_ADHOC` in the CodeDirectory flags.
    static let adHocFlag: UInt32 = 0x0000_0002
    /// `CS_RUNTIME`, applied only when the user asks for it.
    static let runtimeFlag: UInt32 = 0x0001_0000

    let hardenedRuntime: Bool

    var codeDirectoryFlags: UInt32 {
        Self.adHocFlag | (hardenedRuntime ? Self.runtimeFlag : 0)
    }

    /// An ad-hoc signature is not a trusted identity. On a stock device the
    /// installer refuses it; a container that loads the image itself does not
    /// ask the installer at all.
    var trustStatement: String {
        "Ad-hoc signatures carry no certificate chain. "
            + "A stock device will refuse to install the package; "
            + "the in-app container can still load it."
    }
}
