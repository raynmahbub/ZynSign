import Foundation

/// Download Center workspace constructors for `ZynSignError`.
///
/// These cover the persisted download queue and its private file area. A
/// snapshot that cannot be read is a diagnostic, not a dead end: the center
/// starts empty rather than importing or deleting anything it cannot interpret.
extension ZynSignError {

    /// The center's own storage could not be prepared, read, or written.
    static func downloadCenterStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access the Download Center's storage.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The download snapshot exists but cannot be interpreted by this build.
    static func downloadCenterSnapshotUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's Download Center could not be restored.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
