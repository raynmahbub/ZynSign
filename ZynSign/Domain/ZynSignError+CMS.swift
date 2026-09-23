/// Stable reasons for failures at the CMS container boundary.
///
/// The reason is safe to expose to application code. Diagnostic details passed
/// to the factory below must stay redacted: structural facts, bounded counts,
/// algorithm identifiers, and mapped platform error codes are acceptable;
/// container bytes, payload bytes, certificate bodies, and foreign error text
/// are not.
///
/// These reasons cover the container only. Profile metadata failures remain
/// `ProvisioningProfileFailure`, and identity failures remain
/// `SigningIdentityFailure`.
enum CMSFailure: String, CaseIterable, Hashable {

    /// No container bytes were presented.
    case emptyInput

    /// The container exceeds ZynSign's input bound.
    case inputTooLarge

    /// The bytes are not a coherent CMS message.
    case malformedCMS

    /// The encoding ends before the structure it declares.
    case truncatedCMS

    /// The message is CMS but not a content type ZynSign handles.
    case unsupportedContentType

    /// The message is a CMS shape ZynSign deliberately does not accept.
    case unsupportedStructure

    /// The message carries no encapsulated content to hand back.
    case payloadUnavailable

    /// A bounded resource policy stopped the read.
    case resourceLimitExceeded

    /// Decoding failed for a reason the boundary could not classify further.
    case decodeFailed

    /// The message has no signer.
    case signerUnavailable

    /// The message has more than one signer and ZynSign does not choose one.
    case multipleSigners

    /// The signature does not verify, or the signed attributes do not bind the
    /// encapsulated content.
    case signatureInvalid

    /// No embedded certificate could be related to the signer.
    case signerCertificateUnavailable

    /// A certificate the message embeds could not be parsed.
    case certificateParseFailed

    /// A certificate comparison failed.
    case certificateMismatch

    /// The declared digest or signature algorithm is not supported.
    case unsupportedAlgorithm

    /// No verification mechanism exists in this build or on this platform.
    case platformVerificationUnavailable

    /// A security operation failed unexpectedly.
    case unexpectedSecurityError

    var category: DiagnosticCategory {
        switch self {
        case .unsupportedContentType, .unsupportedStructure, .unsupportedAlgorithm:
            return .unsupportedInput
        case .platformVerificationUnavailable:
            return .capabilityUnavailable
        case .decodeFailed, .unexpectedSecurityError:
            return .internalFailure
        default:
            return .invalidInput
        }
    }

    var userMessage: String {
        switch self {
        case .emptyInput:
            return "The signed profile container is empty."
        case .inputTooLarge, .resourceLimitExceeded:
            return "The signed profile container is too large or complex to verify."
        case .malformedCMS:
            return "The signed profile container is not a valid signed message."
        case .truncatedCMS:
            return "The signed profile container is incomplete."
        case .unsupportedContentType:
            return "The signed profile container uses a message type ZynSign does not support."
        case .unsupportedStructure:
            return "The signed profile container uses a structure ZynSign does not support."
        case .payloadUnavailable:
            return "The signed profile container carries no readable profile payload."
        case .decodeFailed:
            return "The signed profile container could not be decoded."
        case .signerUnavailable:
            return "The signed profile container has no signer."
        case .multipleSigners:
            return "The signed profile container has more than one signer."
        case .signatureInvalid:
            return "The signed profile container's signature is not valid."
        case .signerCertificateUnavailable:
            return "The certificate that signed this profile container is not available."
        case .certificateParseFailed:
            return "A certificate in the signed profile container could not be read."
        case .certificateMismatch:
            return "The profile's certificate does not match the certificate that signed it."
        case .unsupportedAlgorithm:
            return "The signed profile container uses a signature algorithm ZynSign does not support."
        case .platformVerificationUnavailable:
            return "Signature verification is not available in this build."
        case .unexpectedSecurityError:
            return "An unexpected security operation failed."
        }
    }
}

extension ZynSignError {

    /// Constructs a controlled CMS failure. The caller supplies only redacted
    /// diagnostic context; this factory never includes container or payload
    /// bytes in the user message.
    static func cms(
        _ reason: CMSFailure,
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError,
            cmsFailure: reason
        )
    }

    /// Preserves only a known CMS reason from a foreign error, never its
    /// description or payload.
    static func sanitizedCMSFailure(_ error: any Error) -> ZynSignError {
        cms((error as? ZynSignError)?.cmsFailure ?? .unexpectedSecurityError)
    }
}
