import Foundation

/// Failures raised by the installed-applications workspace.
///
/// The cases are structural, like every other error family: they name the
/// requirement that was not met, never the content that was refused.
/// `userMessage` is the only text a screen shows.
extension ZynSignError {

    // MARK: - Installed-applications store

    /// The installed-applications catalog's own storage could not be
    /// prepared, read, or written.
    static func installedApplicationStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access your installed-applications records.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The installed-applications catalog exists but cannot be interpreted.
    static func installedApplicationCatalogUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's installed-applications records could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No installed-application record carries the identifier.
    static func installedApplicationRecordNotFound(identifier: String) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "That installation record no longer exists.",
            diagnosticDetail: "No installed-application record carries identifier '\(identifier)'."
        )
    }

    /// No pending attempt carries the identifier.
    static func installationAttemptNotFound(identifier: String) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "That delivery attempt no longer exists.",
            diagnosticDetail: "No pending installation attempt carries identifier '\(identifier)'."
        )
    }

    /// A record for the same bundle identifier already exists when the
    /// caller asked for a fresh record rather than an update.
    static func installedApplicationConflict(bundleIdentifier: String) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "ZynSign already keeps a record for this application.",
            diagnosticDetail: "An installed-application record already exists for bundle identifier '\(bundleIdentifier)'."
        )
    }

    /// The workspace action needs a capability the composition did not
    /// supply — a records store, or an independent verifier.
    static func installationWorkspaceCapabilityUnavailable(detail: String) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "That installation action is not available in this build of ZynSign.",
            diagnosticDetail: detail
        )
    }
}
