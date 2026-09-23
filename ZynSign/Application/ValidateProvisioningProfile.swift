import Foundation

// MARK: - Stage vocabulary

/// The stages one integrated provisioning-profile validation runs, in order.
///
/// The order is the security order, not a convenience ordering: the container is
/// verified before its payload is parsed, the payload is parsed before it is
/// structurally validated, and no policy rule is asked about a payload the CMS
/// boundary did not authenticate. Each stage keeps the boundary that owns it —
/// ZS-018 for the container and the certificate evidence, ZS-017 for parsing and
/// structural validation, ZS-019 for policy — and this enumeration only names
/// them so a caller can see how far a run got.
enum ProvisioningProfilePipelineStage: String, CaseIterable, Equatable, Hashable {

    /// Whether a profile was obtained at all: no profile, an unreadable entry,
    /// or bytes handed to the pipeline.
    case profileInput

    /// The CMS boundary's evidence about the container.
    case cmsVerification

    /// Whether the authenticated payload was parsed into typed metadata.
    case profileParsing

    /// Whether the parsed profile satisfied the structural validator.
    case structuralValidation

    /// Whether the container yielded a signer certificate.
    case signerCertificate

    /// How the signer certificate, the profile's own certificate references,
    /// and the locally listed identities correspond.
    case certificateRelationship

    /// The application, identity, and configuration policy evaluation.
    case policyValidation

    /// A human-readable stage name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .profileInput: return "Profile input"
        case .cmsVerification: return "CMS verification"
        case .profileParsing: return "Profile parsing"
        case .structuralValidation: return "Structural validation"
        case .signerCertificate: return "Signer certificate"
        case .certificateRelationship: return "Certificate relationship"
        case .policyValidation: return "Policy validation"
        }
    }
}

/// What one stage of the pipeline established.
///
/// Four states, because "the stage did not run" and "the stage ran and could not
/// decide" are different facts, and neither is a pass or a failure:
///
/// - `passed` — the stage's own condition was established to hold;
/// - `failed` — the stage established that its condition does not hold, or met
///   input it can classify as structurally broken;
/// - `indeterminate` — the stage ran, or could not run because this build or the
///   input does not permit it, and no conclusion was reached;
/// - `notAttempted` — an earlier stage left this stage nothing to work on.
enum ProvisioningProfilePipelineStageOutcome: String, CaseIterable, Equatable, Hashable {
    case passed
    case failed
    case indeterminate
    case notAttempted

    /// A human-readable outcome name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .indeterminate: return "Indeterminate"
        case .notAttempted: return "Not attempted"
        }
    }
}

/// How far one aggregated finding bears on the integrated status.
///
/// The severities map mechanically onto the failure vocabularies the stages
/// already use — `ZynSignError.category`, `CMSSignatureVerificationStatus`,
/// `ValidationSeverity`, and `ProvisioningPolicyStatus` — and add no rule of
/// their own. That is deliberate: an integration layer that re-judged a stage's
/// outcome would be a second, subtly different validator.
enum ProvisioningProfilePipelineFindingSeverity: String, CaseIterable, Equatable, Hashable {

    /// The stage established that its condition does not hold.
    case rejected

    /// The input is coherent but uses a container form or profile format
    /// ZynSign deliberately does not support. This is not a defect in the
    /// input and not a rejection of it.
    case unsupported

    /// The stage could not establish its condition: unavailable mechanism,
    /// missing context, an unevaluated question, or a non-rejecting observation.
    case unresolved
}

/// One aggregated observation from one stage.
///
/// `code` is the raw value of the *stage's own* code vocabulary — `CMSFailure`
/// for the container, `ProvisioningProfileFailure` for the profile input and
/// payload, `ProvisioningProfileValidationIssueCode` for structural validation,
/// `ProvisioningPolicyFindingCode` for policy, and
/// `ProvisioningProfilePipelineAcquisitionFailure` for acquisition. A boundary's
/// failure vocabulary stays its own, so the pipeline does not mint a fourth
/// vocabulary that could drift from the three it reports on; a caller switches
/// on `stage` and reads the stage's typed code from the evidence the result also
/// carries. `detail` is already-redacted text: a stage name, a state, a bounded
/// count, or the sentence the stage itself wrote. It never carries profile
/// bytes, payload bytes, certificate bodies, entitlement values, identifiers,
/// keys, or credentials.
struct ProvisioningProfilePipelineFinding: Equatable, Hashable {

    /// The stage that produced this observation.
    let stage: ProvisioningProfilePipelineStage

    /// How the observation bears on the integrated status.
    let severity: ProvisioningProfilePipelineFindingSeverity

    /// The stage's own machine-readable code, as its raw value.
    let code: String

    /// Technical diagnostic context, written under the redaction rules.
    let detail: String
}

/// Why a profile that was looked for could not be turned into pipeline input.
///
/// Each case names a different fact about reading, and none of them is a claim
/// about a profile: a package the library no longer holds, a container that
/// cannot be enumerated, and a bundle with two application directories say
/// nothing about whether some profile is valid, and are never reported as if
/// they did.
enum ProvisioningProfilePipelineAcquisitionFailure: String, CaseIterable, Equatable, Hashable {

    /// The library holds no package for the record, or the package it holds is
    /// no longer the one the record vouches for.
    case artifactUnavailable

    /// The container could not be opened or enumerated.
    case containerUnreadable

    /// The container records no single application bundle to look inside.
    case applicationBundleAbsent

    /// The container records more than one application bundle, so no single
    /// embedded profile can be attributed to one of them.
    case applicationBundleAmbiguous

    /// The bundle records the profile entry, but not as a regular file.
    case entryNotRegularFile

    /// The entry exists but its content could not be produced — it is damaged,
    /// stored in a form the reader does not support, or larger than the bound
    /// ZynSign reads within. ZynSign refuses rather than truncates, so the two
    /// are reported the same way and neither is a claim about the profile.
    case entryUnreadable

    /// A statement of what this failure does and does not say. Safe to present:
    /// it names no location, no package, and no profile content.
    var explanation: String {
        switch self {
        case .artifactUnavailable:
            return "The library no longer holds the package this record refers to, so no embedded profile could be read from it."
        case .containerUnreadable:
            return "The package container could not be read, so no embedded profile entry could be located."
        case .applicationBundleAbsent:
            return "The package records no single application bundle, so there was no bundle root to look for an embedded profile in."
        case .applicationBundleAmbiguous:
            return "The package records more than one application bundle, so an embedded profile could not be attributed to one of them."
        case .entryNotRegularFile:
            return "The bundle records an entry at the embedded-profile location that is not a regular file, so it was not read."
        case .entryUnreadable:
            return "The embedded-profile entry could not be read within ZynSign's read bound, and ZynSign refuses to read part of a file."
        }
    }
}

