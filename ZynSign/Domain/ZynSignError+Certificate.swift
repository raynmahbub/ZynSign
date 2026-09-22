/// Certificate-specific constructors for `ZynSignError`.
///
/// These factories distinguish the ways certificate handling can fail, so
/// that "the data is not a certificate", "the certificate is structurally
/// broken", "the certificate uses an unsupported feature", and "the
/// operation failed" stay separate outcomes with separate user remedies.
/// Each maps onto a shared diagnostic category; callers never invent
/// categories, and no key material, passwords, or sensitive certificate
/// details reach user-facing text.
///
/// `diagnosticDetail` remains subject to the redaction rules: no private
/// key material, passwords, authentication tokens, or complete sensitive
/// credentials.
extension ZynSignError {

    /// The data could not be parsed as a certificate at all — it is not DER,
    /// it is truncated, or its structure is too damaged to interpret.
    static func invalidCertificateData(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected file does not contain a valid certificate.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The certificate is structurally parseable but contains a feature
    /// ZynSign does not support, such as an unsupported public-key type or
    /// signature algorithm.
    static func unsupportedCertificate(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "The certificate uses a feature ZynSign does not support.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The certificate data is malformed in a way that was detected after
    /// initial parsing, such as invalid dates or inconsistent fields.
    static func malformedCertificate(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The certificate is malformed and cannot be used.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A signing operation failed because the required private key is not
    /// available or not accessible.
    static func signingKeyUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "The signing key is not available.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A signing operation failed for a reason other than key
    /// unavailability.
    static func signingFailed(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "The signing operation could not be completed.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The identity store could not be accessed.
    static func identityStoreFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access its signing identities.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A certificate was found but no matching identity exists.
    static func signingIdentityNotFound(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "No signing identity matches the selected certificate.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
