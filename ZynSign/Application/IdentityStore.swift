import Foundation

/// The boundary through which ZynSign discovers and accesses signing
/// identities.
///
/// The identity store is the seam where platform-specific key storage,
/// certificate services, and identity resolution live. Callers see only
/// domain types and structured failures, and never see a key reference,
/// keychain item, or platform certificate object.
///
/// The store answers four questions:
/// - what identities are available,
/// - what is the metadata of a given identity,
/// - how to access the signing capability for an identity;
/// - which public certificate accompanies that capability for CMS construction.
///
/// Security boundary, **Accepted**:
/// - Private key material is never exposed through this port. Callers
///   receive a `SigningCapability` that can produce signatures but not key
///   bytes.
/// - Private keys are not persisted in the application database
///   (`ApplicationRecordStore`). They reside in the platform's secure storage
///   (Keychain) with non-exportable attributes where applicable.
/// - The store must not automatically import arbitrary certificates or
///   private keys. Import is a separate capability with explicit user intent.
/// - `.p12` / PKCS#12 import is a separate capability and is not part of
///   this port's contract in this milestone.
///
/// The port is declared in Application because it composes platform
/// dependencies and workflow state. Its implementation lives in Platform.
protocol IdentityStore {

    /// Lists the signing identities currently available.
    ///
    /// An identity is available when its certificate can be inspected and its
    /// status can be reported. Availability of the private key is reported
    /// through `SigningIdentity.keyAvailability`, not through presence in
    /// this list alone.
    ///
    /// - Returns: The identities, in a deterministic order suitable for
    ///   display.
    /// - Throws: A typed `ZynSignError` when the store cannot be accessed.
    func listIdentities() throws -> [SigningIdentity]

    /// Retrieves the identity with `id`, or `nil` when no such identity
    /// exists.
    ///
    /// - Parameter id: The identifier of the identity to retrieve.
    /// - Returns: The identity, or `nil`.
    /// - Throws: A typed `ZynSignError` when the store cannot be accessed.
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity?

    /// Retrieves the metadata for `id`, or `nil` when no such identity
    /// exists. Convenience that returns only metadata without full identity.
    ///
    /// - Parameter id: The identifier.
    /// - Returns: The metadata, or `nil`.
    /// - Throws: A typed `ZynSignError` when the store cannot be accessed.
    func metadata(for id: SigningIdentityIdentifier) throws -> SigningIdentityMetadata?

    /// Accesses the signing capability for `id`.
    ///
    /// The capability can produce signatures without exposing private-key
    /// bytes. It may be unavailable when the key is not accessible (e.g.
    /// device locked, key not present).
    ///
    /// - Parameter id: The identifier of the identity whose capability is
    ///   requested.
    /// - Returns: The signing capability.
    /// - Throws: A typed `ZynSignError` when the identity does not exist,
    ///   the key is unavailable, or the store cannot be accessed.
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability

    /// Public certificate bytes for CMS construction only; never a key locator.
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate
}

extension IdentityStore {
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate {
        throw ZynSignError.identity(.certificateUnavailable)
    }

    func metadata(for id: SigningIdentityIdentifier) throws -> SigningIdentityMetadata? {
        guard let identity = try identity(withID: id) else { return nil }
        return SigningIdentityMetadata(identity: identity)
    }
}