// MARK: - Request

/// How the profile a pipeline run validated reached the pipeline.
///
/// Recorded so that a result can state what it was about without any caller
/// bookkeeping: bytes a caller supplied and bytes read out of an application
/// bundle are the same work for the stages and different facts for a reader.
enum ProvisioningProfilePipelineOrigin: String, CaseIterable, Equatable, Hashable {

    /// The caller supplied exact bytes: a controlled local artifact, an
    /// extracted file it read itself, or a test fixture.
    case supplied

    /// The bytes came from an application bundle's `embedded.mobileprovision`
    /// entry, as read by `BundleProvisioningProfileIntake`.
    case embeddedBundleEntry
}

/// Why a profile could not be obtained, or how many bytes were.
///
/// The three states are the ones a caller must not be able to confuse: "no
/// profile is there", "a profile is there and could not be read", and "these are
/// its bytes" are different answers, and only the third lets the pipeline run.
/// A byte count is recorded instead of the bytes, because this value is a record
/// of the input, not a carrier of it.
enum ProvisioningProfilePipelineAcquisition: Equatable, Hashable {

    /// Neither a supplied profile nor an embedded profile entry was present.
    /// An App Store package legitimately carries no embedded profile, so this
    /// is the absence of an input and not a verdict on an application.
    case notFound

    /// A profile entry was looked for and could not be turned into input.
    case unusable(ProvisioningProfilePipelineAcquisitionFailure)

    /// The exact number of bytes presented for validation. Zero is a real
    /// reading — an empty file — and is classified by the input bound rather
    /// than by this value.
    case bytesRead(byteCount: Int)
}

/// The profile one pipeline run validates.
///
/// This is the seam where an artifact and a profile meet. The bytes are untrusted
/// and bounded downstream by the existing profile-input policy; they are never
/// written, executed, or persisted by anything here.
enum ProvisioningProfilePipelineProfile: Equatable, Hashable {

    /// No profile was supplied, and none was found where one was expected.
    case notFound

    /// A profile entry was discovered and could not be read.
    case unusable(ProvisioningProfilePipelineAcquisitionFailure)

    /// The exact bytes of one profile, as presented by the caller.
    case bytes(Data)

    /// What the pipeline can record about this profile before any stage ran.
    var acquisition: ProvisioningProfilePipelineAcquisition {
        switch self {
        case .notFound:
            return .notFound
        case .unusable(let failure):
            return .unusable(failure)
        case .bytes(let bytes):
            return .bytesRead(byteCount: bytes.count)
        }
    }
}

/// What a caller must supply for one integrated provisioning-profile validation.
///
/// Every field is evidence that already exists elsewhere: the profile's bytes or
/// the reason there are none, what the application declares, the identifier being
/// validated, a signing-identity identifier, a requested configuration, and
/// whatever device and platform context the caller established.
///
/// What the request cannot carry: private-key bytes, a key reference, a Keychain
/// record, a password, a PKCS#12 payload, raw CMS content, a file handle, or a
/// storage location. A signing identity enters only as the opaque
/// `SigningIdentityIdentifier` ZS-016 established, and the pipeline reads that
/// identity's metadata through the identity store and nothing else.
struct ValidateProvisioningProfileRequest: Equatable, Hashable {

    /// The profile to validate, or the reason there is none to validate.
    let profile: ProvisioningProfilePipelineProfile

    /// How the profile reached the pipeline.
    let profileOrigin: ProvisioningProfilePipelineOrigin

    /// What the application declares about itself, when it is known.
    let applicationMetadata: ApplicationMetadata?

    /// The bundle identifier being validated, when it differs from the
    /// identifier the application's metadata declares.
    let bundleIdentifier: BundleIdentifier?

    /// The identity to evaluate, when the caller has one. Its metadata is
    /// resolved read-only; no signing capability is ever requested.
    let signingIdentityID: SigningIdentityIdentifier?

    /// What the caller intends to sign with: claimed entitlements, the debugging
    /// preference, and the intended profile class.
    let signingConfiguration: SigningConfiguration

    /// What the caller knows about the device this validation concerns.
    let deviceContext: ProvisioningDeviceContext

    /// The platforms the application is intended for, when the caller
    /// established them explicitly.
    let intendedPlatforms: [ProvisioningProfilePlatform]?

    init(
        profile: ProvisioningProfilePipelineProfile,
        profileOrigin: ProvisioningProfilePipelineOrigin = .supplied,
        applicationMetadata: ApplicationMetadata? = nil,
        bundleIdentifier: BundleIdentifier? = nil,
        signingIdentityID: SigningIdentityIdentifier? = nil,
        signingConfiguration: SigningConfiguration = SigningConfiguration(),
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil
    ) {
        self.profile = profile
        self.profileOrigin = profileOrigin
        self.applicationMetadata = applicationMetadata
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentityID = signingIdentityID
        self.signingConfiguration = signingConfiguration
        self.deviceContext = deviceContext
        self.intendedPlatforms = intendedPlatforms
    }
}

// MARK: - Result

/// The outcome the integrated pipeline assigns to one validation.
///
/// Four states, and each has a rule that can be checked rather than assumed:
///
/// 1. `invalid` — at least one finding is `.rejected`: the container's signature
///    did not verify, the container is not a profile ZynSign can read at all,
///    the authenticated payload is structurally broken, or a policy rule was
///    violated.
/// 2. `unsupported` — nothing was rejected, and at least one finding is
///    `.unsupported`: the input is coherent but uses a container form, a
///    profile payload format, or a declared algorithm ZynSign deliberately does
///    not handle. This is the same distinction
///    `ValidationClassification.unsupported` and
///    `DiagnosticCategory.unsupportedInput` already draw; it is not used for a
///    capability this build lacks, which stays `indeterminate`.
/// 3. `valid` — every stage whose outcome the pipeline requires passed, and the
///    policy evaluation returned `compatible`. Because `compatible` requires
///    that every policy category be satisfied, an unavailable device identity,
///    an unattempted trust evaluation, or an unanswered entitlement question makes
///    a run `valid` impossible rather than silently acceptable, and a stage
///    reported `indeterminate` or `notAttempted` can never be read as a pass.
/// 4. `indeterminate` — otherwise: no definite incompatibility was established
///    and at least one required check could not be completed. This includes "no
///    profile was found", because the absence of an input decides nothing about
///    an application.
///
/// `valid` is the last thing this pipeline can say, and it says only that the
/// stages ZynSign implements reached their positive outcomes. It is not
/// installation, not platform acceptance, not certificate trust, not a
/// signature, and not Apple's approval: trust stays `notPerformed` and
/// authorization stays `notEvaluated` on every path here.
enum ProvisioningProfilePipelineStatus: String, CaseIterable, Equatable, Hashable {
    case valid
    case invalid
    case indeterminate
    case unsupported

