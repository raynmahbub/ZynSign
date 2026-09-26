import Foundation

/// The form an embedded signature takes, read from its CodeDirectory flags
/// and its CMS blob.
///
/// The form describes structure only. `certificate` means a CMS signature
/// payload is present, not that it verifies or that its certificate is
/// trusted; verification is reported separately.
enum CodeSignatureForm: String, Equatable, Hashable {
    /// A CMS signature payload is present: the signature names a signer.
    case certificate
    /// Signed without a certificate (`CS_ADHOC`), with no CMS payload.
    case adHoc
    /// Signed automatically by the linker at build time (`CS_LINKER_SIGNED`).
    case linkerSigned
    /// A CodeDirectory without the ad-hoc flag and without a CMS payload: the
    /// signature claims a signer but carries no signer data.
    case incomplete

    static func classify(primaryFlags: UInt32?, cmsPayloadByteCount: Int?) -> CodeSignatureForm {
        if let bytes = cmsPayloadByteCount, bytes > 0 {
            return .certificate
        }
        let flags = primaryFlags ?? 0
        if flags & CodeDirectoryFlagTable.linkerSigned != 0 {
            return .linkerSigned
        }
        if flags & CodeDirectoryFlagTable.adHoc != 0 {
            return .adHoc
        }
        return .incomplete
    }

    var displayName: String {
        switch self {
        case .certificate: return "Certificate-based"
        case .adHoc: return "Ad-hoc"
        case .linkerSigned: return "Linker-signed (ad-hoc)"
        case .incomplete: return "Incomplete"
        }
    }

    var explanation: String {
        switch self {
        case .certificate:
            return "The signature carries a CMS message that names the certificate used to sign it."
        case .adHoc:
            return "The signature binds the code's hashes but names no certificate. iOS does not run ad-hoc signed apps unless they are re-signed."
        case .linkerSigned:
            return "The linker added an ad-hoc signature at build time so the code is internally consistent. It names no certificate and is normally replaced when the app is signed."
        case .incomplete:
            return "The CodeDirectory does not declare an ad-hoc signature, yet no CMS signature payload is present."
        }
    }
}

/// One blob inside the signature SuperBlob.
struct CodeSignatureBlobSummary: Equatable, Hashable, Identifiable {
    let slotNumber: UInt32
    let slot: CodeSignatureBlobType
    let magic: UInt32
    let byteCount: Int

    var id: UInt32 { slotNumber }

    var title: String {
        switch slot {
        case .codeDirectory: return "CodeDirectory"
        case .alternateCodeDirectory(let index): return "Alternate CodeDirectory \(index + 1)"
        case .requirements: return "Requirements"
        case .entitlements: return "Entitlements (XML)"
        case .derEntitlements: return "Entitlements (DER)"
        case .cms: return "CMS Signature"
        case .other(let value):
            switch value {
            case 8...11: return "Launch Constraint"
            default: return "Slot \(MachOHexadecimal.text(UInt64(value)))"
            }
        }
    }

    var explanation: String {
        switch slot {
        case .codeDirectory, .alternateCodeDirectory:
            return "Lists the hash of every page of code and of the signature's other parts."
        case .requirements:
            return "Rules describing which signatures count as this code, such as its designated requirement."
        case .entitlements:
            return "The capabilities the code claims, as a property list."
        case .derEntitlements:
            return "The same entitlements in the binary DER form newer iOS versions read."
        case .cms:
            return "The cryptographic signature over the CodeDirectory, with the signer's certificates."
        case .other:
            return "A signature component ZynSign lists without interpreting."
        }
    }
}

/// One reserved special slot of a CodeDirectory.
struct CodeDirectorySpecialSlotSummary: Equatable, Hashable, Identifiable {
    /// The slot's positive ordinal (`1` is Info.plist). The format stores it
    /// at negative index `-number`.
    let number: Int
    /// Whether the slot declares a digest (any nonzero byte).
    let isBound: Bool

    var id: Int { number }
    var title: String { Self.title(for: number) }
    var explanation: String { Self.explanation(for: number) }

    static func title(for number: Int) -> String {
        switch number {
        case 1: return "Info.plist"
        case 2: return "Requirements"
        case 3: return "Resource Seal"
        case 4: return "Application-specific"
        case 5: return "Entitlements (XML)"
        case 6: return "Representation-specific"
        case 7: return "Entitlements (DER)"
        case 8: return "Launch Constraint (self)"
        case 9: return "Launch Constraint (parent)"
        case 10: return "Launch Constraint (responsible)"
        case 11: return "Library Constraint"
        default: return "Special Slot \(number)"
        }
    }

