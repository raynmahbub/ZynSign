/// One structural observation produced while examining an artifact.
///
/// A finding records what was observed, where, and how severely — never a
/// user-facing instruction. `detail` is technical diagnostic context written
/// for logs and reports; callers remain responsible for the redaction rules
/// (no key material, credentials, profile bodies, device identifiers, or
/// user data). User-facing wording is composed by the presentation layer
/// from the code and severity, not stored here.
struct ValidationFinding: Equatable, Hashable {

    /// How severely this observation bears on the artifact under examination.
    let severity: ValidationSeverity

    /// The machine-readable identity of the observation.
    let code: ValidationIssueCode

    /// Technical diagnostic context. Always present; callers keep it
    /// log-safe under the redaction rules.
    let detail: String

    /// The archive entry the finding concerns, when it concerns exactly one.
    /// `nil` means the finding concerns the artifact as a whole.
    let location: ArchivePath?

    /// Records one observation about the examined artifact.
    init(
        severity: ValidationSeverity,
        code: ValidationIssueCode,
        detail: String,
        location: ArchivePath? = nil
    ) {
        self.severity = severity
        self.code = code
        self.detail = detail
        self.location = location
    }

    /// Whether this finding by itself rejects the artifact under examination.
    var isRejecting: Bool {
        severity.rejectsArtifact
    }

    /// The diagnostic category derived from the issue code.
    var category: DiagnosticCategory {
        code.category
    }
}