    /// Whether every stage passed and the policy evaluation was compatible. This
    /// is never a statement about a device, an installation, or the platform.
    var isFullyEstablished: Bool { self == .valid }

    /// A human-readable status name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .valid: return "Valid"
        case .invalid: return "Invalid"
        case .indeterminate: return "Indeterminate"
        case .unsupported: return "Unsupported"
        }
    }
}

/// What one integrated validation was given, recorded before any stage ran.
struct ProvisioningProfilePipelineInputState: Equatable, Hashable {

    /// Where the profile came from.
    let origin: ProvisioningProfilePipelineOrigin

    /// Whether bytes were obtained, and how many; or why they were not.
    let acquisition: ProvisioningProfilePipelineAcquisition

    /// Whether a profile was present enough to be read.
    var isProfileDiscovered: Bool {
        if case .bytesRead = acquisition { return true }
        return false
    }

    /// The number of bytes presented for validation, when any were.
    var byteCount: Int? {
        if case .bytesRead(let byteCount) = acquisition { return byteCount }
        return nil
    }
}

/// The integrated result of validating one provisioning profile against one
/// application and signing context.
///
/// The result exposes the stages independently and carries the evidence each
/// stage produced, rather than summarising it:
///
/// - what was given — `input`;
/// - parsing — `verification?.parsingState` and `profile`;
/// - structural validation — `verification?.inspection?.validation`;
/// - CMS authentication — `verification?.cms` and `authenticity`;
/// - signer certificate and relationship — `certificateRelationship` and the
///   `signerCertificatePresent`, `profileCertificateReferencePresent`,
///   `certificateCorrespondence`, `signingIdentityRelationship`, and
///   `signingIdentityKeyAvailability` views onto it;
/// - policy — `policy` with its nine per-category statuses;
/// - aggregation — `outcomes`, `findings`, and `overallStatus`.
///
/// There is deliberately no `isValid`, `isTrusted`, `isInstallable`, or
/// `isSigned` flag, and no field here can be set by a caller: the whole value is
/// derived in one run.
struct ProvisioningProfilePipelineResult: Equatable, Hashable {

    /// What the pipeline was given, and what it could do with it.
    let input: ProvisioningProfilePipelineInputState

