/// Import-specific constructors for `ZynSignError`.
///
/// These factories distinguish the ways bringing a user-selected package into
/// ZynSign can fail, so that "the user cancelled", "the file cannot be
/// reached", "the platform refused access", "ZynSign's own storage failed",
/// and "something unexpected happened" remain separate outcomes with separate
/// remedies. Each maps onto a shared diagnostic category; callers never
/// invent categories, and no provider identity, security-scoped location, or
/// other filesystem detail reaches user-facing text.
///
/// User cancellation is a first-class category and is never rendered as an
/// application error: a cancelled import is an ordinary outcome.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key
/// material, credentials, profile bodies, device identifiers, user data, or
/// unnecessary filesystem locations.
extension ZynSignError {

    /// The user cancelled the import, or the surrounding task was cancelled
    /// before the import completed.
    static func importCancelled(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .cancelled,
            userMessage: "The import was cancelled.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected file is not of the accepted package type. Decided by the
    /// file-type policy before any content is read; the archive layer remains
    /// the authority on whether the content is a valid package.
    static func unsupportedImportFile(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "ZynSign can import only .ipa application packages.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected file could not be reached — it disappeared, or the file
    /// provider could not produce it. The failure is on the provider side; it
    /// says nothing about the file's content.
    static func selectedFileUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The selected file could not be reached.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The platform refused access to the selected file. The failure is an
    /// access grant, not the file's content and not a ZynSign defect.
    static func selectedFileAccessDenied(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign was not allowed to read the selected file.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// ZynSign could not prepare its own temporary storage for the import.
    /// The failure is on the infrastructure side.
    static func importTemporaryStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not prepare temporary storage for the import.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected package could not be copied into ZynSign's working
    /// storage — the source stopped being readable, or the destination could
    /// not be written, while staging ran.
    static func importCopyFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not copy the selected package into its working storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The import ended in a way the intake and the use case do not model.
    /// The failure is on the infrastructure side; the underlying cause is
    /// preserved for diagnosis and never shown to the user.
    static func importUnexpectedFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "An unexpected problem ended the import.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
