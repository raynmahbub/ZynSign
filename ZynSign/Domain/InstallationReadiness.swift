import Foundation

/// One readiness check the Installation Workspace performs before presenting
/// a signed application as ready to deliver.
///
/// Every case names a fact ZynSign establishes itself, from evidence it
/// already holds — the signing journal, the export catalog, export storage,
/// and the library record. Nothing here consults the platform, predicts the
/// platform's decision, or implies that a passing report means an
/// installation will be accepted. A check with no evidence is reported as
/// *not performed* rather than guessed in either direction.
enum InstallationReadinessCheck: String, CaseIterable, Hashable, Sendable {

    /// A successful signing run exists for this application and delivered
    /// the artifact under inspection. Established from the signing journal.
    case signedArtifact

    /// The artifact's last independent verification concluded `valid`.
    /// Established from the export record's recorded verification. No
    /// verification on record blocks readiness: ZynSign verifies artifacts
    /// before presenting them as ready.
    case artifactVerification

    /// The artifact's bytes are held in export storage at the size the
    /// record captured, so the package can be read and delivered. Deep
    /// readability — container, executable, seals — is what verification
    /// establishes when it runs; this check establishes that the bytes are
    /// there to read.
    case packageReadable

    /// The export commit completed: the record carries the byte count and,
    /// for every record this build writes, a content fingerprint. A record
    /// from before fingerprints were measured still passes, with an
    /// attention note.
    case exportCompleted

    /// The signing assets behind the artifact are still current: the
    /// provisioning profile and the certificate the run recorded have not
    /// expired. Established from the dates the signing journal recorded;
    /// when the journal recorded no dates the check reports *not performed*
    /// rather than pass or fail.
    case signingAssetsCurrent

    /// The declared metadata delivery needs — an identifier, a name, and a
    /// version — is present on the record, so a manifest and an installed
    /// record can name the application without inventing values.
    case deliveryMetadata

    /// The short name the checklist row shows.
    var displayName: String {
        switch self {
        case .signedArtifact: return "Signed"
        case .artifactVerification: return "Verified"
        case .packageReadable: return "Package"
        case .exportCompleted: return "Export"
        case .signingAssetsCurrent: return "Identity"
        case .deliveryMetadata: return "Metadata"
        }
    }

    /// What the check establishes, in one fixed sentence. Used by the
    /// checklist's explanatory text and by diagnostics.
    var explanation: String {
        switch self {
        case .signedArtifact:
            return "A signing run succeeded and delivered this artifact."
        case .artifactVerification:
            return "ZynSign's independent verification passed on the artifact's own bytes."
        case .packageReadable:
            return "The artifact's bytes are held in export storage at the recorded size."
        case .exportCompleted:
            return "The export completed with a measured size and content fingerprint."
        case .signingAssetsCurrent:
            return "The profile and certificate recorded by the signing run have not expired."
        case .deliveryMetadata:
            return "The declared name, identifier, and version needed for delivery are present."
        }
    }

    /// The order the checklist presents checks in: the artifact's lifecycle,
    /// not the enum's.
    static let presentationOrder: [InstallationReadinessCheck] = [
        .signedArtifact,
        .artifactVerification,
        .packageReadable,
        .exportCompleted,
        .signingAssetsCurrent,
        .deliveryMetadata,
    ]
}

/// The outcome of one readiness check.
///
/// The states are deliberately narrow:
///
/// - `passed` — the check ran and its evidence supports readiness.
/// - `attention` — the check ran and passed, but something deserves a
///   look before delivery. Attention never blocks.
/// - `blocked` — the check ran and its evidence is against readiness.
///   Any blocked check holds the whole report back.
/// - `notPerformed` — there was no evidence to check, so ZynSign says so
///   instead of inventing a result. A not-performed verification blocks,
///   because ZynSign verifies artifacts before presenting them as ready;
///   everywhere else it is shown as an open question.
enum InstallationCheckState: Equatable, Hashable, Sendable {

    case passed
    case attention(reason: String)
    case blocked(reason: String)
    case notPerformed(reason: String)

