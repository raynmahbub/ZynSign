import Foundation

/// Tweak-library constructors for `ZynSignError`.
///
/// The tweak library keeps payload bytes and a record catalog in the app
/// container. Three failures are typed: the storage could not be prepared or
/// written, the catalog exists but cannot be interpreted, and a record the
/// caller named is not recorded. None carries payload bytes, fingerprint
/// input, or user file paths in its user-facing message.
extension ZynSignError {

    /// Tweak storage could not be prepared, read, or written.
    static func tweakLibraryStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access the tweak library.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The tweak catalog exists but cannot be interpreted: it is damaged or
    /// records a value this build cannot represent. The catalog is left in
    /// place for diagnosis.
    static func tweakLibraryCatalogUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's tweak library records could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The tweak catalog was written by a newer build than this one. The
    /// catalog is intact and is left untouched.
    static func tweakLibraryCatalogUnsupported(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "The tweak library was written by a newer version of ZynSign and cannot be read by this build.",
            diagnosticDetail: diagnosticDetail
        )
    }

    /// A structured on-disk catalog outside the library could not be
    /// interpreted. The catalog is left in place for diagnosis. The area
    /// name names the feature for diagnostics only; the user-facing message
    /// stays general.
    static func structuredCatalogUnreadable(
        area: String,
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not read its records for this feature.",
            diagnosticDetail: "[\(area)] \(diagnosticDetail ?? "The catalog could not be read.")",
            underlyingError: underlyingError
        )
    }
}
