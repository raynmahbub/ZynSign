import Foundation

/// CodeDirectory version milestones deliberately supported for construction.
///
/// `0x20001` is the earliest format version understood by the existing
/// parser. `0x20200` is the smallest version that carries a team identifier.
/// The constructor does not emit scatter, extended-limit, executable-segment,
/// runtime, pre-encryption, or linkage fields; later parser-only versions are
/// represented as unsupported rather than guessed at.
enum CodeDirectoryVersion: Equatable, Hashable {
    case v20001
    case v20200
    case v20400
    case unsupported(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0x20001: self = .v20001
        case 0x20200: self = .v20200
        case 0x20400: self = .v20400
        default: self = .unsupported(rawValue)
        }
    }

    var rawValue: UInt32 {
        switch self {
        case .v20001: return 0x20001
        case .v20200: return 0x20200
        case .v20400: return 0x20400
        case .unsupported(let value): return value
        }
    }

    var headerLength: Int {
        switch self {
        case .v20001: return 44
        case .v20200: return 52
        case .v20400: return 52
        case .unsupported: return 0
        }
    }

    var supportsTeamIdentifier: Bool {
        switch self {
        case .v20001: return false
        case .v20200, .v20400: return true
        case .unsupported: return false
        }
    }

    var supportsDEREntitlements: Bool {
        self == .v20400
    }
}

/// Flags are preserved as a raw bit set. Unknown bits are retained rather
/// than silently discarded; interpreting platform policy flags is outside
/// CodeDirectory construction.
struct CodeDirectoryFlags: OptionSet, Equatable, Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// The on-disk CodeDirectory hash type, kept distinct from the digest
/// algorithm that produces the hash bytes. The truncated SHA-256 form uses
/// SHA-256 as its digest algorithm but stores only its first 20 bytes.
enum CodeDirectoryHashType: Equatable, Hashable {
    case sha1
    case sha256
    case sha256Truncated
    case sha384
    case unsupported(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .sha1
        case 2: self = .sha256
        case 3: self = .sha256Truncated
        case 4: self = .sha384
        default: self = .unsupported(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .sha1: return 1
        case .sha256: return 2
        case .sha256Truncated: return 3
        case .sha384: return 4
        case .unsupported(let value): return value
        }
    }

    var digestAlgorithm: DigestAlgorithm? {
        switch self {
        case .sha1: return .sha1
        case .sha256, .sha256Truncated: return .sha256
        case .sha384: return .sha384
        case .unsupported: return nil
        }
    }

    var expectedHashSize: Int? {
        switch self {
        case .sha1, .sha256Truncated: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .unsupported: return nil
        }
    }
}

/// The complete hashing configuration written to a CodeDirectory.
struct CodeDirectoryHashConfiguration: Equatable, Hashable {
    let hashType: CodeDirectoryHashType
    let digestAlgorithm: DigestAlgorithm
    /// The full digest size produced before any CodeDirectory truncation.
    var digestSize: Int { digestAlgorithm.digestLength }
    /// The number of bytes stored in each CodeDirectory slot.
    let hashSize: Int

    /// Creates a configuration for a published CodeDirectory hash type.
    /// `hashSize` is accepted explicitly so an invalid combination is a
    /// structured error instead of being silently normalized.
    init(hashType: CodeDirectoryHashType, hashSize: Int? = nil) throws {
        guard let digestAlgorithm = hashType.digestAlgorithm,
              let expectedHashSize = hashType.expectedHashSize else {
            throw CodeDirectoryError.invalidHashType(hashType.rawValue)
        }
        let actualHashSize = hashSize ?? expectedHashSize
        guard actualHashSize == expectedHashSize else {
            throw CodeDirectoryError.invalidHashSize(
                expected: expectedHashSize,
                actual: actualHashSize
            )
        }
        guard actualHashSize > 0, actualHashSize <= 48 else {
            throw CodeDirectoryError.invalidHashConfiguration
        }
        self.hashType = hashType
        self.digestAlgorithm = digestAlgorithm
        self.hashSize = actualHashSize
    }