    /// Whether the check's evidence supports readiness.
    var isPassing: Bool {
        switch self {
        case .passed, .attention: return true
        case .blocked, .notPerformed: return false
        }
    }

    /// Whether the check holds the readiness report back.
    ///
    /// No default: a state added later must decide, here, whether it blocks.
    var isBlocking: Bool {
        switch self {
        case .blocked: return true
        case .passed, .attention, .notPerformed: return false
        }
    }

    /// Whether the check could not be evaluated at all.
    var isNotPerformed: Bool {
        if case .notPerformed = self { return true }
        return false
    }

    /// The fixed-language reason attached to the state, when one exists.
    var reason: String? {
        switch self {
        case .passed: return nil
        case .attention(let reason): return reason
        case .blocked(let reason): return reason
        case .notPerformed(let reason): return reason
        }
    }

    /// The mark a checklist row shows for this state.
    var displayMark: String {
        switch self {
        case .passed: return "✓"
        case .attention: return "!"
        case .blocked: return "✕"
        case .notPerformed: return "–"
        }
    }
}

/// The evidence one readiness evaluation reads.
///
/// Every field is established elsewhere — by the signing journal, the export
/// catalog, export storage, or the library record — and passed in. Nothing
/// is inferred here, and an absent fact stays absent.
struct InstallationReadinessEvidence: Equatable, Sendable {

    /// The outcome of the signing run that produced the artifact, when the
    /// journal still holds one.
    var signingOutcome: SigningRecord.Outcome?

    /// The recorded verification conclusion, when one exists.
    var verificationStatus: ArtifactVerificationStatus?

    /// Whether the export record carries a content fingerprint.
    var fingerprintRecorded: Bool?

    /// Whether the artifact's bytes are held at the recorded size.
    var artifactAvailable: Bool?

    /// When the provisioning profile the run used expires, as recorded.
    var profileExpiresAt: Date?

    /// When the certificate the run used stops being valid, as recorded.
    var certificateExpiresAt: Date?

    /// The declared bundle identifier.
    var bundleIdentifier: String?

    /// The declared display name, when the bundle declared one.
    var displayName: String?

    /// The declared marketing version, when the bundle declared one.
    var shortVersion: String?

    /// The instant the evaluation reads expiry against. Injectable for
    /// deterministic tests.
    var now: Date

    init(
        signingOutcome: SigningRecord.Outcome? = nil,
        verificationStatus: ArtifactVerificationStatus? = nil,
        fingerprintRecorded: Bool? = nil,
        artifactAvailable: Bool? = nil,
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        shortVersion: String? = nil,
        now: Date = Date()
    ) {
        self.signingOutcome = signingOutcome
        self.verificationStatus = verificationStatus
        self.fingerprintRecorded = fingerprintRecorded
        self.artifactAvailable = artifactAvailable
        self.profileExpiresAt = profileExpiresAt
        self.certificateExpiresAt = certificateExpiresAt
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.now = now
    }
}

/// One evaluated check in a readiness report.
struct InstallationCheckOutcome: Equatable, Hashable, Identifiable, Sendable {

    /// The check that ran.
    let check: InstallationReadinessCheck

    /// What it concluded.
    let state: InstallationCheckState

    var id: InstallationReadinessCheck { check }
}

/// What readiness evaluation concluded for one signed application.
///
/// The report carries only checks ZynSign actually evaluated — a check with
/// no evidence is recorded as `notPerformed` with its reason, never dropped
/// and never turned into a pass. `isReady` answers exactly one question:
/// *may the workspace present this application as ready to deliver?* It
/// makes no claim about the platform's acceptance, which ZynSign cannot see.
struct InstallationReadinessReport: Equatable, Sendable {

    /// The checks, in presentation order.
    let outcomes: [InstallationCheckOutcome]

    /// When the evaluation ran.
    let evaluatedAt: Date

    /// Every check that ran, indexed for lookup.
    var outcomesByCheck: [InstallationReadinessCheck: InstallationCheckState] {
        Dictionary(uniqueKeysWithValues: outcomes.map { ($0.check, $0.state) })
    }

