import Foundation

/// Signing-queue workspace constructors for `ZynSignError`.
///
/// These factories cover the persisted signing queue's workspace: its
/// snapshot document and the queue-owned profile copies beside it. They
/// mirror `ZynSignError+SigningWorkspace.swift`: storage failure and
/// snapshot unreadable, with one factory per outcome so the diagnostic
/// category and the user-facing message stay aligned. The queue treats
/// every one of these as recoverable degradation — a queue whose snapshot
/// cannot be read starts empty rather than refusing to run — so these
/// errors are diagnostics, never dead ends.
extension ZynSignError {

    // MARK: - Queue workspace

    /// The queue's own storage could not be prepared, read, or written.
    static func signingQueueStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access the signing queue's storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The queue snapshot exists but cannot be interpreted by this build.
    static func signingQueueSnapshotUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's signing queue could not be restored.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A signing job's request could not be assembled — a missing package
    /// file, an unparsable identifier, or a profile copy that is gone.
    static func signingJobRequestUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The signing job's request could not be assembled.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
