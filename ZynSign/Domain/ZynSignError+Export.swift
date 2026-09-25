/// Export-workspace constructors for `ZynSignError`.
///
/// These factories cover the Export Center and signing-operation workspace,
/// mirroring `ZynSignError+Library.swift`: storage failure, catalog
/// unreadable, record not found, artifact no longer held, and the two
/// conditions a signing run can hit before it starts — no free space, and no
/// name available for the artifact. Each maps onto a shared diagnostic
/// category, and none of them carries a location, a file name chosen by the
/// user, or any signing material in its user-facing message.
extension ZynSignError {

    /// Export storage could not be prepared, read, or written.
    static func exportStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access its exported artifacts.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The export catalog exists but cannot be interpreted: it is not a
    /// catalog, it is damaged, or it records a value this build cannot
    /// represent. The catalog is left in place for diagnosis.
    static func exportCatalogUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's export records could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The export catalog was written in a schema newer than this build
    /// understands. The catalog is intact and is left untouched.
    static func exportCatalogUnsupported(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "ZynSign's export records were written by a newer version of ZynSign and cannot be read by this build.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No export record exists for the identifier an operation named.
    static func exportRecordNotFound(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "That exported artifact is no longer listed in the Export Center.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The artifact an export record describes is not held by export storage.
    /// This is a listed state wherever a record is shown — see
    /// `ExportAvailability` — and an error only where an operation needed the
    /// bytes.
    static func exportArtifactUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The signed artifact is no longer in ZynSign's export storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// Export storage already holds a file where the artifact would be
    /// committed. The name policy resolves collisions; reaching this means a
    /// name appeared between choosing it and writing it, and nothing is
    /// overwritten.
    static func exportArtifactConflict(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign did not overwrite an existing file in export storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// Signing could not start because the device does not have enough free
    /// space to hold the working copy, the produced container, and the
    /// artifact without risking a partial write.
    static func insufficientStorageForSigning(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "There is not enough free space to sign this application safely.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The signing workspace could not be created for one operation. Each
    /// operation gets its own directory, so this is an infrastructure failure
    /// rather than a conflict between operations.
    static func signingWorkspaceUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not prepare a workspace for this signing run.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