    /// The outcome of every stage. A stage absent from the dictionary was not
    /// reached and reads as `notAttempted`.
    let outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome]

    /// The container, parsing, structural, and certificate evidence, when the
    /// profile input reached the container boundary and the boundary answered.
    /// `nil` exactly when there was no input to verify, when the input could not
    /// be read, or when the boundary stopped with a typed failure and so returned
    /// no evidence object.
    let verification: ProvisioningProfileVerification?

    /// The policy evaluation, when there was staged container evidence for it to
    /// read. `nil` means no policy rule was applied at all, which is a different
    /// fact from "every category was indeterminate".
    let policy: ProvisioningPolicyValidationResult?

    /// Every meaningful observation, in stage order, with the code the stage
    /// itself used.
    let findings: [ProvisioningProfilePipelineFinding]

    /// The integrated status, computed from the rules on
    /// `ProvisioningProfilePipelineStatus`.
    let overallStatus: ProvisioningProfilePipelineStatus

    init(
        input: ProvisioningProfilePipelineInputState,
        outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome],
        verification: ProvisioningProfileVerification?,
        policy: ProvisioningPolicyValidationResult?,
        findings: [ProvisioningProfilePipelineFinding],
        overallStatus: ProvisioningProfilePipelineStatus
    ) {
        self.input = input
        self.outcomes = outcomes
        self.verification = verification
        self.policy = policy
        self.findings = findings
        self.overallStatus = overallStatus
    }

    // MARK: Stage access

    /// The outcome of one stage.
    func outcome(for stage: ProvisioningProfilePipelineStage) -> ProvisioningProfilePipelineStageOutcome {
        outcomes[stage] ?? .notAttempted
    }

    /// Every stage and its outcome, in pipeline order.
    var stageOutcomes: [(stage: ProvisioningProfilePipelineStage, outcome: ProvisioningProfilePipelineStageOutcome)] {
        ProvisioningProfilePipelineStage.allCases.map { ($0, outcome(for: $0)) }
    }

    /// The findings that establish a definite failure.
    var rejections: [ProvisioningProfilePipelineFinding] {
        findings.filter { $0.severity == .rejected }
    }

    /// The findings that record input outside ZynSign's supported capability.
    var unsupportedFindings: [ProvisioningProfilePipelineFinding] {
        findings.filter { $0.severity == .unsupported }
    }

    /// The findings whose questions stayed open.
    var unresolvedFindings: [ProvisioningProfilePipelineFinding] {
        findings.filter { $0.severity == .unresolved }
    }

    // MARK: Evidence views

    /// The parsed profile, when the authenticated payload was parsed.
    var profile: ProvisioningProfile? { verification?.profile }

    /// The container evidence, when the boundary answered.
    var cms: CMSVerificationResult? { verification?.cms }

    /// The parsed profile's structural result, when there was a parsed profile.
    var structuralValidation: ProvisioningProfileValidation? { verification?.inspection?.validation }

    /// The signer, profile, and local-identity certificate relationships.
    var certificateRelationship: ProvisioningProfileCertificateRelationship? {
        verification?.certificateRelationship
    }

    /// Whether a profile's payload is cryptographically authenticated. Distinct
    /// from being discovered, parsed, structurally valid, trusted, or authorized.
    var authenticity: ProvisioningProfileAuthenticityStatus? { verification?.authenticity }

    /// The signer certificate's fingerprint, when one was extracted.
    var signerFingerprint: CertificateFingerprint? { verification?.signerFingerprint }

    /// The instant the policy validity rule was evaluated at, when policy ran.
    var evaluationDate: Date? { policy?.evaluationDate }

    /// Trust evaluation state. Always `notPerformed` on this path.
    var trustEvaluation: CMSTrustEvaluationStatus { verification?.trustEvaluation ?? .notPerformed }

    /// Platform authorization state. Always `notEvaluated` on this path.
    var authorization: ProvisioningProfileAuthorizationStatus { verification?.authorization ?? .notEvaluated }

    /// Whether a profile was discovered well enough to be handed to the stages.
    var isProfileDiscovered: Bool { input.isProfileDiscovered }

    /// Whether the authenticated payload was parsed into typed metadata.
    var isProfileParsed: Bool { verification?.isParsed == true }

    /// Whether the parsed profile satisfied the structural validator.
    var isStructurallyValid: Bool { verification?.isStructurallyValid == true }

    /// Whether the parsed profile's validity period contains the evaluation
    /// instant. A period fact, not a trust fact.
    var isProfileWithinValidityPeriod: Bool { verification?.isCurrentlyValid == true }

    /// Whether the CMS signature verified. Authentication, not trust, not
    /// authorization, not compatibility.
    var isProfileAuthenticated: Bool { verification?.isCMSAuthenticated == true }

    /// Whether the policy evaluation found the configuration compatible with
    /// ZynSign's implemented rules.
    var isPolicyCompatible: Bool { policy?.overall.isCompatible == true }

    // MARK: Certificate facts

    /// Whether the container yielded a signer certificate.
    var signerCertificatePresent: Bool? { certificateRelationship?.signerCertificatePresent }

    /// Whether the parsed profile carries certificate references of its own.
    var profileCertificateReferencePresent: Bool? { certificateRelationship?.profileCertificateReferencePresent }

    /// Whether the signer certificate is one the profile names. `nil` when the
    /// comparison was never made, because there was no evidence to compare.
    var certificateCorrespondence: CertificateMatchOutcome? { certificateRelationship?.match }

    /// How the locally listed signing identities relate to the profile's
    /// certificate set, as the CMS boundary established it.
    var signingIdentityRelationship: LocalSigningIdentityRelationship? {
        certificateRelationship?.localSigningIdentity
    }

    /// The private-key availability reported for the one identity whose
    /// certificate the profile names, when exactly one did. A report about a
    /// capability, never a signature and never key bytes.
    var signingIdentityKeyAvailability: SigningKeyAvailability? {
        certificateRelationship?.localSigningIdentityKeyAvailability
    }

    // MARK: Diagnostics

    /// A redacted diagnostic rendering of the whole run: the integrated status,
    /// every stage's outcome, the stages' own renderings, and the codes of the
    /// findings that were not clean. It inherits the redaction rules of the
    /// renderings it composes — states, outcomes, codes, bounded counts, and
    /// fingerprints — and adds no identifiers, values, or bytes of its own.
    var diagnosticDescription: String {
        var parts: [String] = ["pipeline.status(\(overallStatus.rawValue))"]
        for stage in ProvisioningProfilePipelineStage.allCases {
            parts.append("pipeline.stage.\(stage.rawValue)(\(outcome(for: stage).rawValue))")
        }
        parts.append("pipeline.input(\(input.origin.rawValue) \(acquisitionText))")
        for finding in findings {
            parts.append("pipeline.finding(\(finding.stage.rawValue) \(finding.code) \(finding.severity.rawValue))")
        }
        if let verification { parts.append(verification.diagnosticDescription) }
        if let policy { parts.append(policy.diagnosticDescription) }
        return parts.joined(separator: " ")
    }

    private var acquisitionText: String {
        switch input.acquisition {
        case .notFound: return "notFound"
        case .unusable(let failure): return "unusable(\(failure.rawValue))"
        case .bytesRead(let byteCount): return "bytes(\(byteCount))"
        }
    }

    /// The presentation-safe rendering of this result.
    var summary: ProvisioningProfilePipelineSummary {
        ProvisioningProfilePipelineSummary(
            profileOrigin: input.origin,
            profileDiscovered: isProfileDiscovered,
            profileAuthenticated: isProfileAuthenticated,
            profileParsed: isProfileParsed,
            structurallyValid: isStructurallyValid,
            profileWithinValidityPeriod: isProfileWithinValidityPeriod,
            cmsSignatureStatus: cms?.status,
            signerCertificatePresent: signerCertificatePresent ?? false,
            certificateCorrespondence: certificateCorrespondence ?? .notEvaluated,
            signingIdentityRelationship: signingIdentityRelationship ?? .notEvaluated,
            policyCompatibility: policy?.overall ?? .indeterminate,
            policyWasEvaluated: policy != nil,
            trustEvaluation: trustEvaluation,
            authorization: authorization,
            overallStatus: overallStatus,
            reasons: findings.compactMap { finding in
                // A non-rejecting structural observation is recorded on the result
                // and in the diagnostics; it is not a reason a caller needs in
                // order to act on the outcome, so the summary leaves it out.
                if finding.severity == .unresolved, finding.stage == .structuralValidation { return nil }
                return ProvisioningProfilePipelineReason(finding: finding)
            }
        )
    }
}

/// One safe, non-sensitive reason behind an integrated status.
///
/// The shape a screen would render: the stage, the severity, the stage's code,
/// and one already-redacted sentence. It carries no identifiers, no certificate
/// bodies, no entitlement values, no profile bytes, and no keys, and it names no
/// action: nothing here signs, re-signs, installs, generates, or modifies a
/// profile.
struct ProvisioningProfilePipelineReason: Equatable, Hashable {

    let stage: ProvisioningProfilePipelineStage
    let severity: ProvisioningProfilePipelineFindingSeverity
    let code: String
    let text: String

    init(finding: ProvisioningProfilePipelineFinding) {
        self.stage = finding.stage
        self.severity = finding.severity
        self.code = finding.code
        self.text = finding.detail
    }
}

/// A presentation-safe rendering of one integrated provisioning-profile
/// validation.
///
/// Every state a caller might otherwise infer from another is stated here
/// separately, so that "a profile was found" cannot be rendered as "a profile
/// was verified" and a verified container cannot be rendered as a compatible
/// configuration. No field is an action.
struct ProvisioningProfilePipelineSummary: Equatable, Hashable {

    /// Where the profile came from.
    let profileOrigin: ProvisioningProfilePipelineOrigin

    /// Whether a profile was present and read well enough to be validated.
    let profileDiscovered: Bool

    /// Whether the container's CMS signature verified for the payload.
    let profileAuthenticated: Bool

    /// Whether the authenticated payload was parsed into typed metadata.
    let profileParsed: Bool

    /// Whether the parsed profile satisfied the structural validator.
    let structurallyValid: Bool

    /// Whether the profile's validity period contains the evaluation instant.
    let profileWithinValidityPeriod: Bool

