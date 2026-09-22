/// The outcome classification ZynSign assigns when it evaluates a package or
/// one of its parts.
///
/// Evaluation results are classified rather than collapsed into a single
/// undifferentiated error, so that "broken", "outside deliberately supported
/// capability", and "not safely decidable" stay distinct outcomes with
/// distinct remedies.
enum ValidationClassification: String, CaseIterable, Hashable {

    /// The evaluated input satisfied every rule that was checked.
    case valid

    /// A required structural or metadata condition is definitively broken.
    case invalid

    /// The input may be structurally coherent but falls outside deliberately
    /// supported capability.
    case unsupported

    /// Inspection cannot safely choose one interpretation. Ambiguous input is
    /// never resolved silently.
    case ambiguous

    /// Whether this classification may continue into later workflow stages.
    /// Only a `valid` outcome proceeds; ambiguous input must not be carried
    /// forward on the strength of a guess.
    var permitsLaterStages: Bool {
        self == .valid
    }

    /// A human-readable classification name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .valid: return "Valid"
        case .invalid: return "Invalid"
        case .unsupported: return "Unsupported"
        case .ambiguous: return "Ambiguous"
        }
    }
}
