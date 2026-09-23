import Foundation

/// The nested code signing boundary of `ZynSignError`.
///
/// Maps `NestedSigningFailure` domain failures onto the application's unified
/// error surface. Preserves the failure reason and honest diagnostic category
/// while ensuring no private keys, raw signing credentials, or sensitive Keychain
/// data reach user-facing messages.
extension ZynSignError {

    /// Wraps one nested signing failure.
    static func nestedSigning(_ failure: NestedSigningFailure) -> ZynSignError {
        ZynSignError(
            category: failure.category,
            userMessage: failure.reason.userMessage,
            diagnosticDetail: failure.detail,
            nestedSigningFailure: failure.reason
        )
    }

    /// Constructs a nested signing failure from a reason and optional context.
    static func nestedSigning(
        _ reason: NestedSigningFailureReason,
        at path: BundlePath? = nil,
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        let detail: String
        if let diagnosticDetail {
            detail = diagnosticDetail
        } else if let path {
            detail = "\(reason.rawValue): \(path.rawValue)"
        } else {
            detail = reason.rawValue
        }
        return ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: detail,
            nestedSigningFailure: reason
        )
    }
}
