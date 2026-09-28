import Foundation

/// What a bounded header read can say about encryption.
///
/// `cryptid` is the value the load command records. Zero means the command
/// says the image is not encrypted yet. Absence of the command is not the
/// same statement, and neither value is a claim about FairPlay, trust, or
/// whether a device would accept the image.
enum ExplorerEncryptionStatus: Equatable, Hashable {

    case notEncrypted
    case encrypted(cryptid: UInt32)
    case commandAbsent
    case unreadable

    var displayName: String {
        switch self {
        case .notEncrypted: return "Not encrypted"
        case .encrypted(let cryptid): return "Encrypted (cryptid \(cryptid))"
        case .commandAbsent: return "No encryption command"
        case .unreadable: return "Not in preview"
        }
    }
}

/// Whether a Mach-O header names an embedded signature region.
///
/// Presence of `LC_CODE_SIGNATURE` is a structural observation. It does not
/// mean the signature verifies, that a certificate is trusted, or that the
/// application can be installed.
enum ExplorerSignaturePresence: Equatable, Hashable {

    case commandPresent
    case commandAbsent
    case unreadable

    var displayName: String {
        switch self {
        case .commandPresent: return "Signature command present"
        case .commandAbsent: return "No signature command"
        case .unreadable: return "Not in preview"
        }
    }

    /// Shown wherever a signature line could be mistaken for a verdict.
    static let disclaimer = "A signature command says only that the header names a signature region. It is not evidence the signature is valid or that the application can be installed."
}

/// One architecture slice as far as a prefix read could see it.
struct ExplorerMachOSlice: Equatable, Hashable, Identifiable {

    let index: Int
    let architectureName: String
    let fileTypeName: String
    let loadCommandCount: Int
    let encryption: ExplorerEncryptionStatus
    let signature: ExplorerSignaturePresence
    /// Whether every load command the header declared fit in the prefix.
    let commandsFullyRead: Bool

    var id: Int { index }
}

/// A clean Mach-O summary for the explorer. No hash slots, no hex dump, and
/// no verdict.
struct ExplorerMachOReport: Equatable, Hashable {

    enum Container: String, Equatable, Hashable {
        case thin
        case universal
    }

    let container: Container
    let slices: [ExplorerMachOSlice]
    let declaredByteCount: Int?
    let inspectedPrefixByteCount: Int
    /// Whether the bytes were a complete entry whose archive checksum was
    /// checked. A prefix of a larger file is never claimed to be checked.
    let checksumVerified: Bool

    var architectureSummary: String {
        let names = slices.map(\.architectureName).filter { !$0.isEmpty }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    var fileTypeSummary: String {
        let names = Array(Set(slices.map(\.fileTypeName))).sorted()
        if names.isEmpty { return "—" }
        if names.count == 1 { return names[0] }
        return "Mixed"
    }

    var loadCommandSummary: String {
        guard let first = slices.first(where: \.commandsFullyRead) ?? slices.first else { return "—" }
        if slices.count <= 1 { return String(first.loadCommandCount) }
        return slices.map { String($0.loadCommandCount) }.joined(separator: ", ")
    }

    var encryptionSummary: ExplorerEncryptionStatus {
        for slice in slices {
            if case .encrypted = slice.encryption {
                return slice.encryption
            }
        }
        let values = slices.map(\.encryption)
        if values.isEmpty { return .unreadable }
        if values.allSatisfy({ $0 == values[0] }) { return values[0] }
        return .unreadable
    }

    var signatureSummary: String {
        let values = slices.map(\.signature)
        if values.isEmpty { return ExplorerSignaturePresence.unreadable.displayName }
        if values.allSatisfy({ $0 == .commandPresent }) { return ExplorerSignaturePresence.commandPresent.displayName }
        if values.allSatisfy({ $0 == .commandAbsent }) { return ExplorerSignaturePresence.commandAbsent.displayName }
        if values.contains(.commandPresent) && values.contains(.commandAbsent) {
            return "Mixed across architectures"
        }
        if values.allSatisfy({ $0 == .unreadable }) { return ExplorerSignaturePresence.unreadable.displayName }
        return "See architectures"
    }

    var prefixWasPartial: Bool {
        slices.contains { !$0.commandsFullyRead } || checksumVerified == false && declaredByteCount.map { $0 > inspectedPrefixByteCount } == true
    }

    /// The note under the panel. Always disclaims signature validity.
    var note: String {
        var lines = [ExplorerSignaturePresence.disclaimer]
        if slices.contains(where: { !$0.commandsFullyRead }) {
            lines.append("Only the start of this file was read. Encryption and signature are reported only for load commands that fit in that prefix.")
        }
        if !checksumVerified {
            lines.append("The package checksum for the whole file was not verified.")
        }
        return lines.joined(separator: " ")
    }
}

/// One entitlement line on an extension or profile page.
///
/// Values are shortened. Arrays are counts, not contents, so a device list
/// cannot be dumped into the explorer by being stored as an entitlement value.
struct ExplorerEntitlementLine: Equatable, Hashable, Identifiable {

