import Foundation

/// Release-feed constructors for `ZynSignError`.
///
/// A repository release feed is remote, untrusted metadata. Two failures are
/// typed: the feed could not be reached or does not form an address, and the
/// feed answered but its body cannot be read as a release listing. Neither
/// message carries the feed body.
extension ZynSignError {

    /// The feed could not be reached, or the reference does not form an
    /// address.
    static func releaseFeedUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "The release feed could not be reached.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The feed answered, but its body is not a readable release listing.
    static func releaseFeedUnreadable(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "The release feed did not return a readable release listing.",
            diagnosticDetail: diagnosticDetail
        )
    }
}
