/// The severity of one validation finding.
///
/// Errors reject the artifact under examination: an artifact with any error
/// finding must not continue into later workflow stages. Warnings record
/// observations that deserve attention but do not by themselves reject the
/// artifact.
enum ValidationSeverity: String, CaseIterable, Hashable {

    /// A rejecting observation.
    case error

    /// A non-rejecting observation.
    case warning

    /// Whether a finding at this severity rejects the artifact under
    /// examination.
    var rejectsArtifact: Bool {
        self == .error
    }
}
