import Foundation

/// The embedded entitlements blob: the container whose digest occupies
/// CodeDirectory special slot 5.
///
/// Format evidence:
///
/// - **Verified (Apple open-source headers).** `cs_blobs.h` defines the
///   generic blob frame — a big-endian 32-bit magic followed by a big-endian
///   32-bit total length that includes the eight header bytes — and names
///   `CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171` with
///   `CSSLOT_ENTITLEMENTS = 5`.
/// - **Verified (Apple open-source headers) for reading.** The blob's data is
///   "a serialized property list"; XML and binary encodings are both legal
///   plist forms, so the parser accepts both.
/// - **ZynSign policy for writing.** ZynSign embeds the canonical XML form
///   produced by `CanonicalPropertyListXMLSerializer`, with no trailing NUL
///   byte. Whether Apple's own signer emits byte-identical XML — including
///   its exact indentation and any trailing newline — is **not established**
///   and is recorded as requiring experiment. ZynSign's digest boundary is
///   its own canonical bytes, which are a deterministic function of the
///   entitlement value alone.
struct EntitlementsBlob: Equatable, Hashable {

    static let magic: UInt32 = 0xFADE7171
    static let headerLength = 8
    static let maximumPayloadByteCount = EntitlementsPlistParser.maximumPayloadByteCount

    /// The exact payload bytes: a complete serialized property list.
    let payload: Data

    /// The exact header-inclusive blob bytes.
    let bytes: Data

    var serializedLength: Int { bytes.count }

    /// Frames a payload that was serialized by ZynSign's canonical
    /// serializer. The payload is copied into the frame; the caller's data is
    /// never mutated.
    init(canonicalPayload payload: Data) throws {
        guard !payload.isEmpty else { throw EntitlementsError.emptyPayload }
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw EntitlementsError.payloadTooLarge
        }
        let totalLength = Self.headerLength + payload.count
        guard let encodedLength = UInt32(exactly: totalLength) else {
            throw EntitlementsError.payloadTooLarge
        }
        var writer = CheckedBinaryWriter(maximumLength: totalLength)
        try writer.appendUInt32BigEndian(Self.magic)
        try writer.appendUInt32BigEndian(encodedLength)
        try writer.appendData(payload)
        self.payload = payload
        self.bytes = writer.data
    }

    /// Parses an existing entitlements blob, validating only the generic
    /// frame. The payload is extracted exactly; interpreting it is the plist
    /// parser's job, and this method deliberately does not perform it.
    init(existingBlob bytes: Data) throws {
        guard bytes.count >= Self.headerLength else {
            throw EntitlementsError.invalidBlobFraming
        }
        let magic = try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let reader = BoundedBinaryReader(bytes: raw)
            return try reader.uint32(at: 0, order: .bigEndian, boundary: .signatureBlob)
        }
        guard magic == Self.magic else {
            throw EntitlementsError.invalidBlobFraming
        }
        let declaredLength = try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            let reader = BoundedBinaryReader(bytes: raw)
            return try reader.uint32AsInt(at: 4, order: .bigEndian, boundary: .signatureBlob)
        }
        guard declaredLength == bytes.count else {
            throw EntitlementsError.invalidBlobFraming
        }
        self.payload = Data(bytes.dropFirst(Self.headerLength))
        self.bytes = bytes
    }

    /// Decodes the payload into the typed entitlement model. Read-only: no
    /// bytes are rewritten and no signature is modified.
    func parseEntitlements(
        limits: ProvisioningProfileParsingLimits = .default
    ) throws -> CodeSigningEntitlements {
        try EntitlementsPlistParser.parse(payload, limits: limits)
    }
}

/// Deterministic serialization of the entitlement payload.
///
/// The serialization boundary for entitlements is one function: this type's
/// `serialize`. Everything that needs entitlement bytes — the blob frame, the
/// special-slot digest, diagnostics that re-derive bytes — goes through it,
/// so there is exactly one canonicalization rule and one place it is tested.
///
/// The rule is the canonical property-list form documented on
/// `CanonicalPropertyListXMLSerializer`: fixed header lines, keys in
/// ascending UTF-8 byte order, tab indentation, one element per line, a
/// trailing newline, and no value transformation of any kind. Two entitlement
/// sets that differ in any serialized byte are different digests; two sets
/// that differ only in dictionary insertion order are identical bytes.
struct EntitlementsCanonicalSerializer {

    let limits: CanonicalPropertyListLimits

    init(limits: CanonicalPropertyListLimits = .default) {
        self.limits = limits
    }

    /// Serializes one entitlement set to its exact canonical bytes.
    func serialize(_ entitlements: CodeSigningEntitlements) throws -> Data {
        let serializer = CanonicalPropertyListXMLSerializer(limits: limits)
        do {
            return try serializer.serialize(root: .dictionary(entitlements.values))
        } catch let error as CanonicalPropertyListError {
            throw EntitlementsError.canonicalizationError(error)
        }
    }

    /// Serializes and frames in one step, producing the exact bytes whose
    /// digest occupies CodeDirectory special slot 5.
    func blob(_ entitlements: CodeSigningEntitlements) throws -> EntitlementsBlob {
        let payload = try serialize(entitlements)
        return try EntitlementsBlob(canonicalPayload: payload)
    }
}

extension EntitlementsError {
    /// Maps a canonicalization failure into this boundary's vocabulary.
    /// Kept internal to the file's layer; declared as an extension so the
    /// enum above stays focused on stages.
    static func canonicalizationError(_ error: CanonicalPropertyListError) -> EntitlementsError {
        switch error {
        case .rootMustBeDictionary: return .malformedPlist
        case .unsupportedValueType: return .unsupportedValueType
        case .nonFiniteNumber: return .nonFiniteNumber
        case .invalidKey: return .invalidKey
        case .resourceLimitExceeded: return .resourceLimitExceeded
        case .integerOverflow: return .resourceLimitExceeded
        case .outputTooLarge: return .payloadTooLarge
        }
    }
}
