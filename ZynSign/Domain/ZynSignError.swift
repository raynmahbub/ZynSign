import Foundation

/// ZynSign's structured error type.
///
/// Design rules, following the architecture:
///
/// - Failures are typed and categorized, never reduced to free-form strings.
/// - `userMessage` is written to be shown directly to the user. It contains no
///   diagnostic detail and nothing from the wrapped cause, so a platform or
///   parse error cannot leak into user-facing text.
/// - `diagnosticDetail` carries technical context for logs and reports. It is
///   still written by callers, so callers remain responsible for the
///   redaction rules: no key material, credentials, profile bodies, or user
///   data may be placed in it.
/// - `underlyingError` preserves the cause for diagnosis. It appears only in
///   the debug rendering, never in the user-facing message.
struct ZynSignError: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {

    /// The stable category of the failure.
    let category: DiagnosticCategory

    /// A user-presentable explanation, free of sensitive and technical detail.
    let userMessage: String

    /// Technical context for diagnostics, if any.
    let diagnosticDetail: String?

    /// The preserved underlying cause, if any.
    let underlyingError: (any Error)?

    init(
        category: DiagnosticCategory,
        userMessage: String,
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) {
        self.category = category
        self.userMessage = userMessage
        self.diagnosticDetail = diagnosticDetail
        self.underlyingError = underlyingError
    }

    /// The user-presentable message.
    var errorDescription: String? { userMessage }

    /// A short, log-safe summary: category plus the user message. Excludes
    /// diagnostic detail and the underlying cause.
    var description: String {
        "zynsign.error(\(category)): \(userMessage)"
    }

    /// The full diagnostic rendering: category, detail, and underlying cause.
    /// Use for diagnostics only — never show this to the user, and only write
    /// it where the redaction rules permit.
    var debugDescription: String {
        var parts = ["zynsign.error(\(category))"]
        if let diagnosticDetail {
            parts.append("detail: \(diagnosticDetail)")
        }
        if let underlyingError {
            parts.append("cause: \(String(describing: underlyingError))")
        }
        return parts.joined(separator: " | ")
    }
}