    static func explanation(for number: Int) -> String {
        switch number {
        case 1: return "Binds the bundle's Info.plist, so editing it breaks the signature."
        case 2: return "Binds the requirement set stored in the signature."
        case 3: return "Binds _CodeSignature/CodeResources, which in turn lists a hash for every resource file."
        case 4: return "Reserved for application-specific data."
        case 5: return "Binds the XML entitlements stored in the signature."
        case 6: return "Reserved for representation-specific data."
        case 7: return "Binds the DER entitlements stored in the signature."
        case 8, 9, 10: return "Binds a launch constraint stored in the signature."
        case 11: return "Binds a library-loading constraint stored in the signature."
        default: return "A special slot ZynSign does not name."
        }
    }
}

/// One CodeDirectory, summarised for inspection.
struct CodeDirectorySummary: Equatable, Identifiable {
    /// The SuperBlob slot: `0` for the primary CodeDirectory, `0x1000`+ for
    /// alternates.
    let slotNumber: UInt32
    let isPrimary: Bool
    let version: UInt32
    let flags: UInt32
    let hashType: MachOHashType
    let hashSize: Int
    let pageSizeExponent: UInt8
    let pageCount: Int
    let codeLimit: UInt64
    let identifier: String
    let teamIdentifier: String?
    let platform: UInt8
    let specialSlots: [CodeDirectorySpecialSlotSummary]
    let executableSegmentBase: UInt64?
    let executableSegmentLimit: UInt64?
    let executableSegmentFlags: UInt64?
    let runtimeVersion: MachOPackedVersion?
    let hasScatter: Bool
    let hasPreEncryptionHashes: Bool
    let hasLinkage: Bool
    let byteCount: Int
    /// The CodeDirectory hash (CDHash): the first 20 bytes of the digest of
    /// the CodeDirectory blob under its own hash type. `nil` when it was not
    /// computed.
    let cdHash: Data?

    var id: UInt32 { slotNumber }

    init(slotNumber: UInt32, directory: MachOCodeDirectory, byteCount: Int, cdHash: Data?) {
        self.slotNumber = slotNumber
        self.isPrimary = slotNumber == 0
        self.version = directory.version
        self.flags = directory.flags
        self.hashType = directory.hashType
        self.hashSize = directory.hashSize
        self.pageSizeExponent = directory.pageSizeExponent
        self.pageCount = directory.codeSlotCount
        self.codeLimit = directory.effectiveCodeLimit
        self.identifier = MachOText.sanitized(directory.identifier, limit: 512)
        self.teamIdentifier = directory.teamIdentifier.map { MachOText.sanitized($0, limit: 64) }
        self.platform = directory.platform
        self.specialSlots = directory.specialSlots.map {
            CodeDirectorySpecialSlotSummary(number: -$0.slotNumber, isBound: $0.hasNonzeroBytes)
        }.sorted { $0.number < $1.number }
        self.executableSegmentBase = directory.executableSegment?.base
        self.executableSegmentLimit = directory.executableSegment?.limit
        self.executableSegmentFlags = directory.executableSegment?.flags
        self.runtimeVersion = directory.runtime.map { MachOPackedVersion(rawValue: $0) }
        self.hasScatter = directory.scatter != nil
        self.hasPreEncryptionHashes = directory.preEncryptHashesRange != nil
        self.hasLinkage = directory.linkage != nil
        self.byteCount = byteCount
        self.cdHash = cdHash
    }

    /// The page size in bytes, or `nil` for the unpaged single-range form.
    var pageSize: Int? {
        pageSizeExponent == 0 ? nil : 1 << Int(pageSizeExponent)
    }

    /// The slot's label, for example "Primary" or "Alternate 1".
    var slotLabel: String {
        isPrimary ? "Primary" : "Alternate \(Int(slotNumber) - 0x1000 + 1)"
    }

    /// The version as `2.5` style text with the raw value.
    var versionText: String {
        let major = (version >> 16) & 0xFF
        let minor = (version >> 8) & 0xFF
        return "\(major).\(minor) (\(MachOHexadecimal.text(UInt64(version))))"
    }

    var decodedFlags: MachODecodedFlags { CodeDirectoryFlagTable.decode(flags) }

    var decodedExecutableSegmentFlags: MachODecodedFlags? {
        executableSegmentFlags.map { ExecutableSegmentFlagTable.decode($0) }
    }

    var boundSpecialSlotCount: Int { specialSlots.filter(\.isBound).count }

    /// The CDHash as lowercase hexadecimal, when computed.
    var cdHashText: String? {
        cdHash.map { MachOHexadecimal.bytes($0) }
    }
}

/// The requirement set, summarised.
struct RequirementsSummary: Equatable {
    enum State: String, Equatable {
        case absent
        case parsed
        case unsupported
        case malformed
    }

    let state: State
    /// The names of the requirement kinds in the set, in set order.
    let requirementKinds: [String]

