/// Archive-specific constructors for `ZynSignError`.
///
/// These factories distinguish the ways container handling can fail, so that
/// "the package is broken", "ZynSign refuses this entry", "the package is
/// beyond the accepted resource policy", and "ZynSign's own storage failed"
/// stay separate outcomes with separate user remedies. Each maps onto a shared
/// diagnostic category; callers never invent categories, and no lower-level
/// container or filesystem detail reaches user-facing text.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key material,
/// credentials, profile bodies, device identifiers, user data, or unnecessary
/// filesystem locations.
extension ZynSignError {

    /// The container could not be read as an archive at all — it is not a
    /// supported container, or its structure is too damaged to enumerate.
    static func unreadableArtifact(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "ZynSign could not read the selected package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The container records an entry whose name or form ZynSign refuses to
    /// process, such as an escaping path or an entry type it does not model.
    static func unsafeArchiveEntry(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected package contains an entry ZynSign cannot safely access.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The container declares more entries, more nesting, or more expanded
    /// content than ZynSign's resource policy accepts.
    static func archiveResourceLimitExceeded(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected package is larger or more complex than ZynSign can inspect.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A container feature ZynSign deliberately does not implement, such as an
    /// encrypted or otherwise unsupported entry encoding.
    static func unsupportedArchiveFeature(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "This package uses an archive feature ZynSign does not support.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// An entry exists but its content could not be produced — the stored data
    /// is truncated, inconsistent, or failed to expand. The failure is in the
    /// package's content, not in ZynSign's storage.
    static func archiveEntryUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "ZynSign could not read part of the selected package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// ZynSign could not rebuild or rewrite an application package: the entry
    /// set was refused, a container ceiling was exceeded, or the destination
    /// could not be written. The source artifact is untouched on every
    /// packaging failure; only the produced output is discarded.
    static func packagingFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "ZynSign could not rebuild the application package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No archive is available for the artifact ZynSign was asked to examine.
    /// The failure is on the infrastructure side; it says nothing about any
    /// package's contents.
    static func artifactNotAvailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not find the selected package in its working storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
