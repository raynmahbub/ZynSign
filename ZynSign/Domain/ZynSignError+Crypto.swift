/// Stable reasons for failures at the cryptographic signing and
/// verification boundary.
///
/// The reason is safe to expose to application code. Diagnostic details
/// passed to the factory below must stay redacted: operation identifiers,
/// algorithm names, identity references, fingerprints, and bounded counts
/// are acceptable; key material, credentials, signed data, signature bytes
/// beyond their count, and foreign error text are not.
///
/// These reasons cover what this boundary decides. A failure the identity
/// boundary decided — an unknown identity, an unavailable key, an
/// authorization failure — keeps its own `SigningIdentityFailure` reason
/// when it crosses a capability, and a container failure keeps its
/// `CMSFailure` reason. This vocabulary does not restate those facts.
enum CryptoFailure: String, CaseIterable, Hashable {

    /// A digest or signature scheme this build does not support.
    case unsupportedAlgorithm

    /// The requested key family does not match the key that is available.
    /// An RSA operation against an EC-only key, or the reverse, is
    /// incompatible: it is reported, never substituted.
    case incompatibleKey

    /// The input does not match the requested operation: a message where a
    /// digest is required, a digest where a message is required, or a
    /// digest of an algorithm the operation does not work on.
    case invalidInput

    /// A presented or produced signature is not a coherent value for the
    /// operation.
    case malformedSignature

    /// The certificate a verification was asked to use could not be used:
    /// absent encoding, or a platform object the platform could not read a
    /// public key from.
    case certificateUnavailable

    /// The signing operation could not complete after the request passed
    /// every check: the protected-key operation itself failed.
    case signingFailure

    /// The verification operation could not complete for a reason that is
    /// not a plain mismatch and not a platform limitation.
    case verificationFailure

    /// The signing capability is not available to this boundary.
    case capabilityUnavailable

    /// The platform cannot perform the requested operation in this build or
    /// on this target. Reported as a limitation, never as a defect in the
    /// input.
    case platformLimitation

    /// A cryptographic operation failed for a reason the boundary could not
    /// classify further.
    case unexpectedFailure

    var category: DiagnosticCategory {
        switch self {
        case .invalidInput, .malformedSignature, .certificateUnavailable:
            return .invalidInput
        case .unsupportedAlgorithm, .incompatibleKey:
            return .unsupportedInput
        case .capabilityUnavailable, .platformLimitation:
            return .capabilityUnavailable
        case .signingFailure, .verificationFailure, .unexpectedFailure:
            return .internalFailure
        }
    }

    var userMessage: String {
        switch self {
        case .unsupportedAlgorithm:
            return "The requested cryptographic algorithm is not supported."
        case .incompatibleKey:
            return "The requested signature does not match the key of this signing identity."
        case .invalidInput:
            return "The signing input does not match the requested operation."
        case .malformedSignature:
            return "The signature value is not in a usable form."
        case .certificateUnavailable:
            return "The certificate for this verification is not available."
        case .signingFailure:
            return "The signature could not be produced."
        case .verificationFailure:
            return "The signature verification could not be completed."
        case .capabilityUnavailable:
            return "The signing capability is not available."
        case .platformLimitation:
            return "This operation is not available on this platform."
        case .unexpectedFailure:
            return "An unexpected cryptographic operation failed."
        }
    }
}

extension ZynSignError {

    /// Constructs a controlled cryptographic failure. The caller supplies
    /// only redacted diagnostic context; this factory never includes key
    /// material, signed data, or signature bytes in the user message.
    ///
    /// The diagnostic detail defaults to the reason itself, as the identity
    /// and CMS factories do; a caller-supplied detail replaces it and stays
    /// bound to the redaction rules.
    static func crypto(
        _ reason: CryptoFailure,
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: diagnosticDetail ?? reason.rawValue,
            cryptoFailure: reason
        )
    }

    /// Preserves a known crypto or identity reason from a foreign error.
    ///
    /// Reasons the identity boundary decided keep their own vocabulary when
    /// they cross a capability; anything else is reduced to an unexpected
    /// failure. Foreign error descriptions and payloads are never retained.
    static func sanitizedCryptoFailure(_ error: any Error) -> ZynSignError {
        if let zynSignError = error as? ZynSignError,
           zynSignError.cryptoFailure != nil || zynSignError.identityFailure != nil {
            return zynSignError
        }
        return crypto(.unexpectedFailure)
    }
}
