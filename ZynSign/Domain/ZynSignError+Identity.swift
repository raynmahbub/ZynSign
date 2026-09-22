/// Machine-readable identity failures. No case carries user or platform data.
enum SigningIdentityFailure: String, CaseIterable, Hashable {
    case identityNotFound
    case certificateUnavailable
    case privateKeyUnavailable
    case certificateKeyMismatch
    case unsupportedKeyType
    case unsupportedSigningAlgorithm
    case invalidSigningInput
    case keychainAccessFailure
    case authorizationFailure
    case duplicateIdentity
    case malformedStoredIdentity
    case capabilityUnavailable
    case platformRestriction
    case signingFailure
    case unexpectedSecurityFailure

    var category: DiagnosticCategory {
        switch self {
        case .identityNotFound, .certificateUnavailable, .certificateKeyMismatch,
             .invalidSigningInput, .malformedStoredIdentity: return .invalidInput
        case .unsupportedKeyType, .unsupportedSigningAlgorithm: return .unsupportedInput
        case .privateKeyUnavailable, .authorizationFailure, .capabilityUnavailable,
             .platformRestriction: return .capabilityUnavailable
        case .duplicateIdentity: return .ambiguousInput
        case .keychainAccessFailure: return .storageFailure
        case .signingFailure, .unexpectedSecurityFailure: return .internalFailure
        }
    }

    var userMessage: String {
        switch self {
        case .identityNotFound: return "The signing identity is no longer registered."
        case .certificateUnavailable: return "The identity's certificate is unavailable."
        case .privateKeyUnavailable: return "The identity's signing key is unavailable."
        case .certificateKeyMismatch: return "The certificate and signing key do not match."
        case .unsupportedKeyType: return "This signing key type is not supported."
        case .unsupportedSigningAlgorithm: return "The requested signing algorithm is not supported by this key."
        case .invalidSigningInput: return "The signing input does not match the requested algorithm."
        case .keychainAccessFailure: return "Secure identity storage could not be accessed."
        case .authorizationFailure: return "Access to the signing identity is not authorized right now."
        case .duplicateIdentity: return "This certificate already has a registered identity."
        case .malformedStoredIdentity: return "Stored identity information could not be read safely."
        case .capabilityUnavailable: return "The signing capability is unavailable."
        case .platformRestriction: return "The required identity protection is not available."
        case .signingFailure: return "The requested signature could not be produced."
        case .unexpectedSecurityFailure: return "An unexpected security operation failed."
        }
    }
}

extension ZynSignError {
    /// Unlike general diagnostic factories, this boundary accepts no free-form
    /// detail or underlying error that could contain credentials or key handles.
    static func identity(_ reason: SigningIdentityFailure) -> ZynSignError {
        ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: reason.rawValue,
            identityFailure: reason
        )
    }

    /// Preserve only a known reason, never foreign error descriptions/payloads.
    static func sanitizedIdentityFailure(_ error: any Error) -> ZynSignError {
        identity((error as? ZynSignError)?.identityFailure ?? .unexpectedSecurityFailure)
    }
}
