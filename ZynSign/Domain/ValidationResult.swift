/// The outcome of structural examination of one artifact.
///
/// A validation result classifies the artifact and carries the findings
/// behind that classification. Its scope is structural only: archive
/// readability, path safety, application-bundle presence, and basic metadata
/// shape. Signature validity, certificate and profile trust, entitlement
/// authorization, and platform acceptance are separate future evaluations
/// with their own result types — this type never speaks for them, and a
/// `valid` result must never be read as signed, trusted, or installable.
///
/// Consistency expectations, upheld by the factories below and checkable
/// through `isConsistent`:
/// - a `valid` result carries no error findings;
/// - a rejecting result (`invalid`, `unsupported`, `ambiguous`) carries at
///   least one error finding.
///
/// The expectations are checked rather than enforced at construction because
/// findings are assembled incrementally while examination runs.
struct ValidationResult: Equatable, Hashable {

    /// The classification assigned to the examined artifact.
    let classification: ValidationClassification

    /// The findings behind the classification, in examination order.
    let findings: [ValidationFinding]

    /// Records an examination outcome directly.
    init(classification: ValidationClassification, findings: [ValidationFinding] = []) {
        self.classification = classification
        self.findings = findings
    }

    /// A clean structural pass with no findings.
    static func valid() -> ValidationResult {
        ValidationResult(classification: .valid, findings: [])
    }

    /// A structural pass with non-rejecting observations. The findings are
    /// expected to be warnings; anything else is detectable through
    /// `isConsistent`.
    static func validWithWarnings(findings: [ValidationFinding]) -> ValidationResult {
        ValidationResult(classification: .valid, findings: findings)
    }

    /// A structural failure with the findings behind it.
    static func invalid(findings: [ValidationFinding]) -> ValidationResult {
        ValidationResult(classification: .invalid, findings: findings)
    }

    /// A structurally coherent artifact outside deliberately supported
    /// capability, with the findings behind it.
    static func unsupported(findings: [ValidationFinding]) -> ValidationResult {
        ValidationResult(classification: .unsupported, findings: findings)
    }

    /// An examination that could not safely choose one interpretation, with
    /// the findings behind it.
    static func ambiguous(findings: [ValidationFinding]) -> ValidationResult {
        ValidationResult(classification: .ambiguous, findings: findings)
    }

    /// Whether the examined artifact passed every rule that was checked.
    var isValid: Bool {
        classification == .valid
    }

    /// The rejecting findings, in examination order.
    var errors: [ValidationFinding] {
        findings.filter { $0.severity == .error }
    }

    /// The non-rejecting findings, in examination order.
    var warnings: [ValidationFinding] {
        findings.filter { $0.severity == .warning }
    }

    /// Whether the classification and the findings agree: a `valid` result
    /// carries no errors, and a rejecting result carries at least one.
    var isConsistent: Bool {
        if classification == .valid {
            return errors.isEmpty
        }
        return !errors.isEmpty
    }
}
