/// The lifecycle state of one imported artifact, as far as this build takes it.
///
/// The model is deliberately minimal: an artifact is recorded, structurally
/// examined, and — when it establishes a bundle — its declared metadata is
/// examined. Each examination either confirms or rejects the artifact.
/// States for later workflow stages — signing readiness, signed output,
/// verification outcomes — do not exist yet because those stages do not exist
/// yet; they must not be anticipated here ahead of the work that defines
/// them.
///
/// A workflow stage (`WorkflowStage`) is a pipeline position; an artifact
/// state is where one imported package stands in its own lifecycle. The two
/// vocabularies stay separate.
enum ArtifactState: String, CaseIterable, Hashable {

    /// The artifact was recorded and has not been examined yet.
    case imported

    /// Structural examination completed and the artifact passed every rule
    /// that was checked. Says nothing about signatures, trust, or
    /// installability, which are separate future evaluations. The metadata
    /// examination pass may still confirm or reject the artifact.
    case inspected

    /// Examination determined the artifact cannot proceed: structural rules
    /// were not satisfied, or the bundle's declared metadata failed
    /// validation. The reasons are carried by the recorded validation
    /// result, not by this state.
    case invalid

    /// Whether the state is terminal in this build: no onward transition is
    /// defined. A structurally inspected artifact may still undergo the
    /// metadata examination pass — which can confirm it or reject it — so
    /// only a rejected artifact is terminal.
    var isTerminal: Bool {
        self == .invalid
    }

    /// Whether the lifecycle permits moving from this state to `target`.
    /// Structural examination of a freshly imported artifact reports
    /// `inspected` or `invalid`; the metadata examination pass over an
    /// inspected artifact reports `inspected` when the declared metadata
    /// passed and `invalid` when it did not.
    func canTransition(to target: ArtifactState) -> Bool {
        switch (self, target) {
        case (.imported, .inspected), (.imported, .invalid),
             (.inspected, .inspected), (.inspected, .invalid):
            return true
        default:
            return false
        }
    }

    /// The lifecycle state that follows a structural examination with the
    /// given classification: `valid` becomes `inspected`, anything else
    /// becomes `invalid`. This is the single derivation behind recorded
    /// examination outcomes.
    static func state(following classification: ValidationClassification) -> ArtifactState {
        classification == .valid ? .inspected : .invalid
    }

    /// A human-readable state name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .imported: return "Imported"
        case .inspected: return "Inspected"
        case .invalid: return "Invalid"
        }
    }
}
