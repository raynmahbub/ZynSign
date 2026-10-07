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
    ///
    /// The message names every extension the policy accepts, because a person
    /// holding a `.tipa` or a folder of packages in a `.zip` needs to know
    /// those are wanted too — and needs to hear that a profile or a
    /// certificate is imported somewhere else, not that ZynSign is broken.
    static func unsupportedImportFile(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "ZynSign imports .ipa and .tipa packages, and .zip archives that hold them. A .p12 or a .mobileprovision is added under Certificates & Profiles instead.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected file is empty. An empty file cannot be an application
    /// package, and refusing it before anything is copied keeps the failure
    /// cheap and its explanation exact.
    static func importSourceEmpty(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected file is empty, so it cannot be an application package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected file begins with bytes that no ZIP container begins with.
    ///
    /// This is a cheap integrity check, not a verdict on the content: a file
    /// that passes it is still untrusted and is decided by the archive and
    /// metadata examinations. It exists so the common mistake — a plain file
    /// that was renamed to `.ipa` — is refused before it is copied, with an
    /// explanation that names what was actually observed.
    static func importContainerUnrecognised(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The selected file is not a package archive, so it cannot be an application package.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The selected file is larger than ZynSign will copy. The check runs
    /// before anything is written, so an oversized selection costs the user
    /// nothing but the refusal — and never fills the device.
    static func importSourceTooLarge(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .unsupportedInput,
            userMessage: "The selected package is larger than ZynSign can import.",
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
