import Foundation

/// Decides whether an authenticated provisioning profile is compatible with an
/// application, a signing identity, and a requested signing configuration,
/// under the policy rules ZynSign implements.
///
/// The validator is pure, deterministic for identical inputs, and read-only. It
/// performs no CMS work (the certificate relationship arrives already
/// established), no certificate parsing, no I/O, no Keychain access, and no
/// signing. It never receives private-key bytes, a key reference, a password, or
/// a Keychain record, and it never asks an identity store for a signing
/// capability.
///
/// Order of evaluation:
///
/// 1. authenticity gates everything else: policy rules are applied only to a
///    payload whose CMS signature verified, and every other category stays
///    indeterminate otherwise;
/// 2. each category is then evaluated independently, and every meaningful
///    finding is reported rather than stopping at the first mismatch.
///
/// What the result never says: that the signer's certificate is trusted, that
/// Apple authorized the profile, that a signature exists, or that the platform
/// will accept the application. Compatibility here means the supplied facts
/// satisfy ZynSign's own rules.
struct ProvisioningPolicyValidator {

    /// The clock the validity rule evaluates against. Injected so an evaluation
    /// is reproducible and its instant is visible in the result.
    let clock: any EvaluationClock

    init(clock: any EvaluationClock) {
        self.clock = clock
    }

    /// Evaluates every policy category the context carries facts for.
    func validate(_ context: ProvisioningPolicyValidationContext) -> ProvisioningPolicyValidationResult {
        let evaluationDate = clock.now()
        var categories: [ProvisioningPolicyCategoryResult] = [authenticityCategory(context)]

        if let profile = context.profile, context.profileAuthenticity == .authenticated {
            categories.append(validityCategory(profile: profile, at: evaluationDate))
            categories.append(profileTypeCategory(context: context, profile: profile))
            categories.append(bundleIdentifierCategory(context: context, profile: profile))
            categories.append(teamIdentifierCategory(context: context, profile: profile))
            categories.append(certificateCategory(context))
            categories.append(entitlementsCategory(context: context, profile: profile))
            categories.append(platformCategory(context: context, profile: profile))
            categories.append(deviceCategory(context: context, profile: profile))
        } else {
            let code = Self.gateCode(context)
            let detail = Self.gateDetail(code)
            for category in ProvisioningPolicyCategory.allCases where category != .profileAuthenticity {
                categories.append(
                    categoryResult(category, [
                        finding(category, .indeterminate, code, detail)
                    ])
                )
            }
        }

        return ProvisioningPolicyValidationResult(
            evaluationDate: evaluationDate,
            categories: categories,
            trustEvaluation: context.certificateRelationship.trustEvaluation,
            authorization: .notEvaluated
        )
    }

    // MARK: - Authenticity

