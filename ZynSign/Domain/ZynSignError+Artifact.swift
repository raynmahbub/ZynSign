/// Artifact-specific constructors for `ZynSignError`.
///
/// These factories map artifact lifecycle failures onto the shared diagnostic
/// categories, so callers never invent ad-hoc categories and never leak
/// lower-level failures into user-facing text. `diagnosticDetail` is
/// technical context for logs and reports, and callers remain responsible
/// for the redaction rules; `underlyingError` preserves the cause for
/// diagnosis and never appears in the user message.
extension ZynSignError {

    /// The package is not a usable application archive: it is unreadable,
    /// structurally broken, or carries malformed content.
    static func invalidArtifact(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected package is not a valid application archive.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The package is structurally coherent but uses features outside
    /// deliberately supported capability.
    static func unsupportedArtifact(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "This package uses features ZynSign does not support.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The package admits more than one safe interpretation — for example
    /// several application bundle candidates — so ZynSign refuses to choose
    /// between them.
    static func ambiguousArtifact(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .ambiguousInput,
            userMessage: "The selected package contains more than one application, so ZynSign cannot safely choose between them.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No application bundle could be found in the package.
    static func missingApplicationBundle(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "No application was found in the selected package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The package's declared application information has an unacceptable
    /// type or value.
    static func malformedArtifactMetadata(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The package's application information is malformed.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The package's declared application information contradicts itself or
    /// the archive layout.
    static func inconsistentArtifactMetadata(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The package's application information is inconsistent.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// ZynSign could not store the package in its own working storage. The
    /// failure is on the infrastructure side; it says nothing about the
    /// package contents.
    static func artifactStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not store the selected package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
