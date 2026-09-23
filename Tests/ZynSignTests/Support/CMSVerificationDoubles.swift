import Foundation
@testable import ZynSign

/// A signature mechanism double that records every check it was asked to make.
///
/// The CMS boundary's own logic — container reading, signer selection,
/// attribute binding, status mapping — is deterministic and platform
/// independent, so tests drive it with this double and assert on what it
/// received. Signature mathematics against real fixture bytes is exercised
/// separately by the iOS-gated platform verifier tests.
final class RecordingCMSSignatureVerifier: CMSSignatureVerifier {

    /// One recorded verification request.
    struct Call: Equatable {
        let message: Data
        let signature: Data
        let algorithm: CMSVerificationAlgorithm
        let certificateFingerprint: CertificateFingerprint
    }

    /// The answer to give when no error is configured.
    var result = true

    /// An error to throw instead of answering.
    var error: Error?

    private(set) var calls: [Call] = []

    var callCount: Int { calls.count }

    var lastCall: Call? { calls.last }

    func verify(
        message: Data,
        signature: Data,
        algorithm: CMSVerificationAlgorithm,
        certificate: Certificate
    ) throws -> Bool {
        calls.append(
            Call(
                message: message,
                signature: signature,
                algorithm: algorithm,
                certificateFingerprint: certificate.fingerprint
            )
        )
        if let error { throw error }
        return result
    }
}

/// A deterministic mechanism that accepts a signature only when it equals the
/// SHA-256 digest of the message it was handed.
///
/// Real fixture signatures are RSA and ECDSA values, so this double rejects
/// them; it exists to exercise the rejected path over genuine container bytes
/// without a device and without implying anything about platform behaviour.
struct DigestEchoCMSSignatureVerifier: CMSSignatureVerifier {

    func verify(
        message: Data,
        signature: Data,
        algorithm: CMSVerificationAlgorithm,
        certificate: Certificate
    ) throws -> Bool {
        guard algorithm.isSupported else {
            throw ZynSignError.cms(.unsupportedAlgorithm)
        }
        return signature == Data(CertificateDigest.sha256(message))
    }
}

/// A CMS boundary double that returns a prepared result.
struct StubCMSVerifier: CMSVerifier {

    let result: CMSVerificationResult
    var error: Error?

    init(result: CMSVerificationResult, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult {
        if let error { throw error }
        return result
    }
}

/// A CMS boundary double that fails with foreign, unredacted text.
struct ForeignErrorCMSVerifier: CMSVerifier {

    static let privateText = "private cms provider detail"

    func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult {
        throw NSError(
            domain: "private cms provider",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: Self.privateText]
        )
    }
}

/// A payload-decoder double for the verification use case.
///
/// The verification use case feeds the existing inspection use case through its
/// payload overload, so the decoder seam must never be reached. A call is
/// recorded so a test can assert that.
final class UnusedPayloadDecoder: ProvisioningProfilePayloadDecoder {

    private(set) var callCount = 0

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        callCount += 1
        throw ZynSignError.provisioningProfilePlatformParsingFailure(
            diagnosticDetail: "The verification use case must not decode through this seam."
        )
    }
}

/// A read-only identity store double.
///
/// It records capability requests so a test can prove that establishing a
/// certificate relationship never asked for a signing capability and never
/// produced a signature.
final class TestIdentityStore: IdentityStore {

    var identities: [SigningIdentity] = []
    var failure: Error?

    private(set) var capabilityRequests: [SigningIdentityIdentifier] = []

    func listIdentities() throws -> [SigningIdentity] {
        if let failure { throw failure }
        return identities
    }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        if let failure { throw failure }
        return identities.first { $0.id == id }
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        capabilityRequests.append(id)
        throw ZynSignError.identity(.capabilityUnavailable)
    }
}

/// Helpers shared by the CMS and profile-verification tests.
enum CMSVerificationTestSupport {

    /// The first offset at which `needle` occurs in `haystack`, or `nil`.
    ///
    /// A small byte search, used to prove that bytes the CMS boundary
    /// reconstructs are the bytes the container actually carried. Fixtures are
    /// a few kilobytes, so the direct search is cheaper than the machinery a
    /// general-purpose matcher would need.
    static func firstIndex(of needle: Data, in haystack: Data) -> Int? {
        let haystackBytes = Array(haystack)
        let needleBytes = Array(needle)
        guard !needleBytes.isEmpty, needleBytes.count <= haystackBytes.count else { return nil }
        for start in 0...(haystackBytes.count - needleBytes.count) {
            if Array(haystackBytes[start ..< start + needleBytes.count]) == needleBytes {
                return start
            }
        }
        return nil
    }

    /// The lowercase hexadecimal SHA-256 digest text of `data`.
    static func sha256Hexadecimal(_ data: Data) -> String? {
        CertificateFingerprint(digestBytes: CertificateDigest.sha256(data))?.hexDigest
    }

    /// Parses a fixture certificate with the production certificate parser.
    static func certificate(_ der: Data) throws -> Certificate {
        Certificate(
            metadata: try AppleCertificateParser().parseCertificate(derData: der),
            derData: der
        )
    }
}

/// A certificate parser that never produces metadata, used to observe the
/// boundary's behaviour when no embedded certificate can be parsed.
struct OpaqueCertificateParser: CertificateParser {

    func parseCertificate(_ input: CertificateInput) throws -> CertificateMetadata {
        throw ZynSignError.invalidCertificateStructure(
            diagnosticDetail: "This parser records that no certificate could be parsed."
        )
    }
}
