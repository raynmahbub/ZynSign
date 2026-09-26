import Foundation

/// The conclusion of one independent verification of one artifact.
///
/// A status is a statement about the bytes ZynSign just reopened and read. It
/// is not a trust evaluation, not a platform authorization, and not an
/// installation claim:
///
/// - `valid` — every check this build runs passed.
/// - `invalid` — at least one check failed. The findings say which.
/// - `warning` — every check passed, but something about the artifact
///   deserves attention (a profile near expiry, a seal that lists more
///   resources than verification read).
/// - `unsupported` — verification could not reach a conclusion: the artifact
///   is not present, its container cannot be read by this build, or part of
///   the artifact is outside the bounds verification reads. Unsupported is
///   never success, and it is never shown as one.
enum ArtifactVerificationStatus: String, Codable, CaseIterable, Hashable, Sendable {

    case valid
    case invalid
    case warning
    case unsupported

    /// The status name shown to the user.
    var displayName: String {
        switch self {
        case .valid: return "Valid"
        case .invalid: return "Invalid"
        case .warning: return "Warning"
        case .unsupported: return "Unsupported"
        }
    }

    /// What the status does and does not claim, in fixed language.
    var explanation: String {
        switch self {
        case .valid:
            return "Every check ZynSign runs passed on the artifact's own bytes. This says the artifact is internally coherent — not that it is trusted, authorized by the platform, or installable."
        case .invalid:
            return "At least one check failed on the artifact's own bytes. The findings name what was found."
        case .warning:
            return "Every check passed, but something about the artifact deserves attention."
        case .unsupported:
            return "Verification could not reach a conclusion for part of this artifact. Unsupported is not a pass."
        }
    }

    /// Whether the status means the artifact passed every check.
    var isPassing: Bool { self == .valid }

    /// Whether the status represents a definite problem.
    var isFailing: Bool { self == .invalid }

    /// Whether the status is inconclusive rather than a verdict.
    var isInconclusive: Bool { self == .unsupported }
}

/// How a finding bears on verification's conclusion.
enum ArtifactVerificationSeverity: String, Codable, CaseIterable, Hashable, Sendable {

    /// A check failed. Any error makes the report invalid.
    case error

    /// The check passed but something deserves attention. Warnings alone
    /// make the report a warning, never a failure.
    case warning

    /// The check could not be completed within this build's bounds, or the
    /// artifact is outside what this build verifies. Unsupported findings
    /// make the report unsupported unless an error is also present.
    case unsupported

    /// A check passed and the finding records what was observed.
    case note

    /// Whether the finding keeps the report from being a plain pass.
    var preventsPass: Bool { self != .note }
}

/// The stable identity of one verification finding.
///
/// Codes are persisted in the signing history and shown in the interface, so
/// they are added to and never repurposed. A detail string explains one
/// observation; the code says which observation it is.
enum ArtifactVerificationFindingCode: String, Codable, CaseIterable, Hashable, Sendable {

    /// The artifact is not present in export storage.
    case artifactUnavailable

    /// The container could not be read by this build.
    case containerUnreadable

    /// The package's structure was examined.
    case containerStructure

    /// The bundle's declared metadata was examined.
    case bundleInformation

    /// The declared executable is not a regular file inside the bundle.
    case executableMissing

    /// The executable could not be read within the verification bound.
    case executableUnreadable

    /// The executable is not a Mach-O image this build parses.
    case executableFormat

    /// The main executable's code signature was examined.
    case mainSignature

    /// The signature region could not be parsed.
    case signatureStructure

    /// The signature carries no CodeDirectory, or its identifier was checked.
    case codeDirectory

    /// The CodeDirectory's identifier disagrees with the bundle identifier.
    case codeDirectoryIdentifier

    /// The main executable's entitlements slot was examined.
    case entitlements

    /// The resource seal was examined.
    case resourceSeal

    /// A sealed resource's recorded digest disagrees with its bytes.
    case sealedResourceDigest

    /// A sealed resource could not be read.
    case sealedResourceUnreadable

    /// The seal lists more resources than verification read.
    case sealCoverage

    /// Nested code inside the bundle was examined.
    case nestedCode

    /// The embedded provisioning profile was examined.
    case embeddedProfile

    /// The embedded profile does not authorize the bundle identifier.
    case embeddedProfileIdentifier

    /// The embedded profile's validity period does not cover now.
    case embeddedProfileExpiry

    /// The embedded profile's container signature was not evaluated.
    case embeddedProfileAuthenticity

    /// Cryptographic trust was deliberately not evaluated.
    case trustNotEvaluated
}

/// One observation from one verification.
struct ArtifactVerificationFinding: Equatable, Hashable, Sendable {

    let code: ArtifactVerificationFindingCode
    let severity: ArtifactVerificationSeverity

    /// Fixed-language detail: bundle-relative locations at most. Never a key,
    /// a credential, profile content, an absolute path, or a signature's
    /// bytes.
    let detail: String

    init(code: ArtifactVerificationFindingCode, severity: ArtifactVerificationSeverity, detail: String) {
        self.code = code
        self.severity = severity
        self.detail = detail
    }

    /// The line the interface and the history record show.
    var line: String { "\(severity.displayName): \(detail)" }
}

extension ArtifactVerificationSeverity {

    /// The severity name shown to the user.
    var displayName: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .unsupported: return "Not verified"
        case .note: return "Checked"
        }
    }
}

