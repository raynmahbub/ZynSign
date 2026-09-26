/// Library-organization constructors for `ZynSignError`.
///
/// These factories cover collections and the organization document that
/// holds them. They keep "the name you typed cannot be used", "the
/// collection is gone", and "the organization could not be read or saved"
/// apart, because each has a different remedy. User-facing text never
/// repeats what the user typed and never names a storage location.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key
/// material, credentials, profile bodies, device identifiers, user data, or
/// unnecessary filesystem locations.
extension ZynSignError {

    /// A collection name was empty, or longer than the limit, once
    /// surrounding whitespace and control characters were removed.
    static func libraryCollectionNameInvalid(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "Give the collection a name of 1 to \(LibraryCollection.maximumNameLength) characters.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// Another collection already uses the name, ignoring case, diacritics,
    /// and width.
    static func libraryCollectionNameTaken(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "A collection with that name already exists. Choose a different name.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// No collection exists for the identifier an operation named — it was
    /// deleted, for example, while a sheet that refers to it was open.
    static func libraryCollectionNotFound(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The collection is no longer in your library.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// A collection with the same identifier already exists. Identifiers
    /// are freshly minted, so this indicates a caller defect.
    static func libraryOrganizationConflict(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "The collection could not be created.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The organization document could not be written, or its directory
    /// could not be prepared. Nothing about the library's applications
    /// changed.
    static func libraryOrganizationStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not save your library's collections.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The organization document exists but cannot be interpreted. It is
    /// left in place for diagnosis; nothing is reset or partially loaded.
    static func libraryOrganizationUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "Your library's collections could not be read.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The organization document was written in a schema newer than this
    /// build understands. The document is intact and is left untouched.
    static func libraryOrganizationUnsupported(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "Your library's collections were saved by a newer version of ZynSign and cannot be read by this build.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// Nothing could be exported: none of the requested applications has a
    /// package file ZynSign can hand over.
    static func libraryExportUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "None of the selected applications has a package file that can be exported.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
