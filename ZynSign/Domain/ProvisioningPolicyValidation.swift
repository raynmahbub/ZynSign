import Foundation

/// The status of one policy rule or one policy category.
///
/// Three states, not two: a rule that could not be evaluated must not be
/// reported as satisfying the policy, and it must not be reported as a
/// violation either.
enum ProvisioningPolicyStatus: String, CaseIterable, Equatable, Hashable {

    /// The rule that applied was satisfied.
    case satisfied

    /// The rule that applied was violated.
    case violated

    /// The rule could not be applied, or no rule applied at all, so the
    /// question stays open.
    case indeterminate

    /// Whether this status rejects the configuration.
    var isViolation: Bool { self == .violated }

    /// Whether this status alone would permit continuing to the next stage.
    var isSatisfied: Bool { self == .satisfied }

    /// A human-readable name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .satisfied: return "Satisfied"
        case .violated: return "Violated"
        case .indeterminate: return "Indeterminate"
        }
    }
}

/// The overall outcome of one policy evaluation.
enum ProvisioningPolicyOutcome: String, CaseIterable, Equatable, Hashable {

    /// Every category was satisfied.
    case compatible

    /// At least one category was violated.
    case incompatible

    /// Nothing was violated, and at least one category could not be decided.
    case indeterminate

    /// Whether every category was satisfied.
    var isCompatible: Bool { self == .compatible }

    /// A human-readable name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .compatible: return "Compatible"
        case .incompatible: return "Incompatible"
        case .indeterminate: return "Indeterminate"
        }
    }
}

/// One area of policy the validator decides.
///
/// The categories are independent: the validator evaluates every applicable
/// one and reports all of them, so a profile that is simultaneously expired,
/// mismatched, and certificate-less produces three findings rather than the
/// first one.
enum ProvisioningPolicyCategory: String, CaseIterable, Equatable, Hashable {

    /// Whether the payload the profile was parsed from is cryptographically
    /// authenticated. Policy rules are not applied to an unauthenticated
    /// payload.
    case profileAuthenticity

    /// Whether the profile's creation/expiration interval contains the
    /// evaluation instant.
    case profileValidity

    /// Which profile class the observed field combination establishes, and
    /// whether it is the class the caller intends.
    case profileType

    /// Whether the profile's application identifier covers the application's
    /// bundle identifier.
    case bundleIdentifier

    /// Whether the profile's team identifier, the requested team claim, and the
    /// signing identity's certificate agree.
    case teamIdentifier

    /// Whether a signing identity's certificate is one the profile names, and
    /// whether that identity has a usable signing capability.
    case certificate

    /// Whether the requested entitlement claims are within the profile's
    /// allowlist, including the specially handled claims.
    case entitlements

    /// Whether the profile declares a platform the application is intended for.
    case platform

    /// Whether the profile's device restriction, where it has one, covers the
    /// device this evaluation concerns.
    case device

    /// A human-readable name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .profileAuthenticity: return "Profile authenticity"
        case .profileValidity: return "Profile validity"
        case .profileType: return "Profile type"
        case .bundleIdentifier: return "Bundle identifier"
        case .teamIdentifier: return "Team identifier"
        case .certificate: return "Certificate"
        case .entitlements: return "Entitlements"
        case .platform: return "Platform"
        case .device: return "Device"
        }
    }
}

/// The machine-readable identity of one policy finding.
///
/// Codes are the stable part of a finding; presentation reads the code first
/// and the category second, and wording is composed outside the domain.
enum ProvisioningPolicyFindingCode: String, CaseIterable, Equatable, Hashable {

    // MARK: Authenticity

    case profileAuthenticated
    case profileAuthenticityRejected
    case profileAuthenticityNotEvaluated
    case profileNotParsed

    // MARK: Profile validity

    case profileWithinValidityPeriod
    case profileExpired
    case profileNotYetValid
    case profileDatesMalformed
    case profileDatesMissing

    // MARK: Profile classification

    case profileClassEstablished
    case profileClassUnknown
    case profileClassMismatch
    case profileClassIntentNotEstablished

    // MARK: Bundle identifier

    case bundleIdentifierExactMatch
    case bundleIdentifierWildcardMatch
    case bundleIdentifierMismatch
    case bundleIdentifierNotComparable
    case applicationBundleIdentifierMissing
    case profileApplicationIdentifierMissing

    // MARK: Team identifier

    case profileTeamIdentifierPresent
    case profileTeamIdentifierMissing
    case teamIdentifierClaimMatched
    case teamIdentifierClaimMismatch
    case teamIdentifierClaimNotComparable
    case teamIdentifierIdentityMatched
    case teamIdentifierIdentityMismatch
    case teamIdentifierIdentityNotEstablished

    // MARK: Certificate