    let key: String
    let valueText: String

    var id: String { key }
}

/// A read-only summary of an embedded profile's declared property list.
///
/// Decoding the list is not CMS verification and not a policy decision.
struct ExplorerProfileSummary: Equatable, Hashable {

    let name: String?
    let teamIdentifiers: [String]
    let expiration: Date?
    /// A non-date expiration declaration, preserved when it was not a date.
    let expirationFallback: String?
    let entitlementLines: [ExplorerEntitlementLine]
    let entitlementsTruncated: Bool
    let note: String

    static let unverifiedNote = "Declared by the embedded profile, not verified. This is not a signature check, and it does not mean the profile authorizes the bundle."
}

/// The framework page. Version and signature are filled only when a bounded
/// read succeeded; absence is `nil` or `.unreadable`, never an invented value.
struct ExplorerFrameworkReport: Equatable, Hashable {

    let name: String
    let version: String?
    let build: String?
    let bundleIdentifier: String?
    let executableName: String?
    let executablePath: BundlePath?
    let signature: ExplorerSignaturePresence
    let declaredByteCount: Int
    let path: BundlePath
    let note: String
}

/// The extension page.
struct ExplorerExtensionReport: Equatable, Hashable {

    let name: String
    let kind: ExplorerExtensionKind
    let bundleIdentifier: String?
    let executableName: String?
    let executablePath: BundlePath?
    let version: String?
    let path: BundlePath
    let entitlementLines: [ExplorerEntitlementLine]
    let entitlementsTruncated: Bool
    let entitlementsNote: String
}

/// A text preview. `text` is a display copy. Producing it does not write the
/// package.
struct ExplorerTextPreview: Equatable, Hashable {

    enum Kind: String, Equatable, Hashable {
        case plain
        case json
        case xml
        case propertyList
    }

    let text: String
    let kind: Kind
    let truncated: Bool
    let byteCount: Int
    let checksumVerified: Bool

    var kindTitle: String {
        switch kind {
        case .plain: return "Text"
        case .json: return "JSON"
        case .xml: return "XML"
        case .propertyList: return "Property list"
        }
    }
}

/// Image bytes for the view to decode. The use case does not decode them and
/// does not retain them beyond the inspection result.
struct ExplorerImagePreview: Equatable, Hashable {
    let data: Data
    let checksumVerified: Bool
}

/// What the explorer can say about a file it will not render as text, an
/// image, or a Mach-O image. There is no hexadecimal dump.
struct ExplorerBinaryFacts: Equatable, Hashable {
    let readByteCount: Int
    let checksumVerified: Bool
    let message: String
}

/// The read-only inspection of one entry the user opened.
struct ExplorerEntryInspection: Equatable {

    let name: String
    let locationText: String
    let declaredByteCount: Int?
    let classification: BundleFileClassification
    let body: Body

    enum Body: Equatable {
        case text(ExplorerTextPreview)
        case image(ExplorerImagePreview)
        case macho(ExplorerMachOReport)
        case profile(ExplorerProfileSummary)
        case framework(ExplorerFrameworkReport)
        case appExtension(ExplorerExtensionReport)
        case binary(ExplorerBinaryFacts)
        case unavailable(title: String, message: String)
    }
}