    init(state: State, requirementKinds: [String]) {
        self.state = state
        self.requirementKinds = requirementKinds
    }

    init(_ requirements: CodeSigningRequirements) {
        switch requirements.disposition {
        case .absent: self.state = .absent
        case .presentAndParsed, .generated, .verified: self.state = .parsed
        case .presentButUnsupported: self.state = .unsupported
        case .malformed: self.state = .malformed
        }
        self.requirementKinds = (requirements.set?.entries ?? []).map { Self.name(for: $0.kind) }
    }

    var count: Int { requirementKinds.count }

    static func name(for kind: RequirementKind) -> String {
        switch kind {
        case .host: return "Host"
        case .guest: return "Guest"
        case .designated: return "Designated"
        case .library: return "Library"
        case .plugin: return "Plug-in"
        case .other(let value): return "Kind \(value)"
        }
    }
}

/// The entitlements embedded in a signature. Only the keys are carried:
/// entitlement values never leave the inspection boundary, so no screen or
/// report can expose them.
enum EmbeddedEntitlementsSummary: Equatable {
    case absent
    case present(keys: [String])
    case malformed

    var keys: [String] {
        if case .present(let keys) = self { return keys }
        return []
    }
}

/// One embedded signature, summarised for inspection.
struct CodeSignatureSummary: Equatable {
    /// The byte count `LC_CODE_SIGNATURE` reserves.
    let signatureRegionByteCount: Int
    /// The SuperBlob's declared length.
    let superBlobByteCount: Int
    let blobs: [CodeSignatureBlobSummary]
    /// Every CodeDirectory, the primary first.
    let codeDirectories: [CodeDirectorySummary]
    let requirements: RequirementsSummary
    let entitlements: EmbeddedEntitlementsSummary
    let hasDEREntitlements: Bool
    /// The CMS blob's byte count including its 8-byte header, or `nil` when
    /// the signature has no CMS slot.
    let cmsBlobByteCount: Int?
    let form: CodeSignatureForm

    var primaryCodeDirectory: CodeDirectorySummary? {
        codeDirectories.first(where: \.isPrimary) ?? codeDirectories.first
    }

    /// The CMS payload's byte count, without the blob header.
    var cmsPayloadByteCount: Int? {
        cmsBlobByteCount.map { max(0, $0 - 8) }
    }

    /// Summarises the embedded signature of `slice`.
    ///
    /// - Parameters:
    ///   - slice: A slice parsed from `bytes`.
    ///   - bytes: The exact bytes the slice was parsed from, starting at
    ///     index zero.
    ///   - codeDirectoryHashes: CDHashes already computed, by SuperBlob slot.
    /// - Returns: `nil` when the slice carries no signature.
    static func make(slice: MachOSlice, bytes: Data, codeDirectoryHashes: [UInt32: Data] = [:]) -> CodeSignatureSummary? {
        guard let embedded = slice.embeddedSignature else { return nil }
        let entries = embedded.superBlob.entries
        let blobs = entries.map {
            CodeSignatureBlobSummary(slotNumber: $0.slotNumber, slot: $0.slot, magic: $0.magic, byteCount: $0.fileRange.count)
        }
        let directories = entries.compactMap { entry -> CodeDirectorySummary? in
            guard let directory = entry.codeDirectory else { return nil }
            return CodeDirectorySummary(
                slotNumber: entry.slotNumber,
                directory: directory,
                byteCount: entry.fileRange.count,
                cdHash: codeDirectoryHashes[entry.slotNumber]
            )
        }.sorted { $0.slotNumber < $1.slotNumber }

        let metadata = EmbeddedSigningMetadataInspector().inspect(slice: slice, artifact: bytes)
        let entitlements: EmbeddedEntitlementsSummary
        switch metadata.entitlements {
        case .absent: entitlements = .absent
        case .present(let declared): entitlements = .present(keys: declared.keys.sorted())
        case .malformed: entitlements = .malformed
        }
        let cmsBlobByteCount = entries.first(where: { $0.slot == .cms })?.fileRange.count
        let primaryFlags = directories.first?.flags
        return CodeSignatureSummary(
            signatureRegionByteCount: embedded.command.dataSize,
            superBlobByteCount: embedded.superBlob.length,
            blobs: blobs,
            codeDirectories: directories,
            requirements: RequirementsSummary(metadata.requirements),
            entitlements: entitlements,
            hasDEREntitlements: entries.contains { $0.slot == .derEntitlements },
            cmsBlobByteCount: cmsBlobByteCount,
            form: CodeSignatureForm.classify(
                primaryFlags: primaryFlags,
                cmsPayloadByteCount: cmsBlobByteCount.map { max(0, $0 - 8) }
            )
        )
    }
}