    private func authenticityCategory(_ context: ProvisioningPolicyValidationContext) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.profileAuthenticity
        let findings: [ProvisioningPolicyFinding]
        if context.profile == nil {
            switch context.profileAuthenticity {
            case .rejected:
                findings = [
                    finding(category, .violated, .profileAuthenticityRejected, "The container's CMS signature did not verify, so there is no authenticated profile data to evaluate.")
                ]
            case .notEvaluated, .authenticated:
                findings = [
                    finding(category, .indeterminate, .profileNotParsed, "The profile's payload was not parsed, so authenticity for a profile cannot be reported.")
                ]
            }
        } else {
            switch context.profileAuthenticity {
            case .authenticated:
                findings = [
                    finding(category, .satisfied, .profileAuthenticated, "The container's CMS signature verified for the payload the profile was parsed from.")
                ]
            case .rejected:
                findings = [
                    finding(category, .violated, .profileAuthenticityRejected, "The container's CMS signature did not verify, so there is no authenticated profile data to evaluate.")
                ]
            case .notEvaluated:
                findings = [
                    finding(category, .indeterminate, .profileAuthenticityNotEvaluated, "No CMS check established authenticity for this profile's payload.")
                ]
            }
        }
        return categoryResult(category, findings)
    }

    private static func gateCode(_ context: ProvisioningPolicyValidationContext) -> ProvisioningPolicyFindingCode {
        guard context.profile != nil else { return .profileNotParsed }
        switch context.profileAuthenticity {
        case .rejected: return .profileAuthenticityRejected
        case .notEvaluated: return .profileAuthenticityNotEvaluated
        case .authenticated: return .profileNotParsed
        }
    }

    private static func gateDetail(_ code: ProvisioningPolicyFindingCode) -> String {
        switch code {
        case .profileNotParsed:
            return "Policy rules were not applied because no profile payload was parsed."
        default:
            return "Policy rules were not applied because the profile payload is not authenticated."
        }
    }

    // MARK: - Profile validity

    private func validityCategory(profile: ProvisioningProfile, at date: Date) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.profileValidity
        guard let creationDate = profile.creationDate, let expirationDate = profile.expirationDate else {
            return categoryResult(category, [
                finding(category, .indeterminate, .profileDatesMissing, "The profile does not carry both a creation date and an expiration date, so its validity period cannot be evaluated.")
            ])
        }

        let validity = ProvisioningProfileValidity.evaluate(
            creationDate: creationDate,
            expirationDate: expirationDate,
            at: date
        )
        let findings: [ProvisioningPolicyFinding]
        switch validity.periodStatus {
        case .currentlyValid:
            findings = [
                finding(category, .satisfied, .profileWithinValidityPeriod, "The evaluation instant falls within the profile's validity period. This is a period fact, not trust and not platform acceptance.")
            ]
        case .expired:
            findings = [
                finding(category, .violated, .profileExpired, "The profile's validity period ended before the evaluation instant.")
            ]
        case .notYetValid:
            findings = [
                finding(category, .violated, .profileNotYetValid, "The profile's validity period begins after the evaluation instant.")
            ]
        case .malformed:
            findings = [
                finding(category, .violated, .profileDatesMalformed, "The profile's creation date is later than its expiration date, so the interval is not an ordered period.")
            ]
        }
        return categoryResult(category, findings)
    }

    // MARK: - Profile classification

    private func profileTypeCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.profileType
        var findings: [ProvisioningPolicyFinding] = []
        let classification = profile.classification

        if classification == .unknown {
            findings.append(
                finding(category, .indeterminate, .profileClassUnknown, "The profile's fields do not establish a supported profile class, so no class-specific rule was applied.")
            )
            return categoryResult(category, findings)
        }

        findings.append(
            finding(category, .satisfied, .profileClassEstablished, "The profile's fields establish a supported profile class.")
        )

        switch context.signingConfiguration.intendedProfileClass {
        case .none:
            break
        case .some(.unknown):
            findings.append(
                finding(category, .indeterminate, .profileClassIntentNotEstablished, "The requested profile class is itself unknown, so no comparison was made.")
            )
        case .some(let intended):
            if intended != classification {
                findings.append(
                    finding(category, .violated, .profileClassMismatch, "The profile's established class is not the class the requested configuration intends.")
                )
            }
        }
        return categoryResult(category, findings)
    }

    // MARK: - Bundle identifier

    private func bundleIdentifierCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.bundleIdentifier
        guard let bundleIdentifier = context.resolvedBundleIdentifier else {
            return categoryResult(category, [
                finding(category, .indeterminate, .applicationBundleIdentifierMissing, "No application bundle identifier was established, so the profile's identifier scope was not compared.")
            ])
        }
        guard profile.applicationIdentifier != nil else {
            return categoryResult(category, [
                finding(category, .indeterminate, .profileApplicationIdentifierMissing, "The profile declares no application identifier, so it has no scope to compare against.")
            ])
        }

        let outcome = ProvisioningIdentifierCompatibility(profile: profile)
            .outcome(forBundleIdentifier: bundleIdentifier)
        let findings: [ProvisioningPolicyFinding]
        switch outcome {
        case .exactMatch:
            findings = [
                finding(category, .satisfied, .bundleIdentifierExactMatch, "The application's bundle identifier is the identifier the profile declares exactly.")
            ]
        case .wildcardMatch:
            findings = [
                finding(category, .satisfied, .bundleIdentifierWildcardMatch, "The application's bundle identifier falls inside the scope the profile's wildcard identifier declares.")
            ]
        case .mismatch:
            findings = [
                finding(category, .violated, .bundleIdentifierMismatch, "The application's bundle identifier lies outside the scope the profile declares.")
            ]
        case .indeterminate:
            findings = [
                finding(category, .indeterminate, .bundleIdentifierNotComparable, "The profile's application identifier cannot be compared with the application's bundle identifier without inventing a boundary the profile does not state.")
            ]
        }
        return categoryResult(category, findings)
    }

    // MARK: - Team identifier

    private func teamIdentifierCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.teamIdentifier
        var findings: [ProvisioningPolicyFinding] = []
        let declaredTeams = Self.declaredTeamIdentifiers(profile)

        if declaredTeams.isEmpty {
            findings.append(
                finding(category, .indeterminate, .profileTeamIdentifierMissing, "The profile declares no team identifier, so no team comparison is possible.")
            )
        } else {
            findings.append(
                finding(category, .satisfied, .profileTeamIdentifierPresent, "The profile declares a team identifier.")
            )
        }

        if let claim = context.signingConfiguration.entitlements?[ProvisioningProfileEntitlementKeys.teamIdentifier] {
            if case .string(let claimedTeam) = claim {
                if declaredTeams.isEmpty {
                    findings.append(
                        finding(category, .indeterminate, .teamIdentifierClaimNotComparable, "The requested team claim cannot be compared because the profile declares no team identifier.")
                    )
                } else if declaredTeams.contains(claimedTeam) {
                    findings.append(
                        finding(category, .satisfied, .teamIdentifierClaimMatched, "The requested team claim is a team identifier the profile declares.")
                    )
                } else {
                    findings.append(
                        finding(category, .violated, .teamIdentifierClaimMismatch, "The requested team claim is not a team identifier the profile declares.")
                    )
                }
            } else {
                findings.append(
                    finding(category, .indeterminate, .teamIdentifierClaimNotComparable, "The requested team claim is not a string, so it was not compared with the profile's team identifier.")
                )
            }
        }

        switch context.signingIdentity {
        case .notProvided:
            findings.append(
                finding(category, .indeterminate, .signingIdentityNotProvided, "No signing identity was supplied, so the identity's team association was not examined.")
            )
        case .noneAvailable:
            findings.append(
                finding(category, .indeterminate, .signingIdentityNoneAvailable, "No signing identity was available, so the identity's team association was not examined.")
            )
        case .lookupFailed:
            findings.append(
                finding(category, .indeterminate, .signingIdentityLookupFailed, "The identity store could not be read, so the identity's team association was not examined.")
            )
        case .identity(let metadata):
            let candidates = Self.teamIdentifierCandidates(in: metadata.certificate.subject)
            if declaredTeams.isEmpty {
                findings.append(
                    finding(category, .indeterminate, .teamIdentifierIdentityNotEstablished, "The certificate's structured attributes were not compared because the profile declares no team identifier.")
                )
            } else if candidates.contains(where: { declaredTeams.contains($0) }) {
                findings.append(
                    finding(category, .satisfied, .teamIdentifierIdentityMatched, "A structured organizational-unit value of the certificate's subject is a team identifier the profile declares.")
                )
            } else if !candidates.isEmpty {
                findings.append(
                    finding(category, .violated, .teamIdentifierIdentityMismatch, "The certificate's subject carries structured team-identifier-shaped values, and none of them is a team identifier the profile declares.")
                )
            } else {
                findings.append(
                    finding(category, .indeterminate, .teamIdentifierIdentityNotEstablished, "The certificate's subject carries no structured team-identifier-shaped attribute, so the identity's team association could not be established. A common name or a label is not used for this comparison.")
                )
            }
        }

        return categoryResult(category, findings)
    }

    /// Every team identifier the profile declares: the `TeamIdentifier` array
    /// and the team-identifier entitlement.
    ///
    /// Both are fields the profile itself carries. The structural validator
    /// already reports a disagreement between them; this rule only asks whether
    /// a claim or an identity corresponds to one of them.
    static func declaredTeamIdentifiers(_ profile: ProvisioningProfile) -> [String] {
        var identifiers = profile.teamIdentifiers ?? []
        if let entitlementTeam = profile.entitlementTeamIdentifier, !identifiers.contains(entitlementTeam) {
            identifiers.append(entitlementTeam)
        }
        return identifiers
    }

    /// The structured values of a certificate subject that could be a team
    /// identifier.
    ///
    /// Only the subject's structured organizational-unit attributes are read.
    /// A common name, an organization, a display string, and a label are never
    /// used, because a human-readable name is not a structured team identifier.
    ///
    /// A candidate is an organizational-unit value of exactly ten ASCII
    /// uppercase letters or digits. That shape is **[Inferred]** from the team
    /// identifiers ZynSign's fixtures and documentation show; it is not a
    /// verified statement that every Apple developer certificate carries its
    /// team identifier in an organizational unit, and the recorded open
    /// question remains open. When this rule cannot establish an association it
    /// returns no candidates, and the caller reports an indeterminate result
    /// rather than a match or a mismatch.
    static func teamIdentifierCandidates(in name: CertificateDistinguishedName) -> [String] {
        var candidates: [String] = []
        for attribute in name.attributes where attribute.recognition == .organizationalUnit {
            guard let text = attribute.text, isTeamIdentifierCandidate(text), !candidates.contains(text) else { continue }
            candidates.append(text)
        }
        return candidates
    }

    /// ZynSign's shape rule for a team-identifier-shaped attribute value.
    static func isTeamIdentifierCandidate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    // MARK: - Certificate

    private func certificateCategory(_ context: ProvisioningPolicyValidationContext) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.certificate
        var findings: [ProvisioningPolicyFinding] = []
        let relationship = context.certificateRelationship

        if relationship.profileCertificateCount > 0 {
            findings.append(
                finding(category, .satisfied, .profileCarriesCertificateReferences, "The profile carries certificate references.")
            )
        } else {
            findings.append(
                finding(category, .indeterminate, .profileCarriesNoCertificateReferences, "The profile carries no certificate reference, so no identity can be related to it.")
            )
        }

        if relationship.profileReferenceWithoutMetadataCount > 0 {
            findings.append(
                finding(category, .indeterminate, .profileCertificateMetadataUnavailable, "At least one certificate reference could not be compared, so the certificate set is incomplete.")
            )
        }

        switch relationship.match {
        case .matched:
            findings.append(
                finding(category, .satisfied, .containerSignerMatchesProfileCertificate, "The container's signer certificate is one of the certificates the profile names.")
            )
        case .mismatched:
            findings.append(
                finding(category, .indeterminate, .containerSignerNotProfileCertificate, "The container's signer certificate is not one of the certificates the profile names. This is recorded as an observation; authenticity evidence remains the CMS boundary's result.")
            )
        case .ambiguous, .incomparable, .notEvaluated:
            findings.append(
                finding(category, .indeterminate, .containerSignerNotEvaluated, "The container's signer certificate was not related to the profile's certificates.")
            )
        }

        switch context.signingIdentity {
        case .notProvided:
            findings.append(
                finding(category, .indeterminate, .signingIdentityNotProvided, "No signing identity was supplied, so no identity certificate was compared with the profile.")
            )
        case .noneAvailable:
            findings.append(
                finding(category, .indeterminate, .signingIdentityNoneAvailable, "No signing identity was available, so no identity certificate was compared with the profile.")
            )
        case .lookupFailed:
            findings.append(
                finding(category, .indeterminate, .signingIdentityLookupFailed, "The identity store could not be read, so no identity certificate was compared with the profile. An unreadable store says nothing about the profile.")
            )
        case .identity(let metadata):
            let identityFingerprint = metadata.certificate.sha256Fingerprint
            if relationship.profileCertificateFingerprints.isEmpty {
                findings.append(
                    finding(category, .indeterminate, .profileCertificateFingerprintsUnavailable, "The profile's certificate references carry no comparable fingerprint, so the identity's certificate could not be checked against them.")
                )
            } else if relationship.profileCertificateFingerprints.contains(identityFingerprint) {
                findings.append(
                    finding(category, .satisfied, .signingIdentityCertificateMatched, "The signing identity's certificate is one of the certificates the profile names.")
                )
                findings.append(contentsOf: capabilityFindings(for: metadata, category: category))
            } else {
                findings.append(
                    finding(category, .violated, .signingIdentityCertificateMismatch, "The signing identity's certificate is not one of the certificates the profile names.")
                )
            }
        }

        return categoryResult(category, findings)
    }

    /// Key availability and readiness, reported separately from the certificate
    /// match because holding a matching certificate is not holding its key.
    ///
    /// These are reports about the identity, not defects in the profile: an
    /// unavailable key makes eligibility indeterminate and never makes a
    /// profile malformed, and nothing here asks for, receives, or exercises a
    /// signing capability.
    private func capabilityFindings(
        for metadata: SigningIdentityMetadata,
        category: ProvisioningPolicyCategory
    ) -> [ProvisioningPolicyFinding] {
        if metadata.keyAvailability.isAvailable,
           metadata.association == .matched,
           metadata.capabilityState == .ready {
            return [
                finding(category, .satisfied, .signingIdentityUsableForSigning, "The identity reports an available key whose public key matches its certificate, with a ready primitive. This is readiness for an operation, not a signature and not an authorization.")
            ]
        }

        var findings: [ProvisioningPolicyFinding] = []
        if !metadata.keyAvailability.isAvailable {
            findings.append(
                finding(category, .indeterminate, .signingKeyUnavailable, "The identity's private key is not reported as available, so eligibility for signing cannot be established.")
            )
        }
        if metadata.association != .matched {
            findings.append(
                finding(category, .indeterminate, .signingKeyAssociationNotEstablished, "The association between the identity's key and its certificate is not reported as matched.")
            )
        }
        if metadata.capabilityState != .ready {
            findings.append(
                finding(category, .indeterminate, .signingCapabilityNotReady, "The identity's primitive capability is not reported as ready.")
            )
        }
        return findings
    }

    // MARK: - Entitlements

    private func entitlementsCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.entitlements
        let authorized = profile.entitlements
        var findings: [ProvisioningPolicyFinding] = []

        // Profile-side: the identifier claim the profile carries must agree with
        // the identifier the profile declares.
        if let authorized {
            if let value = authorized[ProvisioningProfileEntitlementKeys.applicationIdentifier] {
                if case .string(let claim) = value {
                    if let identifier = profile.applicationIdentifier {
                        if claim == identifier.fullValue {
                            findings.append(
                                finding(category, .satisfied, .profileIdentifierEntitlementConsistent, "The profile's identifier entitlement is the application identifier the profile declares.")
                            )
                        } else {
                            findings.append(
                                finding(category, .violated, .profileIdentifierEntitlementInconsistent, "The profile's identifier entitlement is not the application identifier the profile declares.")
                            )
                        }
                    }
                } else {
                    findings.append(
                        finding(category, .indeterminate, .profileIdentifierEntitlementNotComparable, "The profile's identifier entitlement is not a string, so it was not compared with the declared application identifier.")
                    )
                }
            } else {
                findings.append(
                    finding(category, .indeterminate, .profileIdentifierEntitlementMissing, "The profile's allowlist carries no identifier entitlement, so no claim can be checked against it.")
                )
            }
        }

        guard let requested = context.signingConfiguration.entitlements else {
            findings.append(
                finding(category, .indeterminate, .requestedEntitlementsNotEstablished, "No requested claim set was established, so the allowlist was not compared with a request.")
            )
            return categoryResult(category, findings)
        }

        findings.append(contentsOf: applicationIdentifierClaimFindings(context: context, profile: profile, requested: requested))
        findings.append(contentsOf: getTaskAllowFindings(context: context, authorized: authorized))
        findings.append(contentsOf: genericEntitlementFindings(requested: requested, authorized: authorized))

        return categoryResult(category, findings)
    }

    /// The `application-identifier` claim, decided by the one identifier rule.
    private func applicationIdentifierClaimFindings(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile,
        requested: ProvisioningProfileEntitlements
    ) -> [ProvisioningPolicyFinding] {
        let category = ProvisioningPolicyCategory.entitlements
        guard let value = requested[ProvisioningProfileEntitlementKeys.applicationIdentifier] else { return [] }
        guard case .string(let claim) = value else {
            return [
                finding(category, .indeterminate, .applicationIdentifierClaimNotComparable, "The requested identifier claim is not a string, so it was not compared with the profile's scope.")
            ]
        }

        let compatibility = ProvisioningIdentifierCompatibility(profile: profile)
        var findings: [ProvisioningPolicyFinding] = []
        switch compatibility.outcome(forApplicationIdentifierValue: claim) {
        case .exactMatch:
            findings.append(
                finding(category, .satisfied, .applicationIdentifierClaimMatched, "The requested identifier claim is the application identifier the profile declares.")
            )
        case .wildcardMatch:
            findings.append(
                finding(category, .satisfied, .applicationIdentifierClaimMatched, "The requested identifier claim falls inside the scope the profile's wildcard identifier declares.")
            )
        case .mismatch:
            findings.append(
                finding(category, .violated, .applicationIdentifierClaimMismatch, "The requested identifier claim lies outside the scope the profile declares.")
            )
        case .indeterminate:
            findings.append(
                finding(category, .indeterminate, .applicationIdentifierClaimNotComparable, "The requested identifier claim could not be compared with the profile's scope.")
            )
        }

        if let bundleIdentifier = context.resolvedBundleIdentifier,
           let expected = compatibility.expectedApplicationIdentifier(for: bundleIdentifier) {
            if claim != expected {
                findings.append(
                    finding(category, .violated, .applicationIdentifierDoesNotDescribeApplication, "The requested identifier claim does not describe the application being signed under the profile's declared prefix.")
                )
            }
        }
        return findings
    }

    /// `get-task-allow`, handled explicitly.
    ///
    /// The documented behaviour this rule rests on: the claim's presence depends
    /// on the profile class and it affects debuggability rather than
    /// installability on the profiles where it is allowed. Absence is therefore
    /// not treated as `false`, and requesting `false` where the profile
    /// authorizes `true` is reported as an open question rather than as either a
    /// pass or a conflict, because the project's record does not establish
    /// whether a disclaimed value must appear in the allowlist literally. The
    /// rule is stated here rather than applied globally, and no value is
    /// considered universally appropriate.
    private func getTaskAllowFindings(
        context: ProvisioningPolicyValidationContext,
        authorized: ProvisioningProfileEntitlements?
    ) -> [ProvisioningPolicyFinding] {
        let category = ProvisioningPolicyCategory.entitlements
        switch context.signingConfiguration.requestedGetTaskAllowClaim {
        case .notRequested:
            // Nothing was requested, so nothing is compared. Omission is not a
            // pass and is not recorded as one.
            return []
        case .contradictory:
            return [
                finding(category, .indeterminate, .getTaskAllowConfigurationAmbiguous, "The requested debugging preference and the requested claim disagree, so no value was compared.")
            ]
        case .notComparable:
            return [
                finding(category, .indeterminate, .getTaskAllowNotComparable, "The requested debugging claim is not a boolean, so it was not compared with the profile's allowlist.")
            ]
        case .requested(let requestedValue):
            let profileClaim = authorized?[ProvisioningProfileEntitlementKeys.getTaskAllow]
            var authorizedValue: Bool?
            var profileClaimIsNotBoolean = false
            if let profileClaim = profileClaim {
                if case .boolean(let boolean) = profileClaim {
                    authorizedValue = boolean
                } else {
                    profileClaimIsNotBoolean = true
                }
            }
            if profileClaimIsNotBoolean {
                return [
                    finding(category, .indeterminate, .getTaskAllowNotComparable, "The profile's debugging claim is not a boolean, so the requested value was not compared with it.")
                ]
            }
            if requestedValue {
                switch authorizedValue {
                case .some(true):
                    return [
                        finding(category, .satisfied, .getTaskAllowMatched, "The profile authorizes the requested debugging value.")
                    ]
                case .some(false):
                    return [
                        finding(category, .violated, .getTaskAllowNotAuthorized, "The profile carries a debugging value that is not the requested one.")
                    ]
                case .none:
                    return [
                        finding(category, .violated, .getTaskAllowAbsentFromProfile, "The profile carries no debugging claim, so it does not authorize the requested value. Absence is a distinct observation from a value of false.")
                    ]
                }
            }
            switch authorizedValue {
            case .some(false):
                return [
                    finding(category, .satisfied, .getTaskAllowMatched, "The profile authorizes the requested debugging value.")
                ]
            case .some(true):
                return [
                    finding(category, .indeterminate, .getTaskAllowValueNotEstablished, "The profile authorizes the debugging claim with the other value. Whether a disclaimed value must appear in the allowlist literally is not established, so this is reported as an open question rather than as a pass or a conflict.")
                ]
            case .none:
                return [
                    finding(category, .indeterminate, .getTaskAllowAbsentFromProfile, "The profile carries no debugging claim, and absence is not treated as a value of false, so the comparison stays open.")
                ]
            }
        }
    }

    /// Every requested claim the generic rules speak for, in key order.
    private func genericEntitlementFindings(
        requested: ProvisioningProfileEntitlements,
        authorized: ProvisioningProfileEntitlements?
    ) -> [ProvisioningPolicyFinding] {
        let category = ProvisioningPolicyCategory.entitlements
        let evaluations = ProvisioningEntitlementComparator.evaluate(requested: requested, against: authorized)
            .filter { $0.outcome != .requiresSpecialHandling }

        guard !evaluations.isEmpty else {
            return [
                finding(category, .satisfied, .entitlementAuthorized, "No requested claim was decided by the generic rules, so none of them falls outside the profile's allowlist. A claim the dedicated rules decide is reported by the rule that decides it.")
            ]
        }

        return evaluations.compactMap { evaluation -> ProvisioningPolicyFinding? in
            switch evaluation.outcome {
            case .claimMatchesAuthorization:
                return finding(category, .satisfied, .entitlementAuthorized, "The requested claim '\(evaluation.key)' is within the profile's allowlist with a value the comparison rules accept.")
            case .claimNotAuthorized:
                return finding(category, .violated, .entitlementNotAuthorized, "The requested claim '\(evaluation.key)' does not appear in the profile's allowlist.")
            case .claimValueConflicts:
                return finding(category, .violated, .entitlementValueConflict, "The requested claim '\(evaluation.key)' carries a value the profile's allowlist does not authorize.")
            case .cannotBeEvaluated:
                return finding(category, .indeterminate, .entitlementValueNotComparable, "The requested claim '\(evaluation.key)' cannot be compared with the authorized value under any established rule.")
            case .unsupportedByPolicy:
                return finding(category, .indeterminate, .entitlementValueUnsupported, "The requested claim '\(evaluation.key)' uses a value form for which ZynSign has no established comparison rule.")
            case .requiresSpecialHandling:
                // Filtered above: a dedicated rule speaks for this key, so the
                // generic rules stay silent rather than competing with it.
                return nil
            }
        }
    }

    // MARK: - Platform

    private func platformCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.platform
        guard let declared = profile.platforms, !declared.isEmpty else {
            return categoryResult(category, [
                finding(category, .indeterminate, .platformNotDeclared, "The profile declares no platform, so no platform comparison is possible.")
            ])
        }
        guard let intended = context.resolvedPlatformScope.platforms, !intended.isEmpty else {
            return categoryResult(category, [
                finding(category, .indeterminate, .applicationPlatformNotEstablished, "The platforms the application is intended for were not established, so the profile's platforms were not compared.")
            ])
        }

        if declared.contains(where: { intended.contains($0) }) {
            return categoryResult(category, [
                finding(category, .satisfied, .platformSupported, "The profile declares a platform the application is intended for.")
            ])
        }

        let carriesUnrecognized = declared.contains { platform in
            if case .unknown = platform { return true }
            return false
        }
        if carriesUnrecognized {
            return categoryResult(category, [
                finding(category, .indeterminate, .platformNotComparable, "The profile declares a platform spelling ZynSign does not recognise, so no conclusion was drawn from the remaining declarations.")
            ])
        }

        return categoryResult(category, [
            finding(category, .violated, .platformNotSupported, "The profile's declared platforms do not include a platform the application is intended for.")
        ])
    }

    // MARK: - Device

    private func deviceCategory(
        context: ProvisioningPolicyValidationContext,
        profile: ProvisioningProfile
    ) -> ProvisioningPolicyCategoryResult {
        let category = ProvisioningPolicyCategory.device
        let devices = profile.provisionedDevices
        let provisionsAllDevices = profile.provisionsAllDevices == true

        if provisionsAllDevices && devices != nil {
            return categoryResult(category, [
                finding(category, .indeterminate, .deviceRestrictionInconsistent, "The profile both declares that it provisions all devices and carries a device list, so its device restriction is not established.")
            ])
        }

        if provisionsAllDevices {
            return categoryResult(category, [
                finding(category, .satisfied, .deviceRestrictionAbsent, "The profile declares that it provisions all devices, so no device comparison applies. A parsed device list is not proof of authorization, and its absence is not proof of it either.")
            ])
        }

        guard let deviceIdentifiers = devices else {
            return categoryResult(category, [
                finding(category, .satisfied, .deviceRestrictionAbsent, "The profile carries no device list, so no device comparison applies. A parsed device list is not proof of authorization, and a missing one is not proof of it either.")
            ])
        }

        switch context.deviceContext {
        case .unavailable:
            return categoryResult(category, [
                finding(category, .indeterminate, .deviceContextUnavailable, "The profile restricts the devices it covers, and no trustworthy device identity was available to compare against, so this question is deferred. ZynSign does not assume the running device is authorized because the profile lists devices.")
            ])
        case .identified(let identifier):
            if deviceIdentifiers.contains(identifier) {
                return categoryResult(category, [
                    finding(category, .satisfied, .deviceProvisioned, "The device identifier supplied for this evaluation appears in the profile's device list.")
                ])
            }
            return categoryResult(category, [
                finding(category, .violated, .deviceNotProvisioned, "The profile restricts the devices it covers, and the device identifier supplied for this evaluation does not appear in that list.")
            ])
        }
    }

    // MARK: - Helpers

    private func finding(
        _ category: ProvisioningPolicyCategory,
        _ status: ProvisioningPolicyStatus,
        _ code: ProvisioningPolicyFindingCode,
        _ detail: String
    ) -> ProvisioningPolicyFinding {
        ProvisioningPolicyFinding(category: category, status: status, code: code, detail: detail)
    }

    private func categoryResult(
        _ category: ProvisioningPolicyCategory,
        _ findings: [ProvisioningPolicyFinding]
    ) -> ProvisioningPolicyCategoryResult {
        ProvisioningPolicyCategoryResult(category: category, findings: findings)
    }
}
