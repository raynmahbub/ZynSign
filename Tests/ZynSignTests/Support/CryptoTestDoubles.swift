import Foundation
@testable import ZynSign

/// A signing capability double that stands in for a protected key.
///
/// It returns prepared signature bytes and never a private key, and it
/// records every input it was asked to sign so a test can assert exactly
/// what crossed the capability boundary: data and an explicit algorithm,
/// and nothing else.
final class RecordingSigningCapability: SigningCapability {

    var identityID: SigningIdentityIdentifier = SigningIdentityIdentifier()
    var publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
    var isAvailable = true
    var supportedAlgorithms: Set<SigningAlgorithm> = Set(SigningAlgorithm.allCases)

    /// The signature bytes to return when no error is configured.
    var signatureBytes: Data = Data(repeating: 0x5A, count: 64)

    /// An error to throw from `sign` instead of answering.
    var signingError: Error?

    /// Every input the capability was asked to sign, in order.
    private(set) var signedCalls: [(data: Data, algorithm: SigningAlgorithm)] = []

    var signCallCount: Int { signedCalls.count }

    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        if let signingError { throw signingError }
        signedCalls.append((data, algorithm))
        return signatureBytes
    }
}

/// An identity store double that hands out prepared capabilities.
///
/// It records capability and metadata requests so a test can assert when —
/// and whether — the use case reached the store, and what it asked for.
final class InMemorySigningIdentityStore: IdentityStore {

    struct IdentityEntry {
        let identity: SigningIdentity
        let capability: any SigningCapability
    }

    var entries: [SigningIdentityIdentifier: IdentityEntry] = [:]

    /// An error to throw from `signingCapability(for:)` instead of
    /// answering.
    var capabilityFailure: Error?

    /// An error to throw from `metadata(for:)` instead of answering.
    var metadataFailure: Error?

    private(set) var capabilityRequests: [SigningIdentityIdentifier] = []
    private(set) var metadataRequests: [SigningIdentityIdentifier] = []

    func listIdentities() throws -> [SigningIdentity] {
        entries.values.map(\.identity).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        entries[id]?.identity
    }

    func metadata(for id: SigningIdentityIdentifier) throws -> SigningIdentityMetadata? {
        metadataRequests.append(id)
        if let metadataFailure { throw metadataFailure }
        guard let identity = entries[id]?.identity else { return nil }
        return SigningIdentityMetadata(identity: identity)
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        capabilityRequests.append(id)
        if let capabilityFailure { throw capabilityFailure }
        guard let entry = entries[id] else {
            throw ZynSignError.identity(.identityNotFound)
        }
        return entry.capability
    }
}

/// A message-digest double that computes no hashes at all.
///
/// It records the requested algorithm and returns a prepared digest of the
/// right length, so a test can assert that the operation was requested —
/// and which algorithm was selected — without a hashing implementation.
final class RecordingMessageDigest: MessageDigest {

    var preparedDigest: Digest?
    var failure: Error?

    private(set) var requested: [(data: Data, algorithm: DigestAlgorithm)] = []

    func digest(_ data: Data, algorithm: DigestAlgorithm) throws -> Digest {
        requested.append((data, algorithm))
        if let failure { throw failure }
        guard let preparedDigest else {
            throw ZynSignError.crypto(.unsupportedAlgorithm)
        }
        return preparedDigest
    }
}

/// A signature-verifier double that records every check it was asked to
/// make and returns a prepared outcome.
final class RecordingCryptographicSignatureVerifier: CryptographicSignatureVerifier {

    struct Call: Equatable {
        let signature: Data
        let input: SigningInput
        let algorithm: SigningAlgorithm
        let certificateFingerprint: CertificateFingerprint
    }

    var outcome: SignatureVerificationOutcome = .invalid

    private(set) var calls: [Call] = []

    var callCount: Int { calls.count }
    var lastCall: Call? { calls.last }

    func verify(
        signature: Data,
        message: SigningInput,
        algorithm: SigningAlgorithm,
        certificate: Certificate
    ) -> SignatureVerificationOutcome {
        calls.append(
            Call(
                signature: signature,
                input: message,
                algorithm: algorithm,
                certificateFingerprint: certificate.fingerprint
            )
        )
        return outcome
    }
}
