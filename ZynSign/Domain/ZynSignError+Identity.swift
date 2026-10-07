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
    case invalidPassphrase
    case unsupportedContainerFormat
    case containerImportFailed
    case capabilityUnavailable
    case platformRestriction
    case signingFailure
    case unexpectedSecurityFailure

    var category: DiagnosticCategory {
        switch self {
        case .identityNotFound, .certificateUnavailable, .certificateKeyMismatch,
             .invalidSigningInput, .malformedStoredIdentity, .invalidPassphrase,
             .containerImportFailed: return .invalidInput
        case .unsupportedKeyType, .unsupportedSigningAlgorithm, .unsupportedContainerFormat: return .unsupportedInput
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
        case .invalidPassphrase: return "The password does not open this certificate file. Enter it again, or re-export the .p12 with the password you set for it."
        case .unsupportedContainerFormat: return "This file is not a PKCS#12 identity ZynSign can open. Export the certificate and its key as a .p12 or .pfx from the Mac or PC that holds them."
        case .containerImportFailed: return "ZynSign could not read that certificate file. Check the password, and if it keeps failing re-export the certificate and its key as a .p12 or .pfx."
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

    /// The same failure, with technical context for the log.
    ///
    /// The reason's own identifier stays first, so the detail reads the way it
    /// did and the added context is appended rather than substituted. A caller
    /// with nothing to add keeps using `identity(_:)`; there is deliberately no
    /// defaulted parameter, so that call stays unambiguous.
    ///
    /// The added text is subject to the same redaction rules as every other
    /// detail: it names the *policy* facts the Keychain reported — which class
    /// of key, which protection domain, whether the platform called it
    /// synchronizable or exportable — never key material, never a code that
    /// identifies the item.
    static func identity(_ reason: SigningIdentityFailure, diagnosticDetail: String?) -> ZynSignError {
        ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: [reason.rawValue, diagnosticDetail]
                .compactMap { $0 }
                .joined(separator: " "),
            identityFailure: reason
        )
    }

    /// Preserve only a known reason, never foreign error descriptions/payloads.
    static func sanitizedIdentityFailure(_ error: any Error) -> ZynSignError {
        identity((error as? ZynSignError)?.identityFailure ?? .unexpectedSecurityFailure)
    }
}

extension ZynSignError {

    // MARK: - Identity annotation workspace

    /// The local annotation catalog's own storage could not be prepared,
    /// read, or written. The catalog holds display labels and import dates
    /// only; this failure says nothing about any identity or key.
    static func identityAnnotationsStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access its certificate notes.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The local annotation catalog exists but cannot be interpreted: it is
    /// not a catalog, it is damaged, or it records a value this build cannot
    /// represent. The catalog is left in place for diagnosis.
    static func identityAnnotationsUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's certificate notes could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
