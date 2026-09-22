/// Library-specific constructors for `ZynSignError`.
///
/// These factories distinguish the ways keeping and finding library records
/// can fail, so that "the library's own storage failed", "the catalog cannot
/// be interpreted", "the catalog is newer than this build", and "the record
/// is gone" stay separate outcomes with separate remedies. A record whose
/// artifact is gone is not an error at this boundary but a listed state —
/// see `ArtifactAvailability`. Each factory maps onto a shared diagnostic
/// category; callers never invent categories, and no storage location,
/// catalog content, or platform error text reaches user-facing text.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key
/// material, credentials, profile bodies, device identifiers, user data, or
/// unnecessary filesystem locations.
extension ZynSignError {

    /// The library's own storage could not be prepared, read, or written —
    /// a directory could not be created, the catalog could not be written,
    /// or an artifact could not be moved or removed. The failure is on the
    /// infrastructure side; it says nothing about any package.
    static func libraryStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not access its application library.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The library catalog exists but cannot be interpreted: it is not a
    /// catalog, it is damaged, or it records a value this build cannot
    /// represent. The catalog is left in place for diagnosis; nothing is
    /// reset or partially loaded.
    static func libraryCatalogUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign's application library could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The library catalog was written in a schema newer than this build
    /// understands. Reported as a capability this build lacks, not as
    /// damage: the catalog is intact and is left untouched.
    static func libraryCatalogUnsupported(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "ZynSign's application library was written by a newer version of ZynSign and cannot be read by this build.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No record exists for the identifier an operation named.
    static func libraryRecordNotFound(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The application is no longer in ZynSign's library.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A record with the same identifier already exists, so a new record
    /// could not be created under it. Identifiers are freshly minted, so
    /// this indicates a caller defect rather than a user action.
    static func libraryRecordConflict(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "The application could not be added because ZynSign's library already holds a record with its identity.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// An artifact that has not passed inspection was offered to the
    /// library. Only accepted imports become records; this indicates a
    /// caller defect, not a problem with the user's package.
    static func unrecordableArtifact(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "Only a package that passed inspection can be added to ZynSign's library.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
