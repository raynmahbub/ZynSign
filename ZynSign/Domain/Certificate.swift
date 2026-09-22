import Foundation

/// A certificate with its raw DER bytes and extracted metadata.
///
/// `Certificate` is the complete representation of a certificate when raw
/// bytes must be retained for later operations such as CMS construction.
/// It contains both the platform-independent metadata and the DER encoding
/// from which that metadata was derived.
///
/// Ownership and security boundary, **Accepted**:
/// - Raw DER bytes are public certificate data, not private-key material,
///   but they must still be handled as untrusted input. They must not be
///   logged in full, must not be persisted in ordinary application storage
///   such as `ApplicationRecord`, and must not be exposed through the UI
///   beyond fingerprint and metadata.
/// - The DER data is owned by the component that parsed it. For future
///   signing workflows, the Platform layer owns the `SecCertificate` or raw
///   bytes and provides them to the signing boundary only when needed. The
///   Domain layer holds the bytes transiently inside this type but never
///   persists them in the library catalog or other ordinary storage.
/// - Private-key material is never carried in this type. See
///   `SigningIdentity` and `SigningCapability` for the private-key boundary.
///
/// `Certificate` is a value type. Two certificates with the same DER bytes
/// have the same fingerprint and are equal.
struct Certificate: Equatable, Hashable {

    /// The extracted metadata.
    let metadata: CertificateMetadata

    /// The raw DER-encoded bytes.
    ///
    /// The bytes are untrusted input that was successfully parsed. They are
    /// retained only because later operations (e.g. CMS SignedData
    /// construction) require the original encoding. They must not be logged,
    /// must not be persisted in `ApplicationRecordStore`, and must not be
    /// exposed as a file.
    let derData: Data

    /// Creates a certificate from metadata and DER bytes.
    ///
    /// The caller must ensure `metadata` was derived from `derData`. The
    /// initializer does not re-parse or re-validate; it is a pairing
    /// operation with an explicit ownership boundary.
    init(metadata: CertificateMetadata, derData: Data) {
        self.metadata = metadata
        self.derData = derData
    }

    /// The SHA-256 fingerprint, convenience forwarding to metadata.
    var fingerprint: CertificateFingerprint { metadata.sha256Fingerprint }

    /// The subject, convenience forwarding to metadata.
    var subject: CertificateDistinguishedName { metadata.subject }

    /// The issuer, convenience forwarding to metadata.
    var issuer: CertificateDistinguishedName { metadata.issuer }
}

/// The raw DER data of a certificate with its fingerprint.
///
/// This type exists to make the ownership boundary explicit when raw bytes
/// must be retained. It holds only the DER encoding and its fingerprint, not
/// the full metadata, and is intended for use in the Platform layer where
/// the bytes are needed for CMS or other encoding operations.
///
/// Security boundary: raw DER bytes must not be logged, must not be persisted
/// in ordinary application storage, and must not be exposed through UI. They
/// are owned by the Platform layer and provided to the signing boundary only
/// when required.
struct CertificateData: Equatable, Hashable {

    /// The raw DER-encoded bytes.
    let derData: Data

    /// The SHA-256 fingerprint of `derData`.
    let fingerprint: CertificateFingerprint

    /// Creates certificate data from DER bytes and fingerprint.
    init(derData: Data, fingerprint: CertificateFingerprint) {
        self.derData = derData
        self.fingerprint = fingerprint
    }
}
