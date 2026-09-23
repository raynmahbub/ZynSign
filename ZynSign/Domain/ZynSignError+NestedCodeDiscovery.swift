import Foundation

/// The nested-code discovery boundary of `ZynSignError`.
///
/// Discovery's own failure type is `NestedCodeDiscoveryError`: a value the
/// domain builds and tests without any error-surface machinery, in terms of
/// which the rule that rejects a bundle is written. This extension is the
/// single place where that value becomes the application's error surface, so
/// the mapping is total, deliberate, and testable.
///
/// Two properties are preserved by the mapping.
///
/// **The reason survives.** `nestedCodeFailure` carries it, so a caller that
/// needs to distinguish "this binary is not Mach-O" from "this bundle's
/// dependency graph contains a cycle" reads the reason rather than the
/// message. The category follows the reason: an ambiguous executable is
/// `ambiguousInput`, a binary form this build does not model and a resource
/// policy bound are `unsupportedInput`, and every other reason is
/// `invalidInput`, because every one of them describes the application bundle
/// rather than a defect in ZynSign or in this platform.
///
/// **Nothing else leaks.** The user message is the reason's own message and
/// nothing more. The bundle-relative location that the failure names stays
/// inside `diagnosticDetail` — the domain writes it into the detail text
/// rather than into a field, and it is written for logs and reports, subject
/// to the redaction rules. No underlying cause is carried at all: a foreign
/// error's text is not evidence about the application and must not reach the
/// user.
extension ZynSignError {

    /// Wraps one nested-code discovery failure.
    static func nestedCodeDiscovery(_ error: NestedCodeDiscoveryError) -> ZynSignError {
        ZynSignError(
            category: error.reason.category,
            userMessage: error.reason.userMessage,
            diagnosticDetail: error.detail,
            nestedCodeFailure: error.reason
        )
    }
}