    case profileCarriesCertificateReferences
    case profileCarriesNoCertificateReferences
    case profileCertificateMetadataUnavailable
    case profileCertificateFingerprintsUnavailable
    case containerSignerMatchesProfileCertificate
    case containerSignerNotProfileCertificate
    case containerSignerNotEvaluated
    case signingIdentityNotProvided
    case signingIdentityNoneAvailable
    case signingIdentityLookupFailed
    case signingIdentityCertificateMatched
    case signingIdentityCertificateMismatch
    case signingIdentityUsableForSigning
    case signingKeyUnavailable
    case signingKeyAssociationNotEstablished
    case signingCapabilityNotReady

    // MARK: Entitlements

    case requestedEntitlementsNotEstablished
    case entitlementAuthorized
    case entitlementNotAuthorized
    case entitlementValueConflict
    case entitlementValueNotComparable
    case entitlementValueUnsupported
    case profileIdentifierEntitlementMissing
    case profileIdentifierEntitlementConsistent
    case profileIdentifierEntitlementInconsistent
    case profileIdentifierEntitlementNotComparable
    case applicationIdentifierClaimMatched
    case applicationIdentifierClaimMismatch
    case applicationIdentifierClaimNotComparable
    case applicationIdentifierDoesNotDescribeApplication

    // MARK: get-task-allow

    case getTaskAllowMatched
    case getTaskAllowNotAuthorized
    case getTaskAllowAbsentFromProfile
    case getTaskAllowValueNotEstablished
    case getTaskAllowNotComparable
    case getTaskAllowConfigurationAmbiguous

    // MARK: Platform

    case platformSupported
    case platformNotSupported
    case platformNotDeclared
    case applicationPlatformNotEstablished
    case platformNotComparable

    // MARK: Device

    case deviceRestrictionAbsent
    case deviceProvisioned
    case deviceNotProvisioned
    case deviceContextUnavailable
    case deviceRestrictionInconsistent
}

/// One policy observation.
///
/// A finding records a category, a status, a stable code, and technical
/// diagnostic text. The text is written for logs and reports and is subject to
/// the repository's redaction rules: it names categories, keys, and states, and
/// never carries private-key material, credentials, certificate bodies, profile
/// bytes, device identifiers, or full entitlement values.
struct ProvisioningPolicyFinding: Equatable, Hashable {

    /// The policy area this observation belongs to.
    let category: ProvisioningPolicyCategory

    /// Whether the rule that produced this observation was satisfied, violated,
    /// or could not be decided.
    let status: ProvisioningPolicyStatus

    /// The machine-readable identity of the observation.
    let code: ProvisioningPolicyFindingCode

    /// Technical diagnostic context, written under the redaction rules above.
    let detail: String

    init(
        category: ProvisioningPolicyCategory,
        status: ProvisioningPolicyStatus,
        code: ProvisioningPolicyFindingCode,
        detail: String
    ) {
        self.category = category
        self.status = status
        self.code = code
        self.detail = detail
    }
}

/// One policy category and the findings behind its status.
///
/// The status is derived from the findings rather than assigned beside them, so
/// a category can never claim a status its findings contradict. A violated
/// finding outranks an indeterminate one, which outranks a satisfied one, and a
/// category with no findings is indeterminate, because nothing was established.
struct ProvisioningPolicyCategoryResult: Equatable, Hashable {

    /// The category.
    let category: ProvisioningPolicyCategory

    /// The status derived from `findings`.
    let status: ProvisioningPolicyStatus

    /// The findings, in evaluation order.
    let findings: [ProvisioningPolicyFinding]

    init(category: ProvisioningPolicyCategory, findings: [ProvisioningPolicyFinding]) {
        self.category = category
        self.findings = findings
        self.status = Self.deriveStatus(from: findings)
    }

    /// The aggregation rule: the most severe finding decides.
    static func deriveStatus(from findings: [ProvisioningPolicyFinding]) -> ProvisioningPolicyStatus {
        if findings.contains(where: { $0.status == .violated }) { return .violated }
        if findings.contains(where: { $0.status == .indeterminate }) { return .indeterminate }
        if findings.isEmpty { return .indeterminate }
        return .satisfied
    }
}

/// The structured outcome of one policy evaluation.
///
/// The result exposes a status per category rather than a single boolean, and
/// it carries no field that could be read as "iOS will accept this":
///
///     parsed
///         ↓
///     structurally valid            (ZS-017, a separate result)
///         ↓
///     CMS authenticated             (ZS-018, a separate result)
///         ↓
///     certificate relationship      (ZS-018, a separate result)
///         ↓
///     policy compatible             (this result)
///         ↓
///     eligible for signing          (this result, and no further)
///
/// `overall` of `.compatible` means every category ZynSign evaluated was
/// satisfied by the facts in the context. It does not mean the profile is
/// trusted, that the certificate chain is valid, that the platform will accept
/// the application, that a signature exists, or that anything was signed.
/// Platform acceptance is performed by the system and is not representable
/// here; `authorization` therefore stays `notEvaluated`.
struct ProvisioningPolicyValidationResult: Equatable, Hashable {