/// The bounds verification reads within.
///
/// Verification reopens an artifact and reads it. Those reads are bounded so
/// that verifying an artifact can never expand into unbounded work, and so
/// that a bound being reached is reported as an unsupported finding rather
/// than silently skipped.
struct ArtifactVerificationLimits: Equatable, Hashable {

    /// The greatest executable size verification will read into memory.
    let maximumExecutableBytes: Int

    /// The greatest number of sealed file resources verification will
    /// re-digest.
    let maximumSealedResourceCount: Int

    /// The greatest size of one sealed resource verification will read.
    let maximumSealedResourceBytes: Int

    /// The greatest total bytes verification will read while re-digesting
    /// sealed resources.
    let maximumTotalSealedReadBytes: Int

    /// The greatest number of nested code objects verification will inspect.
    let maximumNestedCodeCount: Int

    /// The greatest embedded-profile size verification will read.
    let maximumProfileBytes: Int

    init(
        maximumExecutableBytes: Int,
        maximumSealedResourceCount: Int,
        maximumSealedResourceBytes: Int,
        maximumTotalSealedReadBytes: Int,
        maximumNestedCodeCount: Int,
        maximumProfileBytes: Int
    ) {
        self.maximumExecutableBytes = maximumExecutableBytes
        self.maximumSealedResourceCount = maximumSealedResourceCount
        self.maximumSealedResourceBytes = maximumSealedResourceBytes
        self.maximumTotalSealedReadBytes = maximumTotalSealedReadBytes
        self.maximumNestedCodeCount = maximumNestedCodeCount
        self.maximumProfileBytes = maximumProfileBytes
    }

    /// The policy verification applies unless the composition root chooses
    /// another. The numbers are conservative ceilings for an ordinary
    /// application package, not tuned measurements.
    static let `default` = ArtifactVerificationLimits(
        maximumExecutableBytes: 256 * 1_024 * 1_024,
        maximumSealedResourceCount: 512,
        maximumSealedResourceBytes: 64 * 1_024 * 1_024,
        maximumTotalSealedReadBytes: 256 * 1_024 * 1_024,
        maximumNestedCodeCount: 64,
        maximumProfileBytes: 4 * 1_024 * 1_024
    )
}

/// What one independent verification of one artifact established.
///
/// The report is produced by reopening the artifact's bytes and reading them
/// again. It shares no state with the signing run that produced the artifact,
/// and it takes nothing that run concluded on trust: presence of a signature
/// is read from the artifact, seal digests are recomputed from the artifact's
/// own files, and the embedded profile is decoded and compared against what
/// the bundle declares.
struct ArtifactVerificationReport: Equatable, Sendable {

    /// The conclusion.
    let status: ArtifactVerificationStatus

    /// Every observation, in the order the checks ran.
    let findings: [ArtifactVerificationFinding]

    /// When verification ran.
    let verifiedAt: Date

    /// The artifact's size as observed during verification, when it was
    /// present.
    let artifactByteCount: Int?

    /// How many checks ran. Reported so a report that ran few checks is
    /// distinguishable from one that ran many.
    let checksRun: Int

    init(
        status: ArtifactVerificationStatus,
        findings: [ArtifactVerificationFinding],
        verifiedAt: Date,
        artifactByteCount: Int?,
        checksRun: Int
    ) {
        self.status = status
        self.findings = findings
        self.verifiedAt = verifiedAt
        self.artifactByteCount = artifactByteCount
        self.checksRun = checksRun
    }

    /// Derives the conclusion from the findings. Errors outrank unsupported
    /// findings, which outrank warnings: a definite failure is never softened
    /// by the parts of the artifact verification could not read.
    static func derive(
        findings: [ArtifactVerificationFinding],
        verifiedAt: Date,
        artifactByteCount: Int?,
        checksRun: Int
    ) -> ArtifactVerificationReport {
        let status: ArtifactVerificationStatus
        if findings.contains(where: { $0.severity == .error }) {
            status = .invalid
        } else if findings.contains(where: { $0.severity == .unsupported }) {
            status = .unsupported
        } else if findings.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .valid
        }
        return ArtifactVerificationReport(
            status: status,
            findings: findings,
            verifiedAt: verifiedAt,
            artifactByteCount: artifactByteCount,
            checksRun: checksRun
        )
    }

    /// The findings of one severity, in order.
    func findings(of severity: ArtifactVerificationSeverity) -> [ArtifactVerificationFinding] {
        findings.filter { $0.severity == severity }
    }

    var errors: [ArtifactVerificationFinding] { findings(of: .error) }
    var warnings: [ArtifactVerificationFinding] { findings(of: .warning) }
    var unsupported: [ArtifactVerificationFinding] { findings(of: .unsupported) }
    var notes: [ArtifactVerificationFinding] { findings(of: .note) }

    /// The findings the signing history keeps: errors, warnings, and
    /// unsupported observations, each already in fixed language. Notes are
    /// dropped because "this check passed" is what the status already says.
    var recordedFindings: [String] {
        findings
            .filter { $0.severity.preventsPass }
            .map { "\($0.code.rawValue): \($0.detail)" }
    }

    /// One line summarising the counts, used by rows and by the history.
    var summary: String {
        var parts: [String] = ["\(status.displayName)"]
        if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")") }
        if !warnings.isEmpty { parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") }
        if !unsupported.isEmpty { parts.append("\(unsupported.count) not verified") }
        if parts.count == 1 { parts.append("\(checksRun) checks") }
        return parts.joined(separator: " · ")
    }
}