    /// Creates the canonical CodeDirectory configuration for a digest
    /// algorithm. SHA-512 is available to the generic digest foundation but
    /// has no supported CodeDirectory hash type in this implementation.
    init(digestAlgorithm: DigestAlgorithm) throws {
        switch digestAlgorithm {
        case .sha1:
            try self.init(hashType: .sha1)
        case .sha256:
            try self.init(hashType: .sha256)
        case .sha384:
            try self.init(hashType: .sha384)
        case .sha512:
            throw CodeDirectoryError.unsupportedDigestAlgorithm(.sha512)
        }
    }
}

/// The CodeDirectory page-size field is a log2 exponent. Exponent zero is
/// the format's unpaged, single-range form; a paged form therefore starts at
/// two bytes and is always a power of two.
enum CodeDirectoryPageSize: Equatable, Hashable {
    case unpaged
    case exponent(UInt8)

    init(exponent: UInt8) throws {
        guard exponent <= 30 else {
            throw CodeDirectoryError.invalidPageSize(exponent)
        }
        self = exponent == 0 ? .unpaged : .exponent(exponent)
    }

    init(bytes: Int) throws {
        guard bytes > 0 else {
            throw CodeDirectoryError.nonPowerOfTwoPageSize(bytes)
        }
        guard bytes >= 2, (bytes & (bytes - 1)) == 0 else {
            throw CodeDirectoryError.nonPowerOfTwoPageSize(bytes)
        }
        let exponent = bytes.trailingZeroBitCount
        guard exponent <= 30 else {
            throw CodeDirectoryError.invalidPageSize(UInt8(exponent))
        }
        self = .exponent(UInt8(exponent))
    }

    var exponent: UInt8 {
        switch self {
        case .unpaged: return 0
        case .exponent(let value): return value
        }
    }

    /// The byte count of each page, or `nil` for the unpaged form.
    var byteCount: Int? {
        switch self {
        case .unpaged: return nil
        case .exponent(let value): return 1 << Int(value)
        }
    }
}

/// A CodeDirectory identifier. This is a CodeDirectory string, not a
/// `BundleIdentifier`: construction preserves the format's UTF-8 string
/// boundary without claiming the identifier is a valid bundle declaration.
struct CodeDirectoryIdentifier: Equatable, Hashable, CustomStringConvertible {
    static let maximumUTF8Length = 4_096
    let rawValue: String

    init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              !rawValue.unicodeScalars.contains(where: { $0.value == 0 }),
              rawValue.utf8.count <= Self.maximumUTF8Length else {
            throw CodeDirectoryError.invalidIdentifier
        }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// A team identifier string, present only in versions that define its field.
struct CodeDirectoryTeamIdentifier: Equatable, Hashable, CustomStringConvertible {
    static let maximumUTF8Length = 4_096
    let rawValue: String

    init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              !rawValue.unicodeScalars.contains(where: { $0.value == 0 }),
              rawValue.utf8.count <= Self.maximumUTF8Length else {
            throw CodeDirectoryError.invalidTeamIdentifier
        }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

enum CodeDirectorySpecialSlotKind: Equatable, Hashable {
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

    init(slotIndex: Int) {
        switch slotIndex {
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
        default: self = .other(slotIndex)
        }
    }

    var slotIndex: Int {
        switch self {
        case .infoPlist: return 1
        case .requirements: return 2
        case .codeResources: return 3
        case .application: return 4
        case .entitlements: return 5
        case .representationSpecific: return 6
        case .derEntitlements: return 7
        case .launchConstraintSelf: return 8
        case .launchConstraintParent: return 9
        case .launchConstraintResponsible: return 10
        case .libraryConstraint: return 11
        case .other(let value): return value
        }
    }
}

/// One reserved negative special slot. Slots are modeled by their positive
/// ordinal because the serialized hash array stores them in reverse order at
/// indices `-nSpecialSlots ... -1`. A nil hash means the reserved slot is
/// absent and is serialized as zero bytes; it does not invent the content of
/// any future special blob.
struct CodeDirectorySpecialSlot: Equatable, Hashable {
    let index: Int
    let kind: CodeDirectorySpecialSlotKind
    let hash: Data?

    init(index: Int, hash: Data? = nil) {
        self.index = index
        self.kind = CodeDirectorySpecialSlotKind(slotIndex: index)
        self.hash = hash
    }

    init(kind: CodeDirectorySpecialSlotKind, hash: Data? = nil) {
        self.init(index: kind.slotIndex, hash: hash)
    }

