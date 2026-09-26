/// The category of a failure, kept separate from any message text.
///
/// Categories are the stable, programmatically usable part of an error:
/// presentation and diagnostics read the category first, then the messages.
/// The set distinguishes, at minimum, the failure kinds the architecture
/// requires, including the honest distinction between input that is at fault
/// and a capability that ZynSign cannot provide on this platform or in this
/// build.
enum DiagnosticCategory: String, CaseIterable, Hashable, CustomStringConvertible, Codable, Sendable {

    /// Input is structurally broken or malformed.
    case invalidInput

    /// Input is coherent but falls outside deliberately supported capability.
    case unsupportedInput

    /// Input admits more than one safe interpretation.
    case ambiguousInput

    /// A capability is not available on this platform or in this build.
    /// Reported as unavailable, not as a defect in the user's input.
    case capabilityUnavailable

    /// The user cancelled the operation.
    case cancelled

    /// Storage or another finite resource failed or ran out.
    case storageFailure

    /// An unexpected internal condition.
    case internalFailure

    var description: String { rawValue }
}