    /// The CMS signature outcome, when the boundary answered.
    let cmsSignatureStatus: CMSSignatureVerificationStatus?

    /// Whether a signer certificate was obtained from the container.
    let signerCertificatePresent: Bool

    /// Whether the signer certificate is one the profile names.
    let certificateCorrespondence: CertificateMatchOutcome

    /// How the locally listed identities relate to the profile's certificates.
    let signingIdentityRelationship: LocalSigningIdentityRelationship

    /// The policy outcome. `indeterminate` when policy never ran, which
    /// `policyWasEvaluated` distinguishes.
    let policyCompatibility: ProvisioningPolicyOutcome

    /// Whether a policy evaluation was performed at all.
    let policyWasEvaluated: Bool

    /// Trust evaluation state. Always `notPerformed` on this path.
    let trustEvaluation: CMSTrustEvaluationStatus

    /// Platform authorization state. Always `notEvaluated` on this path.
    let authorization: ProvisioningProfileAuthorizationStatus

    /// The integrated status.
    let overallStatus: ProvisioningProfilePipelineStatus

    /// The reasons behind every finding that was neither clean nor a merely
    /// informational structural observation, in stage order.
    let reasons: [ProvisioningProfilePipelineReason]
}

// MARK: - Use case

/// Validates a provisioning profile against an application, a signing identity,
/// and a requested signing configuration, in one pass through the stages ZynSign
/// implements.
///
/// This is the integration layer and nothing more. It sequences stages that
/// already exist and owns no rule of its own:
///
///     Profile bytes (supplied, or read from an application bundle)
///             ↓
///     ProvisioningProfileVerificationUseCase          (ZS-018)
///         CMS verification → authenticated payload
///             ↓
///         ProvisioningProfileParser + Validator        (ZS-017)
///             ↓
///         CertificateRelationshipAnalyzer             (ZS-018)
///             ↓
///     ValidateProvisioningConfigurationUseCase
///         → ProvisioningPolicyValidator                 (ZS-019)
///             ↓
///     ProvisioningProfilePipelineResult
///
/// What it never does: read ASN.1 or CMS structures, verify a signature, parse a
/// profile, compare certificates, compare entitlements, match a bundle
/// identifier, evaluate a certificate chain, request a signing capability, sign,
/// repackage, install, mutate any input, or persist anything. Every one of those
/// belongs to the stage named above, and each stage stays independently testable
/// because this type adds no logic to any of them.
///
/// The security order is the sequence itself, and it is not configurable here:
/// the existing container boundary parses a payload only after its signature
/// verified, so this path never parses an untrusted container and never hands an
/// unauthenticated payload to a policy rule. Where a stage cannot run, the run
/// records `notAttempted` or `indeterminate` rather than filling the gap.
struct ValidateProvisioningProfileUseCase {

    private let profileVerification: ProvisioningProfileVerificationUseCase
    private let configurationValidation: ValidateProvisioningConfigurationUseCase

    init(
        profileVerification: ProvisioningProfileVerificationUseCase,
        configurationValidation: ValidateProvisioningConfigurationUseCase
    ) {
        self.profileVerification = profileVerification
        self.configurationValidation = configurationValidation
    }

    /// Runs the pipeline once over one request.
    ///
    /// A profile that is absent, unreadable, empty, malformed, unparsable,
    /// unauthenticated, expired, or incompatible is a returned result, never a
    /// thrown error: each of those is a fact about the input that a caller must be
    /// able to distinguish, and all of them arrive with the stage's own code
    /// attached. Only a failure no stage can classify reaches the caller as an
    /// error, so that an unexpected internal condition is never dressed up as a
    /// verdict about a profile.
    ///
    /// - Parameter request: The profile, application, identity, and configuration
    ///   context to validate. Nothing in it is mutated, and none of it is
    ///   persisted.
    /// - Throws: `CancellationError`, or a typed `ZynSignError` that belongs to no
    ///   stage vocabulary — an internal condition the pipeline must not report as
    ///   a conclusion about the profile.
    /// - Returns: The staged result. Every stage's own evidence stays reachable on
    ///   it, and the integrated status follows the documented rules rather than
    ///   any single stage's outcome.
    func validate(_ request: ValidateProvisioningProfileRequest) throws -> ProvisioningProfilePipelineResult {
        let input = ProvisioningProfilePipelineInputState(
            origin: request.profileOrigin,
            acquisition: request.profile.acquisition
        )

        let bytes: Data
        switch request.profile {
        case .notFound:
            return Self.withoutProfile(
                input: input,
                finding: ProvisioningProfilePipelineFinding(
                    stage: .profileInput,
                    severity: .unresolved,
                    code: ProvisioningProfilePipelineFindingCode.profileNotFound,
                    detail: "No provisioning profile was supplied, and none was recorded where one was expected. Nothing about an application's profile compatibility can be concluded from an absent input; a distributed application is documented to carry no embedded profile at all."
                )
            )
        case .unusable(let failure):
            return Self.withoutProfile(
                input: input,
                finding: ProvisioningProfilePipelineFinding(
                    stage: .profileInput,
                    severity: .unresolved,
                    code: failure.rawValue,
                    detail: failure.explanation
                )
            )
        case .bytes(let profileBytes):
            bytes = profileBytes
        }

        let outcome: ContainerRunOutcome
        do {
            outcome = .verified(try profileVerification.verify(ProvisioningProfileInput(bytes: bytes)))
        } catch let error as ZynSignError {
            guard let classified = Self.classify(error) else { throw error }
            outcome = .stopped(classified)
        } catch {
            throw error
        }

        switch outcome {
        case .stopped(let stopped):
            return ProvisioningProfilePipelineResult(
                input: input,
                outcomes: stopped.outcomes,
                verification: nil,
                policy: nil,
                findings: stopped.findings,
                overallStatus: Self.status(
                    outcomes: stopped.outcomes,
                    findings: stopped.findings,
                    policy: nil
                )
            )
        case .verified(let verification):
            let policy = configurationValidation.validate(
                ValidateProvisioningConfigurationRequest(
                    verification: verification,
                    applicationMetadata: request.applicationMetadata,
                    bundleIdentifier: request.bundleIdentifier,
                    signingIdentityID: request.signingIdentityID,
                    signingConfiguration: request.signingConfiguration,
                    deviceContext: request.deviceContext,
                    intendedPlatforms: request.intendedPlatforms
                )
            )
            // The findings need no reordering: the evidence findings are built in
            // stage order and the policy findings extend that order, so the list
            // reads as the pipeline ran.
            var outcomes = Self.outcomes(for: verification)
            var findings = Self.findings(for: verification)
            outcomes[.policyValidation] = Self.policyOutcome(for: policy)
            findings += Self.policyFindings(for: policy)
            return ProvisioningProfilePipelineResult(
                input: input,
                outcomes: outcomes,
                verification: verification,
                policy: policy,
                findings: findings,
                overallStatus: Self.status(
                    outcomes: outcomes,
                    findings: findings,
                    policy: policy
                )
            )
        }
    }