    /// The state of one check, when the report evaluated it.
    func state(of check: InstallationReadinessCheck) -> InstallationCheckState? {
        outcomes.first(where: { $0.check == check })?.state
    }

    /// Checks whose evidence is against readiness, in presentation order.
    var blockedChecks: [InstallationReadinessCheck] {
        outcomes.filter { $0.state.isBlocking }.map(\.check)
    }

    /// Checks that passed but deserve a look, in presentation order.
    var attentionChecks: [InstallationReadinessCheck] {
        outcomes.filter {
            if case .attention = $0.state { return true }
            return false
        }.map(\.check)
    }

    /// Checks that could not be evaluated, in presentation order.
    var notPerformedChecks: [InstallationReadinessCheck] {
        outcomes.filter { $0.state.isNotPerformed }.map(\.check)
    }

    /// Whether the workspace may present the application as ready to
    /// deliver. A not-performed verification holds the report back; other
    /// not-performed checks do not, because they are open questions rather
    /// than evidence against.
    var isReady: Bool { blockedChecks.isEmpty }

    /// The count of checks that ran and passed outright.
    var passedCount: Int {
        outcomes.filter { $0.state == .passed }.count
    }

    /// The one-line summary the readiness card shows.
    var summary: String {
        if isReady && attentionChecks.isEmpty && notPerformedChecks.isEmpty {
            return "Ready — all \(outcomes.count) checks passed."
        }
        if isReady {
            return "Ready, with notes — \(passedCount)/\(outcomes.count) checks passed cleanly."
        }
        let blockers = blockedChecks.map(\.displayName).joined(separator: ", ")
        return "Not ready — \(blockers) need attention."
    }

    /// The compatibility guidance the checklist shows, in fixed language.
    ///
    /// The wording is deliberate: ZynSign reports what it verified, calls
    /// the package *ready* only in ZynSign's own sense, and never implies
    /// the platform will accept the delivery.
    var guidance: [String] {
        var lines: [String] = []
        if isReady && attentionChecks.isEmpty {
            lines.append("Verification completed successfully. The package appears ready.")
        } else if isReady {
            lines.append("The package appears ready. Review the notes before continuing.")
        } else {
            lines.append("Resolve the blocked checks before delivering.")
        }
        if !notPerformedChecks.isEmpty {
            let names = notPerformedChecks.map(\.displayName).joined(separator: ", ")
            lines.append("ZynSign could not check \(names), so it makes no claim about them.")
        }
        lines.append("These checks describe ZynSign's own validation. Whether the platform accepts the delivery is the platform's decision, which ZynSign cannot see.")
        return lines
    }

    /// The readiness summary spoken to VoiceOver.
    var spokenSummary: String {
        if isReady && attentionChecks.isEmpty && notPerformedChecks.isEmpty {
            return "Ready to deliver. All \(outcomes.count) checks passed."
        }
        if isReady {
            return "Ready to deliver with \(attentionChecks.count) note\(attentionChecks.count == 1 ? "" : "s")."
        }
        return "Not ready. \(blockedChecks.count) check\(blockedChecks.count == 1 ? "" : "s") blocked: "
            + blockedChecks.map(\.displayName).joined(separator: ", ") + "."
    }

