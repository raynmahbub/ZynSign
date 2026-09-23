import Foundation

/// The outcome of checking one cryptographic signature.
///
/// The four outcomes are deliberately separate, because they are different
/// facts:
///
/// - `valid` — the signature over the presented bytes was produced by the
///   private key matching the certificate's public key. A cryptographic
///   conclusion only. It is not a statement that the certificate is
///   trusted, that a chain reaches an anchor, that an identity is
///   authorized, or that anything is code signed.
/// - `invalid` — the signature does not verify. A cryptographic conclusion
///   about the bytes presented, not an error in the caller's request.
/// - `unsupported` — the requested operation is not one this build can
///   perform, with a structured reason. Not a defect in the input and not a
///   statement about the signature.
/// - `failed` — the operation could not be completed and no conclusion was
///   reached, with a structured reason.
enum SignatureVerificationOutcome: Equatable, Hashable {

    /// The signature verifies against the certificate's public key under
    /// the selected operation.
    case valid

    /// The signature does not verify.
    case invalid

    /// The requested operation is not one this build can perform.
    case unsupported(CryptoFailure)

    /// The operation could not be completed; no conclusion was reached.
    case failed(CryptoFailure)

    /// Whether the signature was checked and accepted.
    var isValid: Bool { self == .valid }

    /// Whether a cryptographic conclusion was reached, in either direction.
    var isConclusion: Bool {
        switch self {
        case .valid, .invalid: return true
        case .unsupported, .failed: return false
        }
    }
}

/// The narrow seam where one signature is checked against one certificate's
/// public key.
///
/// This is the verification counterpart of `SigningCapability`. It takes
/// only public material — a signature, the bytes the signature claims to
/// cover, the selected operation, and a certificate — and returns an
/// explicit outcome. It never touches a private key, never requests a
/// signing capability, and never reuses signing state: whatever conclusion
/// it reaches is derived from the bytes and public material it was handed,
/// so a signing-side bug cannot silently validate itself.
///
/// The outcome is a value, not an exception. A signature that does not
/// verify is a normal outcome, as is an operation this build cannot
/// perform, so a caller can distinguish "does not verify" from "could not
/// be checked" — which are three different facts together with "verified".
///
/// What the outcome answers: whether the signature over these bytes was
/// produced by the private key matching this certificate's public key.
/// What it never answers: whether the certificate is trusted, whether an
/// identity is authorized, or whether an artifact is correctly code signed.
protocol CryptographicSignatureVerifier {

    /// Checks `signature` over `message` with the public key of
    /// `certificate` under `algorithm`.
    ///
    /// - Parameters:
    ///   - signature: The signature bytes to check.
    ///   - message: The bytes the signature claims to cover, explicitly a
    ///     message or a digest.
    ///   - algorithm: The operation to check under.
    ///   - certificate: The public certificate whose key the signature is
    ///     checked against.
    /// - Returns: The explicit outcome. Never throws: every outcome,
    ///   including unsupported operations and malformed values, is a value.
    func verify(
        signature: Data,
        message: SigningInput,
        algorithm: SigningAlgorithm,
        certificate: Certificate
    ) -> SignatureVerificationOutcome
}

/// The honest fallback when no signature-verification mechanism is composed.
///
/// On a target without the platform key primitives, or in a composition
/// that deliberately omits a mechanism, every verification is reported as
/// unavailable — never skipped, never reported as a failure of the
/// presented signature, and never answered with a guess.
struct UnavailableCryptographicSignatureVerifier: CryptographicSignatureVerifier {

    init() {}

    func verify(
        signature: Data,
        message: SigningInput,
        algorithm: SigningAlgorithm,
        certificate: Certificate
    ) -> SignatureVerificationOutcome {
        .unsupported(.platformLimitation)
    }
}
