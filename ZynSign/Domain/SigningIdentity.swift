import Foundation

/// The stable identifier of a signing identity within ZynSign.
///
/// Identifiers are opaque: they carry no information about certificate
/// contents, are never derived from certificate metadata, and must never be
/// presented as certificate information. A fresh identifier is minted when an
/// identity is discovered or imported; persistence layers reuse the stored
/// identifier when rehydrating a known identity instead of minting another.
struct SigningIdentityIdentifier: Equatable, Hashable, CustomStringConvertible, Sendable {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier, for example when rehydrating a
    /// persisted identity reference.
    init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Rehydrates an identifier from its string form, or returns `nil` when
    /// the string is not a valid identifier representation.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    /// The canonical string form, suitable for persistence keys and
    /// diagnostics. Contains no certificate information.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}

/// The status of a signing identity's private-key availability.
///
/// A certificate being present and valid is not evidence that its private
/// key is available or usable. Certificate inspection, identity resolution,
/// and signing authorization are separate operations with separate outcomes.
enum SigningKeyAvailability: String, CaseIterable, Equatable, Hashable {

    /// A key handle was resolved. This alone does not prove association or signing success.
    case available

    /// The private key is not available. The certificate may still be
    /// present and valid, but signing cannot be performed.
    case unavailable

    /// The availability could not be determined.
    case unknown

    /// Whether the key is available.
    var isAvailable: Bool { self == .available }
}

/// The operational pairing of a certificate with a usable matching private
/// key, as presented for selection and status.
///
/// A signing identity involves certificate information plus access to the
/// corresponding private signing capability:
///
/// Certificate
///      +
/// Private Signing Capability
///      =
/// Signing Identity
///
/// The domain model makes this distinction explicit. A certificate can exist
/// independently; a signing identity exists only when a matching private
/// capability is available or its absence is explicitly represented.
///
/// `SigningIdentity` contains no private-key bytes. It contains only
/// certificate metadata, an identifier, and status. The actual signing
/// capability is accessed through `IdentityStore`, which returns a
/// `SigningCapability` without exposing key material.
///
/// Private-key material must not be represented as plaintext key in ordinary
/// application models and must not be persisted in the application database.
struct SigningIdentity: Equatable, Hashable {

    /// The identity's own stable identifier.
    let id: SigningIdentityIdentifier

    /// The certificate metadata associated with this identity.
    let certificate: CertificateMetadata

    /// The availability of the private key.
    let keyAvailability: SigningKeyAvailability

    /// Public-key relationship; not inferred from labels or certificate metadata.
    let association: CertificateKeyAssociation

    /// Readiness for a primitive operation, not certificate trust or validity.
    let capabilityState: SigningCapabilityState

    /// Where the capability is resolved, without exposing a storage locator.
    let storage: SigningIdentityStorage

    /// Whether the underlying key is stored in a non-exportable manner,
    /// when known. `nil` when the storage characteristic is unknown.
    ///
    /// Non-exportable storage means raw key bytes cannot be read back
    /// through platform APIs, while remaining usable for signing. Report this
    /// characteristic only when established by the storage adapter.
    /// Import and device behavior require separate validation.
    let isKeyNonExportable: Bool?

    /// Creates a signing identity.
    init(
        id: SigningIdentityIdentifier = SigningIdentityIdentifier(),
        certificate: CertificateMetadata,
        keyAvailability: SigningKeyAvailability,
        isKeyNonExportable: Bool? = nil,
        association: CertificateKeyAssociation = .unknown,
        capabilityState: SigningCapabilityState = .unknown,
        storage: SigningIdentityStorage = .unknown
    ) {
        self.id = id
        self.certificate = certificate
        self.keyAvailability = keyAvailability
        self.isKeyNonExportable = isKeyNonExportable
        self.association = association
        self.capabilityState = capabilityState
        self.storage = storage
    }

    /// Whether the last observation established a matching primitive capability.
    /// Not proof of a successful signature, certificate validity, or trust.
    var isUsableForSigning: Bool {
        keyAvailability.isAvailable && association == .matched && capabilityState == .ready
    }

    /// The display name for the identity: the certificate's subject common
    /// name or raw representation.
    var displayName: String { certificate.subject.displayName }

    /// The SHA-256 fingerprint of the certificate, for stable identification.
    var fingerprint: CertificateFingerprint { certificate.sha256Fingerprint }
}

/// The metadata of a signing identity as presented for selection.
///
/// This is a lighter view of `SigningIdentity` that contains only what the
/// presentation layer needs: identifier, certificate metadata, and status.
/// It contains no capability reference and no private-key material.
struct SigningIdentityMetadata: Equatable, Hashable {

    /// The identity's identifier.
    let id: SigningIdentityIdentifier

    /// The certificate metadata.
    let certificate: CertificateMetadata

    /// The key availability.
    let keyAvailability: SigningKeyAvailability

    let association: CertificateKeyAssociation
    let capabilityState: SigningCapabilityState

    /// Creates identity metadata.
    init(
        id: SigningIdentityIdentifier,
        certificate: CertificateMetadata,
        keyAvailability: SigningKeyAvailability,
        association: CertificateKeyAssociation = .unknown,
        capabilityState: SigningCapabilityState = .unknown
    ) {
        self.id = id
        self.certificate = certificate
        self.keyAvailability = keyAvailability
        self.association = association
        self.capabilityState = capabilityState
    }

    /// Creates metadata from a full identity.
    init(identity: SigningIdentity) {
        self.id = identity.id
        self.certificate = identity.certificate
        self.keyAvailability = identity.keyAvailability
        self.association = identity.association
        self.capabilityState = identity.capabilityState
    }
}

/// Public-key equality, separate from the existence of a key or a certificate.
enum CertificateKeyAssociation: String, Hashable {
    case unknown, matched, mismatched
}

enum SigningCapabilityState: String, Hashable {
    case unknown, ready, unavailable, authorizationRequired, unsupported
}

enum SigningIdentityStorage: String, Hashable {
    case unknown, keychain
}
