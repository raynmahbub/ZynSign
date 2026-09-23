import Foundation

/// The application-layer boundary that produces a cryptographic signature
/// for a registered signing identity.
///
/// The use case orchestrates and nothing else:
///
///     SigningRequest
///             ↓
///     CryptographicSigningUseCase
///             ↓  1. validate the request
///             ↓  2. resolve the signing capability through IdentityStore
///             ↓  3. invoke the cryptographic engine
///     CryptographicSigningEngine → SigningResult
///
/// It holds no key, performs no keychain access itself, and evaluates
/// nothing beyond the operation: it does not decide that a signature is
/// trusted, that an artifact is signed, or that anything is installable.
///
/// The identity store is the ZS-016 boundary: the private key remains
/// inside its platform mechanism, and only signature bytes cross it. This
/// use case is not installed in the application environment: the identity
/// store itself is not composed into the app until its device validation
/// completes, and no interface consumes a signature result yet.
struct CryptographicSigningUseCase {

    private let identityStore: any IdentityStore
    private let engine: any CryptographicSigningEngine

    init(
        identityStore: any IdentityStore,
        engine: any CryptographicSigningEngine = CapabilitySigningEngine()
    ) {
        self.identityStore = identityStore
        self.engine = engine
    }

    /// Signs the request's data through the identity's signing capability.
    ///
    /// - Parameter request: The description of the operation. It carries no
    ///   key material: the identity reference, the operation, the data, and
    ///   optional context.
    /// - Returns: The structured signing result. Success means the requested
    ///   cryptographic operation completed — nothing more.
    /// - Throws: A typed `ZynSignError`. An incoherent request carries a
    ///   crypto reason; an identity that cannot be resolved, or a key that
    ///   is unavailable, carries the identity boundary's own reasons; a
    ///   protected-key failure carries the reason the capability reported.
    func sign(_ request: SigningRequest) throws -> SigningResult {
        try request.validate()

        let capability = try identityStore.signingCapability(for: request.identityID)

        let result = try engine.sign(request, capability: capability)

        // The signature already exists by the time the reference is
        // attached. The engine cannot know the fingerprint — the capability
        // exposes no certificate — so the application layer, which resolves
        // the identity, supplies it. An identity the store can no longer
        // describe does not fail a completed operation: the reference is
        // simply absent.
        let fingerprint = certificateFingerprint(for: request.identityID)

        return SigningResult(
            signature: result.signature,
            algorithm: result.algorithm,
            digestAlgorithm: result.digestAlgorithm,
            identityID: result.identityID,
            publicKeyAlgorithm: result.publicKeyAlgorithm,
            certificateFingerprint: fingerprint,
            signedDigest: result.signedDigest,
            context: result.context
        )
    }

    /// Resolves the identity's certificate fingerprint for the result's
    /// identity reference.
    ///
    /// The signature has already been produced by the time this runs, so an
    /// identity the store can no longer describe — or a store that cannot be
    /// read — does not fail the operation: the reference is simply absent.
    private func certificateFingerprint(for id: SigningIdentityIdentifier) -> CertificateFingerprint? {
        do {
            guard let metadata = try identityStore.metadata(for: id) else { return nil }
            return metadata.certificate.sha256Fingerprint
        } catch {
            return nil
        }
    }
}
