/// Signing-workspace constructors for `ZynSignError`.
///
/// These factories cover the preset, signing-history, and provisioning
/// profile workspaces. They mirror `ZynSignError+Library.swift`: storage
/// failure, catalog unreadable, record not found, and so on, with one
/// factory per outcome so the diagnostic category and the user-facing
/// message stay aligned.
extension ZynSignError {

    // MARK: - Preset workspace

    /// The preset catalog's own storage could not be prepared, read, or
    /// written.
    static func presetStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access your signing presets.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The preset catalog exists but cannot be interpreted.
    static func presetCatalogUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's signing presets could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A preset with the same identifier already exists.
    static func presetConflict(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "A signing preset with that name already exists.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The name the user offered cannot be stored.
    static func presetNameInvalid(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "Enter a preset name that is not empty and is 80 characters or fewer.",
            diagnosticDetail: diagnosticDetail
        )
    }

    /// No stored preset has the requested identifier.
    static func presetNotFound(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "That signing preset is no longer available.",
            diagnosticDetail: diagnosticDetail
        )
    }

    /// A preset cannot be applied because preflight did not pass, or a
    /// referenced certificate or profile could not be resolved.
    static func presetNotReady(
        userMessage: String = "That signing preset is not ready to use.",
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: userMessage,
            diagnosticDetail: diagnosticDetail
        )
    }

    /// Signing was requested without the final confirmation step.
    static func presetConfirmationRequired(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "Confirm the preset summary before signing.",
            diagnosticDetail: diagnosticDetail
        )
    }

    /// The signing queue was asked to run an application the plan marked as
    /// needing manual attention. The queue refuses rather than forcing it.
    static func presetQueueRefusedIncompatible(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "An application that needs manual attention was not queued.",
            diagnosticDetail: diagnosticDetail
        )
    }

    // MARK: - Signing history workspace

    /// The signing history journal's own storage could not be prepared,
    /// read, or written.
    static func signingHistoryStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access your signing history.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The signing history journal exists but cannot be interpreted.
    static func signingHistoryUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's signing history could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    // MARK: - Provisioning profile workspace

    /// The provisioning profile library's storage could not be prepared,
    /// read, or written.
    static func profileLibraryStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access your provisioning profiles.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The provisioning profile library exists but cannot be interpreted.
    static func profileLibraryUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's provisioning profile library could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The imported `.mobileprovision` file could not be parsed.
    static func invalidProvisioningProfileFile(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "ZynSign could not read that provisioning profile.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The provisioning profile is past its expiration date.
    static func provisioningProfileExpired(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "That provisioning profile has expired and cannot be used for signing.",
            diagnosticDetail: diagnosticDetail
        )
    }

    /// The provisioning profile does not cover the bundle identifier of
    /// the application the user wants to sign.
    static func provisioningProfileMismatch(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .ambiguousInput,
            userMessage: "That provisioning profile does not cover this application's bundle identifier.",
            diagnosticDetail: diagnosticDetail
        )
    }

    // MARK: - Health-score workspace

    /// The signing health score could not be computed because inputs
    /// were missing or unreadable.
    static func signingHealthAssessmentUnavailable(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "ZynSign could not assess signing readiness with the available information.",
            diagnosticDetail: diagnosticDetail
        )
    }

    // MARK: - Batch signing workspace

    /// A batch signing run was offered with no entries.
    static func emptyBatchSigningRequest(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "Batch signing needs at least one application.",
            diagnosticDetail: diagnosticDetail
        )
    }
}
