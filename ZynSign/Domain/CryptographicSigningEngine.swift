import Foundation

/// The boundary where a generic cryptographic signature is produced.
///
/// The engine takes a `SigningRequest` and a `SigningCapability` and asks
/// the capability for the signature. It is the single place where a signing
/// request becomes a `SigningResult`, and it keeps the generic-cryptography
/// side of the signing stage's boundary:
///
///     Certificate / Identity
///             ↓
///     Signing Capability            (ZS-016)
///             ↓
///     Cryptographic Signing Engine  (this boundary)
///             ↓
///     Signature Result
///
/// The engine knows nothing about Apple code signing. It cannot locate,
/// read, or modify a Mach-O binary, construct a CodeDirectory or a
/// SuperBlob, assemble a code-signature slot, sign a bundle, generate
/// `CodeResources`, or package an IPA. Those are later stages'
/// responsibilities, and they will use this boundary as a primitive rather
/// than reimplement it. A signature it produces is a cryptographic fact
/// about bytes and one protected key — not a statement that any artifact is
/// correctly code signed.
///
/// The private key never crosses this boundary. The engine holds no key,
/// no key reference, and no key bytes: it asks the capability for a
/// signature, and only signature bytes come back.
protocol CryptographicSigningEngine {

    /// Signs `request` through `capability`.
    ///
    /// - Parameters:
    ///   - request: The validated description of the operation.
    ///   - capability: The signing capability that performs the work,
    ///     resolved by the caller through the identity boundary.
    /// - Returns: The structured signing result.
    /// - Throws: A typed `ZynSignError`. The engine's own decisions carry
    ///   crypto reasons (invalid input, incompatible key, unsupported
    ///   operation, unavailable capability, malformed output); a failure
    ///   the capability itself reports keeps the identity boundary's own
    ///   reason, because key-state facts belong to that boundary.
    func sign(_ request: SigningRequest, capability: any SigningCapability) throws -> SigningResult
}

/// The engine implementation that signs through a `SigningCapability`.
///
/// Pure: it performs no I/O, holds no key, retains nothing after the
/// operation returns, and substitutes nothing — an unsupported combination
/// is a structured failure, never a different algorithm.
struct CapabilitySigningEngine: CryptographicSigningEngine {

    init() {}

    func sign(_ request: SigningRequest, capability: any SigningCapability) throws -> SigningResult {
        try request.validate()

        // The requested key family must be the family the capability holds.
        // An RSA operation against an EC-only capability is incompatible,
        // full stop: it is reported, never performed under a different key.
        guard capability.publicKeyAlgorithm == request.algorithm.publicKeyAlgorithm else {
            throw ZynSignError.crypto(.incompatibleKey)
        }

        // The capability's snapshot says it is not usable. The capability
        // rechecks on the operation itself; this is the engine's own
        // decision not to attempt one.
        guard capability.isAvailable else {
            throw ZynSignError.crypto(.capabilityUnavailable)
        }

        // The operation must be one the capability supports. No substitution.
        guard capability.supportedAlgorithms.contains(request.algorithm) else {
            throw ZynSignError.crypto(.unsupportedAlgorithm)
        }

        var data: Data
        var signedDigest: Digest?
        switch request.input {
        case .message(let value):
            (data, signedDigest) = (value, nil)
        case .digest(let digest):
            (data, signedDigest) = (digest.bytes, digest)
        }

        let signature: Data
        do {
            signature = try capability.sign(data: data, algorithm: request.algorithm)
        } catch let error as ZynSignError
            where error.identityFailure != nil || error.cryptoFailure != nil {
            // The capability's own structured failure keeps its own
            // vocabulary: key-state facts belong to the identity boundary.
            throw error
        } catch {
            // A foreign, unstructured failure is reduced to a reason. Its
            // text and payload are never retained.
            throw ZynSignError.crypto(.signingFailure)
        }
        guard !signature.isEmpty else {
            throw ZynSignError.crypto(.malformedSignature)
        }

        return SigningResult(
            signature: signature,
            algorithm: request.algorithm,
            digestAlgorithm: request.algorithm.digestAlgorithm,
            identityID: request.identityID,
            publicKeyAlgorithm: capability.publicKeyAlgorithm,
            certificateFingerprint: nil,
            signedDigest: signedDigest,
            context: request.context
        )
    }
}