    /// Evaluates readiness from evidence.
    ///
    /// The evaluation is pure. Every check reads only the evidence it names,
    /// a check with no evidence becomes `notPerformed` with a fixed reason,
    /// and the report is assembled in presentation order.
    static func evaluate(_ evidence: InstallationReadinessEvidence) -> InstallationReadinessReport {
        var outcomes: [InstallationCheckOutcome] = []

        // Signed: the journal's run for this artifact succeeded.
        let signedState: InstallationCheckState
        switch evidence.signingOutcome {
        case .succeeded:
            signedState = .passed
        case .failed:
            signedState = .blocked(reason: "The signing run that produced this record failed.")
        case .cancelled:
            signedState = .blocked(reason: "The signing run that produced this record was cancelled.")
        case .none:
            signedState = .notPerformed(reason: "No signing run for this application is in the journal, so there is nothing to confirm.")
        }
        outcomes.append(InstallationCheckOutcome(check: .signedArtifact, state: signedState))

        // Verified: the recorded verification is a pass. No verification is
        // itself a blocker — ZynSign verifies artifacts before presenting
        // them as ready.
        let verificationState: InstallationCheckState
        switch evidence.verificationStatus {
        case .valid:
            verificationState = .passed
        case .warning:
            verificationState = .attention(reason: "Verification passed with a warning. Review the findings before delivering.")
        case .invalid:
            verificationState = .blocked(reason: "Verification concluded the artifact is invalid.")
        case .unsupported:
            verificationState = .blocked(reason: "Verification could not reach a conclusion. Unsupported is not a pass.")
        case .none:
            verificationState = .blocked(reason: "The artifact has not been verified. Run Verify Again before delivering.")
        }
        outcomes.append(InstallationCheckOutcome(check: .artifactVerification, state: verificationState))

        // Package: the bytes are held at the recorded size.
        let packageState: InstallationCheckState
        switch evidence.artifactAvailable {
        case .some(true):
            packageState = .passed
        case .some(false):
            packageState = .blocked(reason: "The artifact's bytes are not in export storage as recorded, so there is no package to deliver.")
        case .none:
            packageState = .notPerformed(reason: "Export storage was not consulted, so the package's presence is unknown.")
        }
        outcomes.append(InstallationCheckOutcome(check: .packageReadable, state: packageState))

        // Export: the commit completed with a measured size, and — for every
        // record this build writes — a fingerprint.
        let exportState: InstallationCheckState
        switch evidence.fingerprintRecorded {
        case .some(true):
            exportState = .passed
        case .some(false):
            exportState = .attention(reason: "The export predates fingerprint measurement. Its size is recorded; no fingerprint is on file.")
        case .none:
            exportState = .notPerformed(reason: "No export record was consulted, so the commit could not be confirmed.")
        }
        outcomes.append(InstallationCheckOutcome(check: .exportCompleted, state: exportState))

        // Identity: the recorded assets are current. Expired blocks; dates
        // the journal never recorded stay an open question.
        let identityState = Self.evaluateAssetExpiry(evidence)
        outcomes.append(InstallationCheckOutcome(check: .signingAssetsCurrent, state: identityState))

        // Metadata: delivery needs an identifier, a name, and a version.
        let metadataState = Self.evaluateMetadata(evidence)
        outcomes.append(InstallationCheckOutcome(check: .deliveryMetadata, state: metadataState))

        return InstallationReadinessReport(
            outcomes: outcomes,
            evaluatedAt: evidence.now
        )
    }

    private static func evaluateAssetExpiry(_ evidence: InstallationReadinessEvidence) -> InstallationCheckState {
        let dates = [evidence.profileExpiresAt, evidence.certificateExpiresAt].compactMap { $0 }
        guard !dates.isEmpty else {
            return .notPerformed(reason: "The signing run recorded no expiry dates, so currency cannot be checked.")
        }
        guard let expired = dates.first(where: { $0 <= evidence.now }) else {
            return .passed
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return .blocked(reason: "A signing asset expired on \(formatter.string(from: expired)). The signed output stops launching after expiry, so delivering it now is not useful.")
    }

    private static func evaluateMetadata(_ evidence: InstallationReadinessEvidence) -> InstallationCheckState {
        guard let identifier = evidence.bundleIdentifier, !identifier.isEmpty else {
            return .blocked(reason: "The package declares no bundle identifier, so delivery cannot name it.")
        }
        let nameIsPresent = evidence.displayName.map { !$0.isEmpty } ?? false
        let versionIsPresent = evidence.shortVersion.map { !$0.isEmpty } ?? false
        if nameIsPresent && versionIsPresent {
            return .passed
        }
        var missing: [String] = []
        if !nameIsPresent { missing.append("a display name") }
        if !versionIsPresent { missing.append("a version") }
        return .attention(reason: "The package declares no \(missing.joined(separator: " or ")). Delivery fills a standard value, but the installed record will be less specific.")
    }
}