    var negativeIndex: Int? {
        guard index != Int.min else { return nil }
        return -index
    }
}

/// One ordinary code-page hash. Indices must be zero-based and contiguous in
/// a constructed CodeDirectory.
struct CodeDirectoryCodeSlot: Equatable, Hashable {
    let index: Int
    let hash: Data

    init(index: Int, hash: Data) {
        self.index = index
        self.hash = hash
    }
}

/// The typed, constructible CodeDirectory domain value. It contains no CMS,
/// private-key, Mach-O, or filesystem state.
struct CodeDirectory: Equatable, Hashable {
    static let magic: UInt32 = 0xFADE0C02
    static let maximumSpecialSlots = 64
    static let maximumCodeSlots = 65_536
    static let maximumSerializedLength = 256 * 1_024 * 1_024

    let version: CodeDirectoryVersion
    let flags: CodeDirectoryFlags
    let identifier: CodeDirectoryIdentifier
    let teamIdentifier: CodeDirectoryTeamIdentifier?
    let platform: UInt8
    let hashConfiguration: CodeDirectoryHashConfiguration
    let pageSize: CodeDirectoryPageSize
    let codeLimit: UInt64
    let specialSlots: [CodeDirectorySpecialSlot]
    let codeSlots: [CodeDirectoryCodeSlot]

    init(
        version: CodeDirectoryVersion,
        flags: CodeDirectoryFlags = [],
        identifier: CodeDirectoryIdentifier,
        teamIdentifier: CodeDirectoryTeamIdentifier? = nil,
        platform: UInt8 = 0,
        hashConfiguration: CodeDirectoryHashConfiguration,
        pageSize: CodeDirectoryPageSize,
        codeLimit: UInt64,
        specialSlots: [CodeDirectorySpecialSlot] = [],
        codeSlots: [CodeDirectoryCodeSlot]
    ) throws {
        self.version = version
        self.flags = flags
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.platform = platform
        self.hashConfiguration = hashConfiguration
        self.pageSize = pageSize
        self.codeLimit = codeLimit
        self.specialSlots = specialSlots
        self.codeSlots = codeSlots
        try validate()
    }

    /// Re-checks all model invariants. Construction and serialization both
    /// call this method so a value cannot reach binary output unchecked.
    func validate() throws {
        guard case .unsupported(let rawVersion) = version else {
            // A supported version continues below.
            try validateSupportedVersion()
            return
        }
        throw CodeDirectoryError.unsupportedVersion(rawVersion)
    }

    private func validateSupportedVersion() throws {
        guard codeLimit <= UInt64(UInt32.max) else {
            throw CodeDirectoryError.invalidCodeLimit
        }
        if teamIdentifier != nil, !version.supportsTeamIdentifier {
            throw CodeDirectoryError.unsupportedFeature(.teamIdentifier)
        }
        guard specialSlots.count <= Self.maximumSpecialSlots,
              codeSlots.count <= Self.maximumCodeSlots else {
            throw CodeDirectoryError.resourceLimitExceeded
        }
        for (position, slot) in specialSlots.enumerated() {
            guard slot.index == position + 1, slot.index > 0 else {
                throw CodeDirectoryError.invalidSlotIndex
            }
            if slot.kind == .derEntitlements, !version.supportsDEREntitlements {
                throw CodeDirectoryError.unsupportedFeature(.derEntitlements)
            }
            if let hash = slot.hash, hash.count != hashConfiguration.hashSize {
                throw CodeDirectoryError.invalidHashLength
            }
        }
        for (position, slot) in codeSlots.enumerated() {
            guard slot.index == position else {
                throw CodeDirectoryError.invalidSlotIndex
            }
            guard slot.hash.count == hashConfiguration.hashSize else {
                throw CodeDirectoryError.invalidHashLength
            }
        }
        let expectedCount = try Self.expectedCodeSlotCount(
            codeLimit: codeLimit,
            pageSize: pageSize
        )
        guard expectedCount == codeSlots.count else {
            throw CodeDirectoryError.invalidPageCount
        }
    }