    // MARK: Container run

    /// Every stage reported as not reached, for a run that stopped before the
    /// container boundary ran.
    private static func unreachedOutcomes() -> [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome] {
        var outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome] = [:]
        for stage in ProvisioningProfilePipelineStage.allCases {
            outcomes[stage] = .notAttempted
        }
        return outcomes
    }

    /// A result for a run that never received a profile to validate. No stage
    /// below acquisition has anything to report, and the integrated status comes
    /// from the same rules every other run is judged by rather than from a value
    /// assigned here.
    private static func withoutProfile(
        input: ProvisioningProfilePipelineInputState,
        finding: ProvisioningProfilePipelineFinding
    ) -> ProvisioningProfilePipelineResult {
        var outcomes = unreachedOutcomes()
        outcomes[.profileInput] = .indeterminate
        return ProvisioningProfilePipelineResult(
            input: input,
            outcomes: outcomes,
            verification: nil,
            policy: nil,
            findings: [finding],
            overallStatus: Self.status(
                outcomes: outcomes,
                findings: [finding],
                policy: nil
            )
        )
    }

    /// One container attempt: staged evidence, or the typed reason a stage
    /// stopped with none.
    private enum ContainerRunOutcome {
        case verified(ProvisioningProfileVerification)
        case stopped(StoppedRun)
    }

    private struct StoppedRun {
        let outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome]
        let findings: [ProvisioningProfilePipelineFinding]
    }

    /// Attributes a typed failure to the stage that owns its vocabulary and
    /// derives both the stage's outcome and the finding from the failure's own
    /// reason. The pipeline adds no judgement of its own: `invalidInput` is what
    /// a stage reported as broken input, `unsupportedInput` is what a stage
    /// reported as outside supported capability, and every other category leaves
    /// the question open.
    private static func classify(_ error: ZynSignError) -> StoppedRun? {
        let code: String
        let stage: ProvisioningProfilePipelineStage
        if let failure = error.provisioningProfileFailure {
            code = failure.rawValue
            stage = (failure == .emptyInput || failure == .inputTooLarge) ? .profileInput : .profileParsing
        } else if let failure = error.cmsFailure {
            code = failure.rawValue
            stage = .cmsVerification
        } else {
            return nil
        }

        let severity: ProvisioningProfilePipelineFindingSeverity
        switch error.category {
        case .invalidInput:
            severity = .rejected
        case .unsupportedInput:
            severity = .unsupported
        case .ambiguousInput, .capabilityUnavailable, .storageFailure, .internalFailure, .cancelled:
            severity = .unresolved
        }

        let stageOutcome: ProvisioningProfilePipelineStageOutcome = severity == .rejected ? .failed : .indeterminate
        var outcomes = Self.unreachedOutcomes()
        outcomes[.profileInput] = stage == .profileInput ? stageOutcome : .passed
        switch stage {
        case .cmsVerification:
            outcomes[.cmsVerification] = stageOutcome
        case .profileParsing:
            // The boundary returned no evidence object for this input, so nothing
            // downstream of it has anything to report on: authenticity stays
            // unevidenced rather than being inferred from a parse failure.
            outcomes[.cmsVerification] = .indeterminate
            outcomes[.profileParsing] = stageOutcome
        default:
            break
        }

        var findings: [ProvisioningProfilePipelineFinding] = []
        if stage == .profileParsing {
            // Recorded first, because the container precedes the payload in the
            // pipeline's own order.
            findings.append(
                ProvisioningProfilePipelineFinding(
                    stage: .cmsVerification,
                    severity: .unresolved,
                    code: ProvisioningProfilePipelineFindingCode.containerEvidenceUnavailable,
                    detail: "The container boundary returned no verification evidence for this input, because the failure was recorded at the profile payload stage. The absence of evidence is reported instead of a conclusion."
                )
            )
        }
        findings.append(
            ProvisioningProfilePipelineFinding(
                stage: stage,
                severity: severity,
                code: code,
                detail: error.userMessage
            )
        )
        return StoppedRun(outcomes: outcomes, findings: findings)
    }

    // MARK: Evidence mapping

    /// The stage outcomes the staged evidence supports. Every state is read off
    /// the evidence the stages produced, so a run that parsed nothing cannot
    /// report a structural outcome and an unverified container cannot report a
    /// policy conclusion.
    private static func outcomes(
        for verification: ProvisioningProfileVerification
    ) -> [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome] {
        var outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome] = [:]
        outcomes[.profileInput] = .passed
        outcomes[.cmsVerification] = cmsOutcome(for: verification)
        outcomes[.profileParsing] = verification.parsingState == .parsed ? .passed : .notAttempted
        if let classification = verification.inspection?.validation.classification {
            switch classification {
            case .valid: outcomes[.structuralValidation] = .passed
            case .invalid: outcomes[.structuralValidation] = .failed
            case .unsupported, .ambiguous: outcomes[.structuralValidation] = .indeterminate
            }
        } else {
            outcomes[.structuralValidation] = .notAttempted
        }
        outcomes[.signerCertificate] = signerOutcome(for: verification.cms.signerCertificateStatus)
        outcomes[.certificateRelationship] = relationshipOutcome(for: verification.certificateRelationship.match)
        return outcomes
    }

    private static func cmsOutcome(
        for verification: ProvisioningProfileVerification
    ) -> ProvisioningProfilePipelineStageOutcome {
        let status = verification.cms.status
        if status.isVerified { return .passed }
        if status.isRejection { return .failed }
        return .indeterminate
    }

    private static func signerOutcome(
        for status: CMSSignerCertificateStatus
    ) -> ProvisioningProfilePipelineStageOutcome {
        switch status {
        case .extracted: return .passed
        case .notSought: return .notAttempted
        case .absentFromMessage, .ambiguous, .unparsable, .identifierNotMatchable: return .indeterminate
        }
    }

    private static func relationshipOutcome(
        for match: CertificateMatchOutcome
    ) -> ProvisioningProfilePipelineStageOutcome {
        switch match {
        case .matched: return .passed
        case .mismatched: return .failed
        case .notEvaluated, .ambiguous, .incomparable: return .indeterminate
        }
    }

    private static func policyOutcome(
        for policy: ProvisioningPolicyValidationResult
    ) -> ProvisioningProfilePipelineStageOutcome {
        switch policy.overall {
        case .compatible: return .passed
        case .incompatible: return .failed
        case .indeterminate: return .indeterminate
        }
    }

    /// The findings the staged evidence supports. Each one carries the code its
    /// own stage used — the CMS status, the structural issue code, or the policy
    /// finding code — so nothing here re-decides what a stage decided.
    private static func findings(
        for verification: ProvisioningProfileVerification
    ) -> [ProvisioningProfilePipelineFinding] {
        var findings: [ProvisioningProfilePipelineFinding] = []

        let status = verification.cms.status
        if !status.isVerified {
            let severity: ProvisioningProfilePipelineFindingSeverity
            if status.isRejection {
                severity = .rejected
            } else if status == .unsupportedAlgorithm {
                severity = .unsupported
            } else {
                severity = .unresolved
            }
            let detail: String
            if let failureDetail = verification.cms.failureDetail {
                detail = "\(ProvisioningProfilePipelineFindingText.cms(status)): \(failureDetail)"
            } else {
                detail = ProvisioningProfilePipelineFindingText.cms(status)
            }
            findings.append(
                ProvisioningProfilePipelineFinding(
                    stage: .cmsVerification,
                    severity: severity,
                    code: status.rawValue,
                    detail: detail
                )
            )
        }

        if verification.parsingState != .parsed {
            findings.append(
                ProvisioningProfilePipelineFinding(
                    stage: .profileParsing,
                    severity: .unresolved,
                    code: ProvisioningProfilePipelineFindingCode.payloadNotParsed,
                    detail: "The authenticated payload was not parsed into profile metadata, because the container boundary did not verify this container. Parsing is not attempted for an unverified container, so no unauthenticated profile metadata exists to report on."
                )
            )
        }

        if let validation = verification.inspection?.validation {
            for finding in validation.findings {
                findings.append(
                    ProvisioningProfilePipelineFinding(
                        stage: .structuralValidation,
                        severity: finding.severity == .error ? .rejected : .unresolved,
                        code: finding.code.rawValue,
                        detail: finding.detail
                    )
                )
            }
        }

        switch verification.cms.signerCertificateStatus {
        case .extracted:
            break
        case .notSought:
            break
        default:
            findings.append(
                ProvisioningProfilePipelineFinding(
                    stage: .signerCertificate,
                    severity: .unresolved,
                    code: verification.cms.signerCertificateStatus.rawValue,
                    detail: "No signer certificate was obtained from the container, so the certificate questions that depend on one stayed open. This is a statement about the container, not about the profile's contents."
                )
            )
        }

        let relationship = verification.certificateRelationship
        if relationship.match != .matched {
            findings.append(
                ProvisioningProfilePipelineFinding(
                    stage: .certificateRelationship,
                    severity: .unresolved,
                    code: relationship.match.rawValue,
                    detail: ProvisioningProfilePipelineFindingText.relationship(relationship.match)
                )
            )
        }

        return findings
    }

    private static func policyFindings(
        for policy: ProvisioningPolicyValidationResult
    ) -> [ProvisioningProfilePipelineFinding] {
        policy.findings.compactMap { finding in
            guard finding.status != .satisfied else { return nil }
            return ProvisioningProfilePipelineFinding(
                stage: .policyValidation,
                severity: finding.status == .violated ? .rejected : .unresolved,
                code: finding.code.rawValue,
                detail: finding.detail
            )
        }
    }

    /// The stages whose positive outcome the integrated status requires.
    ///
    /// `certificateRelationship` is deliberately absent. The correspondence
    /// between the container's signer certificate and the certificate references
    /// the profile itself names is ZS-018 evidence, and ZS-019 records a mismatch
    /// as an open question in its certificate category rather than as a
    /// violation — because a profile whose container was signed by an issuer the
    /// profile does not list among its developer certificates is the ordinary
    /// shape of a real profile. Promoting that observation into `invalid` here
    /// would re-decide a policy question the domain owns, and it could not
    /// silently produce a `valid` either: a mismatch makes the policy certificate
    /// category indeterminate, and a `valid` status requires a compatible policy
    /// evaluation.
    static let requiredStages: [ProvisioningProfilePipelineStage] = [
        .profileInput,
        .cmsVerification,
        .profileParsing,
        .structuralValidation,
        .signerCertificate,
        .policyValidation,
    ]

    /// The integrated status, computed by the rules documented on
    /// `ProvisioningProfilePipelineStatus`. A non-rejecting structural
    /// observation does not by itself deny a run whose required stages all
    /// passed and whose policy evaluation was compatible; every other unresolved
    /// question does, because it keeps a required stage from reporting `passed`.
    static func status(
        outcomes: [ProvisioningProfilePipelineStage: ProvisioningProfilePipelineStageOutcome],
        findings: [ProvisioningProfilePipelineFinding],
        policy: ProvisioningPolicyValidationResult?
    ) -> ProvisioningProfilePipelineStatus {
        if findings.contains(where: { $0.severity == .rejected }) { return .invalid }
        if findings.contains(where: { $0.severity == .unsupported }) { return .unsupported }
        let everythingRequiredPassed = requiredStages.allSatisfy {
            (outcomes[$0] ?? .notAttempted) == .passed
        }
        if everythingRequiredPassed, let policy, policy.overall == .compatible { return .valid }
        return .indeterminate
    }
}

