/// Preferences-specific constructors for `ZynSignError`.
///
/// Keeping and restoring preferences fails in exactly two interesting ways:
/// the store could not be written, or the stored document could not be
/// interpreted. The second is never fatal — an unreadable preferences file
/// falls back to shipped defaults rather than blocking launch — but it is
/// still reported so the Diagnostics area can say so honestly.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key
/// material, credentials, profile bodies, device identifiers, user data, or
/// unnecessary filesystem locations. No preference *value* is ever placed in
/// an error: the user already knows what they chose.
extension ZynSignError {

    /// The preferences file could not be read or written — the directory
    /// could not be prepared, or the document could not be stored.
    static func preferencesStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not save your preferences.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The stored preferences document exists but is not a document this
    /// build can interpret. ZynSign falls back to its shipped defaults and
    /// says so; it never discards the file silently.
    static func preferencesUnreadable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not read your stored preferences, so it is using its defaults.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