    /// The instant the validity rule was evaluated at.
    let evaluationDate: Date

    /// Every category the validator evaluated, in `ProvisioningPolicyCategory`
    /// declaration order, whether the category was decided or not.
    let categories: [ProvisioningPolicyCategoryResult]

    /// The overall outcome, derived from the categories.
    let overall: ProvisioningPolicyOutcome

    /// Trust evaluation state, carried from the certificate relationship.
    /// Always `notPerformed` on this path.
    let trustEvaluation: CMSTrustEvaluationStatus

    /// Platform authorization state. Always `notEvaluated`: policy compatibility
    /// is not platform authorization, and this stage performs none.
    let authorization: ProvisioningProfileAuthorizationStatus

    init(
        evaluationDate: Date,
        categories: [ProvisioningPolicyCategoryResult],
        trustEvaluation: CMSTrustEvaluationStatus = .notPerformed,
        authorization: ProvisioningProfileAuthorizationStatus = .notEvaluated
    ) {
        let ordered = categories.sorted { Self.order(of: $0.category) < Self.order(of: $1.category) }
        self.evaluationDate = evaluationDate
        self.categories = ordered
        self.overall = Self.outcome(for: ordered)
        self.trustEvaluation = trustEvaluation
        self.authorization = authorization
    }

    /// Every finding, in category order.
    var findings: [ProvisioningPolicyFinding] {
        categories.flatMap { $0.findings }
    }

    /// The findings that reject the configuration.
    var violations: [ProvisioningPolicyFinding] {
        findings.filter { $0.status == .violated }
    }

    /// The findings whose questions stayed open.
    var indeterminateFindings: [ProvisioningPolicyFinding] {
        findings.filter { $0.status == .indeterminate }
    }

    /// The result for one category.
    func result(for category: ProvisioningPolicyCategory) -> ProvisioningPolicyCategoryResult? {
        categories.first { $0.category == category }
    }

    /// The status of one category. A category the validator did not evaluate is
    /// reported indeterminate, never satisfied.
    func status(for category: ProvisioningPolicyCategory) -> ProvisioningPolicyStatus {
        result(for: category)?.status ?? .indeterminate
    }

    /// Whether every category was satisfied.
    var isPolicyCompatible: Bool { overall.isCompatible }

    /// Whether ZynSign's own policy rules were all satisfied for this
    /// application, profile, identity, and configuration.
    ///
    /// This is the last thing this stage can say. It is not platform
    /// authorization, not an installation result, and not a signature: nothing
    /// on this path signs, repackages, installs, or rewrites anything.
    var isEligibleForSigning: Bool { isPolicyCompatible }

    // MARK: Category conveniences

    var profileAuthenticity: ProvisioningPolicyStatus { status(for: .profileAuthenticity) }
    var profileValidity: ProvisioningPolicyStatus { status(for: .profileValidity) }
    var profileType: ProvisioningPolicyStatus { status(for: .profileType) }
    var bundleIdentifier: ProvisioningPolicyStatus { status(for: .bundleIdentifier) }
    var teamIdentifier: ProvisioningPolicyStatus { status(for: .teamIdentifier) }
    var certificate: ProvisioningPolicyStatus { status(for: .certificate) }
    var entitlements: ProvisioningPolicyStatus { status(for: .entitlements) }
    var platform: ProvisioningPolicyStatus { status(for: .platform) }
    var device: ProvisioningPolicyStatus { status(for: .device) }

    /// A redacted diagnostic rendering: overall state, per-category states, and
    /// the codes of the findings that were not satisfied. No values, no bytes,
    /// no identifiers, and no credentials.
    var diagnosticDescription: String {
        var parts: [String] = [
            "policy.overall(\(overall.rawValue))",
            "policy.trust(\(trustEvaluation.rawValue))",
            "policy.authorization(\(authorization.rawValue))",
        ]
        for category in categories {
            parts.append("policy.\(category.category.rawValue)(\(category.status.rawValue))")
        }
        for finding in findings where finding.status != .satisfied {
            parts.append("policy.finding(\(finding.code.rawValue) \(finding.status.rawValue))")
        }
        return parts.joined(separator: " ")
    }

    private static func order(of category: ProvisioningPolicyCategory) -> Int {
        ProvisioningPolicyCategory.allCases.firstIndex(of: category) ?? ProvisioningPolicyCategory.allCases.count
    }

    private static func outcome(for categories: [ProvisioningPolicyCategoryResult]) -> ProvisioningPolicyOutcome {
        if categories.isEmpty { return .indeterminate }
        if categories.contains(where: { $0.status == .violated }) { return .incompatible }
        if categories.contains(where: { $0.status == .indeterminate }) { return .indeterminate }
        return .compatible
    }
}