/// The codes the integration layer itself uses, for the two states no stage has
/// a code for: an input that was never there, and evidence a stage could not
/// hand back. Everything else is reported under the stage's own vocabulary.
enum ProvisioningProfilePipelineFindingCode {

    /// Neither a supplied profile nor an embedded profile entry was present.
    static let profileNotFound = "profileNotFound"

    /// The container boundary produced no evidence object to read states from.
    static let containerEvidenceUnavailable = "containerEvidenceUnavailable"

    /// The authenticated payload was never parsed.
    static let payloadNotParsed = "payloadNotParsed"
}

/// Fixed, redacted wording for the two states whose stages carry no message of
/// their own.
enum ProvisioningProfilePipelineFindingText {

    static func cms(_ status: CMSSignatureVerificationStatus) -> String {
        switch status {
        case .verified:
            return "The container's CMS signature verified."
        case .invalid:
            return "The container's CMS signature did not verify, or its signed attributes do not bind the encapsulated payload."
        case .noSigner:
            return "The container carries no signer, so its signature could not be related to any key."
        case .multipleSigners:
            return "The container carries more than one signer, and ZynSign does not choose one."
        case .signerCertificateUnavailable:
            return "No embedded certificate could be related to the signer, so no signature check was attempted."
        case .unsupportedAlgorithm:
            return "The container declares a digest and signature pair ZynSign does not map onto a verification operation. Both identifiers are preserved by the container stage."
        case .unavailable:
            return "No signature-verification mechanism is composed for this build or platform, so authenticity could not be established. This is a capability this build lacks, not a defect in the profile."
        case .verificationFailed:
            return "The verification operation reported an unexpected failure, so no cryptographic conclusion was reached."
        }
    }