    static func expectedCodeSlotCount(
        codeLimit: UInt64,
        pageSize: CodeDirectoryPageSize
    ) throws -> Int {
        let count: UInt64
        switch pageSize {
        case .unpaged:
            count = codeLimit == 0 ? 0 : 1
        case .exponent(let exponent):
            guard exponent > 0, exponent <= 30 else {
                throw CodeDirectoryError.invalidPageSize(exponent)
            }
            guard codeLimit > 0 else {
                throw CodeDirectoryError.invalidPageCount
            }
            let pageBytes = UInt64(1) << UInt64(exponent)
            let completePages = codeLimit / pageBytes
            let hasPartialPage = codeLimit % pageBytes != 0
            count = completePages + (hasPartialPage ? 1 : 0)
        }
        guard let result = Int(exactly: count), result <= Self.maximumCodeSlots else {
            throw CodeDirectoryError.resourceLimitExceeded
        }
        return result
    }
}

/// Input to `CodeDirectoryConstructor`. Code limits and page sizes are
/// explicit so the caller cannot accidentally hash the whole file by default.
struct CodeDirectoryConstructionRequest {
    let version: CodeDirectoryVersion
    let flags: CodeDirectoryFlags
    let identifier: CodeDirectoryIdentifier
    let teamIdentifier: CodeDirectoryTeamIdentifier?
    let platform: UInt8
    let hashConfiguration: CodeDirectoryHashConfiguration
    let pageSize: CodeDirectoryPageSize
    let codeLimit: UInt64
    let specialSlots: [CodeDirectorySpecialSlot]

    init(
        version: CodeDirectoryVersion,
        flags: CodeDirectoryFlags = [],
        identifier: CodeDirectoryIdentifier,
        teamIdentifier: CodeDirectoryTeamIdentifier? = nil,
        platform: UInt8 = 0,
        hashConfiguration: CodeDirectoryHashConfiguration,
        pageSize: CodeDirectoryPageSize,
        codeLimit: UInt64,
        specialSlots: [CodeDirectorySpecialSlot] = []
    ) {
        self.version = version
        self.flags = flags
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.platform = platform
        self.hashConfiguration = hashConfiguration
        self.pageSize = pageSize
        self.codeLimit = codeLimit
        self.specialSlots = specialSlots
    }

    func validate() throws {
        guard case .unsupported(let rawVersion) = version else {
            guard codeLimit <= UInt64(UInt32.max) else {
                throw CodeDirectoryError.invalidCodeLimit
            }
            if teamIdentifier != nil, !version.supportsTeamIdentifier {
                throw CodeDirectoryError.unsupportedFeature(.teamIdentifier)
            }
            guard specialSlots.count <= CodeDirectory.maximumSpecialSlots else {
                throw CodeDirectoryError.resourceLimitExceeded
            }
            for (position, slot) in specialSlots.enumerated() {
                guard slot.index == position + 1, slot.index > 0 else {
                    throw CodeDirectoryError.invalidSlotIndex
                }
                if slot.kind == .derEntitlements, !version.supportsDEREntitlements {
                    throw CodeDirectoryError.unsupportedFeature(.derEntitlements)
                }
                if let hash = slot.hash, hash.count != hashConfiguration.hashSize {
                    throw CodeDirectoryError.invalidHashLength
                }
            }
            _ = try CodeDirectory.expectedCodeSlotCount(codeLimit: codeLimit, pageSize: pageSize)
            return
        }
        throw CodeDirectoryError.unsupportedVersion(rawVersion)
    }
}

/// Constructs a CodeDirectory from caller-supplied code bytes and a digest
/// port. It hashes only the requested code region, then validates the complete
/// model before returning it.
struct CodeDirectoryConstructor {
    private let pageHasher: CodePageHasher

    init(messageDigest: any MessageDigest) {
        self.pageHasher = CodePageHasher(messageDigest: messageDigest)
    }

    func construct(
        _ request: CodeDirectoryConstructionRequest,
        code: Data
    ) throws -> CodeDirectory {
        try request.validate()
        let codeSlots = try pageHasher.hashCodePages(
            code,
            codeLimit: request.codeLimit,
            pageSize: request.pageSize,
            hashConfiguration: request.hashConfiguration
        )
        return try CodeDirectory(
            version: request.version,
            flags: request.flags,
            identifier: request.identifier,
            teamIdentifier: request.teamIdentifier,
            platform: request.platform,
            hashConfiguration: request.hashConfiguration,
            pageSize: request.pageSize,
            codeLimit: request.codeLimit,
            specialSlots: request.specialSlots,
            codeSlots: codeSlots
        )
    }
}
