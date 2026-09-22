/// One imported application package as a domain concept.
///
/// An artifact records the fact of an import — which package arrived, what it
/// was called, in what lifecycle state it stands, and what examination
/// established — without holding package bytes, archive handles, storage
/// locations, or any other means of reaching content. Reading bytes,
/// extracting entries, and persisting records all happen outside the domain;
/// this value only identifies the artifact and tracks its examination.
///
/// Artifacts are immutable: examination produces a new value through
/// `examined(bundle:validation:)` rather than mutating in place, and the
/// lifecycle state is always derived from the recorded examination outcome,
/// never assigned independently.
struct IPAArtifact: Equatable, Hashable {

    /// The stable identity used to correlate this artifact with stored bytes
    /// and records across the application and infrastructure layers.
    let id: ArtifactIdentifier

    /// The lifecycle state, derived from the recorded examination.
    let state: ArtifactState

    /// The provenance label captured at import — for example the picked
    /// file's name — when one was available. An opaque display and
    /// diagnostic label only: never a path, never resolved against any
    /// filesystem or container, and never trusted for security decisions.
    let sourceFileName: String?

    /// The application bundle established by examination, when examination
    /// established one. `nil` before examination, and whenever examination
    /// found no bundle or refused to choose between several.
    let discoveredBundle: ApplicationBundle?

    /// The structural examination outcome, once examination has run.
    let validation: ValidationResult?

    /// Records a fresh import. The artifact starts unexamined: no bundle, no
    /// validation outcome, lifecycle state `imported`.
    init(id: ArtifactIdentifier = ArtifactIdentifier(), sourceFileName: String? = nil) {
        self.id = id
        self.state = .imported
        self.sourceFileName = sourceFileName
        self.discoveredBundle = nil
        self.validation = nil
    }

    /// Records the outcome of structural examination, returning the examined
    /// artifact. The new lifecycle state follows the classification —
    /// `valid` becomes `inspected`, anything else becomes `invalid` — so a
    /// recorded artifact can never claim a state its examination does not
    /// support.
    ///
    /// This performs the `imported` state transition. Re-examining an
    /// already examined artifact is outside the defined lifecycle; the
    /// derivation still applies, keeping any such value internally coherent.
    func examined(bundle: ApplicationBundle?, validation: ValidationResult) -> IPAArtifact {
        IPAArtifact(
            id: id,
            state: ArtifactState.state(following: validation.classification),
            sourceFileName: sourceFileName,
            discoveredBundle: bundle,
            validation: validation
        )
    }

    /// Whether structural examination has been recorded.
    var isExamined: Bool {
        validation != nil
    }

    /// Whether the artifact may continue into later workflow stages. Only an
    /// examined artifact with a `valid` classification proceeds; unexamined
    /// artifacts never do.
    var permitsLaterStages: Bool {
        validation?.classification.permitsLaterStages ?? false
    }

    /// The full construction path, kept private so the lifecycle state can
    /// only ever be set through the derivation in
    /// `examined(bundle:validation:)`.
    private init(
        id: ArtifactIdentifier,
        state: ArtifactState,
        sourceFileName: String?,
        discoveredBundle: ApplicationBundle?,
        validation: ValidationResult?
    ) {
        self.id = id
        self.state = state
        self.sourceFileName = sourceFileName
        self.discoveredBundle = discoveredBundle
        self.validation = validation
    }
}