    static func relationship(_ match: CertificateMatchOutcome) -> String {
        switch match {
        case .notEvaluated:
            return "No comparison between the signer certificate and the profile's certificates was made, because one of the two sides does not exist."
        case .matched:
            return "The container's signer certificate is one of the certificates the profile names."
        case .mismatched:
            return "The container's signer certificate is not one of the certificates the profile names. The container stage records this as an observation about correspondence and authenticity remains its own finding, so the policy stage treats it as an open question rather than a rejection."
        case .ambiguous:
            return "More than one embedded certificate could be the signer, so no single comparison is meaningful."
        case .incomparable:
            return "A signer certificate exists but the profile offers nothing comparable, so correspondence was neither established nor denied."
        }
    }
}

// MARK: - Bundle integration

/// Reads the one `embedded.mobileprovision` entry of a library application's
/// bundle and hands its bytes to the provisioning-profile pipeline.
///
/// This is the artifact half of the integration and nothing else. It reuses the
/// boundaries the package workflow already owns — the library entry's recorded
/// artifact availability, the `ArtifactArchiveReaderProvider` the composition root
/// selected, the container's own entry table, `ApplicationBundleDiscovery`, and
/// `IPALayout.embeddedProvisioningProfileFileName` — and introduces no second
/// reader, no second store, and no second path vocabulary. It reads at most one
/// entry, within one bound, and never extracts, writes, hashes, or parses any
/// file, never opens the container for anything but its entry table and that one
/// entry, and never reads a profile's contents to decide whether one is there.
///
/// It reaches no conclusion. It reports that an entry is recorded at the
/// conventional location and what its bytes are; whether those bytes are a
/// profile, whether they are authenticated, and whether they suit an
/// application are the pipeline's questions, and this type cannot answer them.
/// A record whose artifact is missing or no longer matches the record is reported
/// as unreadable input rather than opened anyway, because the library can no
/// longer vouch for the bytes.
struct BundleProvisioningProfileIntake {

    private let readerProvider: any ArtifactArchiveReaderProvider
    private let limits: ArchiveLimits

    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.readerProvider = readerProvider
        self.limits = limits
    }

    /// The largest profile entry this intake will ask a reader to produce.
    ///
    /// It is the tighter of the archive's own inspection-read bound and the
    /// profile input bound, so a read never succeeds by producing bytes the
    /// profile pipeline would refuse to retain.
    var maximumReadBytes: Int {
        min(limits.maximumInspectionReadBytes, ProvisioningProfileInput.maximumByteCount)
    }

    /// The profile embedded in the bundle of the application this entry records.
    ///
    /// The reader is closed on every path, and exactly one entry's content is
    /// ever requested. A container that cannot be opened or enumerated, a
    /// package with no single application bundle, an entry that is not a regular
    /// file, and an entry whose content cannot be produced within the read bound
    /// each come back as `unusable` with the reason; a bundle that records no
    /// profile at the conventional location comes back as `notFound`. None of
    /// them is reported as a defective profile, because none of them says
    /// anything about a profile.
    func profile(in entry: LibraryEntry) -> ProvisioningProfilePipelineProfile {
        guard entry.isArtifactAvailable else {
            return .unusable(.artifactUnavailable)
        }

        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: entry.record.artifact.artifactID)
        } catch {
            return .unusable(.containerUnreadable)
        }
        defer { reader.close() }

        let entryTable: [ArchiveEntry]
        do {
            entryTable = try reader.readEntryTable()
        } catch {
            return .unusable(.containerUnreadable)
        }

        // Ambiguity is not resolved by choosing a candidate, so a package with
        // more than one primary bundle has no bundle root to look inside.
        let bundlePath: ArchivePath
        switch ApplicationBundleDiscovery.discover(in: entryTable).outcome {
        case .exactlyOne(let discovered):
            bundlePath = discovered
        case .ambiguous(_):
            return .unusable(.applicationBundleAmbiguous)
        case .missingPayloadDirectory, .none:
            return .unusable(.applicationBundleAbsent)
        }

        guard let profilePath = bundlePath.appending(component: IPALayout.embeddedProvisioningProfileFileName) else {
            return .unusable(.containerUnreadable)
        }

        let kind: ArchiveEntryKind?
        do {
            kind = try reader.entryKind(at: profilePath)
        } catch {
            return .unusable(.containerUnreadable)
        }
        switch kind {
        case .none:
            return .notFound
        case .some(.regularFile):
            break
        case .some:
            return .unusable(.entryNotRegularFile)
        }

        let bytes: Data
        do {
            bytes = try reader.readEntryData(at: profilePath, maximumBytes: maximumReadBytes)
        } catch {
            return .unusable(.entryUnreadable)
        }
        return .bytes(bytes)
    }
}

// MARK: - Request convenience

extension ValidateProvisioningProfileRequest {

    /// A request for the profile embedded in the bundle of one library entry,
    /// together with the application context the caller has established.
    ///
    /// The profile side comes from the intake's reading; nothing here infers a
    /// profile state from the entry's presence. A caller that has no application
    /// metadata, no identity, and no configuration asks the profile's own
    /// questions only, and the stages that need the rest report them as open.
    static func embedded(
        in entry: LibraryEntry,
        intake: BundleProvisioningProfileIntake,
        bundleIdentifier: BundleIdentifier? = nil,
        signingIdentityID: SigningIdentityIdentifier? = nil,
        signingConfiguration: SigningConfiguration = SigningConfiguration(),
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil
    ) -> ValidateProvisioningProfileRequest {
        ValidateProvisioningProfileRequest(
            profile: intake.profile(in: entry),
            profileOrigin: .embeddedBundleEntry,
            applicationMetadata: nil,
            bundleIdentifier: bundleIdentifier,
            signingIdentityID: signingIdentityID,
            signingConfiguration: signingConfiguration,
            deviceContext: deviceContext,
            intendedPlatforms: intendedPlatforms
        )
    }
}
