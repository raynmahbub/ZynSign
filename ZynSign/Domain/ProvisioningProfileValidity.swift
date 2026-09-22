import Foundation

/// The validity-period state of a structurally parseable profile.
///
/// This answers only whether the profile supplies an ordered interval and,
/// when it does, whether the injected evaluation instant falls between the
/// creation and expiration dates, inclusively. It is not CMS
/// authenticity, certificate trust, entitlement authorization, or device
/// authorization.
enum ProvisioningProfileValidityPeriodStatus: String, CaseIterable, Equatable, Hashable {

    /// The date fields were present but could not form an ordered interval.
    /// Parser-level type/encoding failures use the controlled `.invalidDate`
    /// profile error before a profile reaches this validator.
    case malformed
    case notYetValid
    case currentlyValid
    case expired

    var isCurrentlyValid: Bool { self == .currentlyValid }
}

/// The result of evaluating a profile's creation/expiration interval.
struct ProvisioningProfileValidity: Equatable, Hashable {

    let periodStatus: ProvisioningProfileValidityPeriodStatus
    let evaluationDate: Date
    let creationDate: Date
    let expirationDate: Date

    var isCurrentlyValid: Bool { periodStatus.isCurrentlyValid }

    static func evaluate(
        creationDate: Date,
        expirationDate: Date,
        at date: Date
    ) -> ProvisioningProfileValidity {
        let status: ProvisioningProfileValidityPeriodStatus
        if creationDate > expirationDate {
            status = .malformed
        } else if date < creationDate {
            status = .notYetValid
        } else if date > expirationDate {
            status = .expired
        } else {
            status = .currentlyValid
        }
        return ProvisioningProfileValidity(
            periodStatus: status,
            evaluationDate: date,
            creationDate: creationDate,
            expirationDate: expirationDate
        )
    }
}

/// Stable issue codes for structural profile validation.
enum ProvisioningProfileValidationIssueCode: String, CaseIterable, Hashable {

    case missingRequiredMetadata
    case invalidFieldValue
    case invalidDate
    case invalidIdentifier
    case inconsistentMetadata
    case unsupportedValue
}

/// One safe, non-throwing validation observation about a parsed profile.
struct ProvisioningProfileValidationFinding: Equatable, Hashable {

    let severity: ValidationSeverity
    let code: ProvisioningProfileValidationIssueCode
    let detail: String

    init(
        severity: ValidationSeverity,
        code: ProvisioningProfileValidationIssueCode,
        detail: String
    ) {
        self.severity = severity
        self.code = code
        self.detail = detail
    }

    var isRejecting: Bool { severity.rejectsArtifact }
}

/// Structural validation kept separate from profile parsing.
///
/// A valid structural result says that the required fields and cross-field
/// invariants checked by ZynSign hold. The separate `validity` value may still
/// be `.malformed`, `.expired`, or `.notYetValid`; none of those states is a
/// trust result.
struct ProvisioningProfileValidation: Equatable, Hashable {

    let classification: ValidationClassification
    let findings: [ProvisioningProfileValidationFinding]
    let validity: ProvisioningProfileValidity?

    var isStructurallyValid: Bool { classification == .valid }
    var errors: [ProvisioningProfileValidationFinding] {
        findings.filter { $0.severity == .error }
    }
    var warnings: [ProvisioningProfileValidationFinding] {
        findings.filter { $0.severity == .warning }
    }
    var isCurrentlyValid: Bool { validity?.isCurrentlyValid == true }
}

/// Required-field and cross-field checks for a parsed profile.
struct ProvisioningProfileValidator {

    let clock: any EvaluationClock

    init(clock: any EvaluationClock) {
        self.clock = clock
    }

    /// Validates a parsed profile without performing CMS, chain, entitlement,
    /// certificate/key, device, or platform-policy authorization.
    func validate(_ profile: ProvisioningProfile) -> ProvisioningProfileValidation {
        var findings: [ProvisioningProfileValidationFinding] = []

        if profile.uuid == nil {
            findings.append(finding(.missingRequiredMetadata, "The profile has no valid UUID field."))
        }
        if profile.profileName?.isEmpty != false {
            findings.append(finding(.missingRequiredMetadata, "The profile has no non-empty Name field."))
        }
        if profile.creationDate == nil {
            findings.append(finding(.missingRequiredMetadata, "The profile has no CreationDate field."))
        }
        if profile.expirationDate == nil {
            findings.append(finding(.missingRequiredMetadata, "The profile has no ExpirationDate field."))
        }
        if profile.entitlements == nil {
            findings.append(finding(.missingRequiredMetadata, "The profile has no Entitlements dictionary."))
        }
        if profile.applicationIdentifier == nil {
            findings.append(finding(.missingRequiredMetadata, "The profile has no application identifier."))
        }

        if let prefixes = profile.applicationIdentifierPrefixes, prefixes.isEmpty {
            findings.append(finding(.invalidFieldValue, "ApplicationIdentifierPrefix was present but empty."))
        }
        if let teams = profile.teamIdentifiers, teams.isEmpty {
            findings.append(finding(.invalidFieldValue, "TeamIdentifier was present but empty."))
        }
        if let platforms = profile.platforms, platforms.isEmpty {
            findings.append(finding(.invalidFieldValue, "Platform was present but empty."))
        }
        if let prefixes = profile.applicationIdentifierPrefixes,
           let identifier = profile.applicationIdentifier,
           prefixes.first != identifier.applicationIdentifierPrefix {
            findings.append(finding(.invalidIdentifier, "The application identifier prefix does not match the profile prefix array."))
        }
        if let version = profile.version, version < 1 {
            findings.append(finding(.invalidFieldValue, "Version must be a positive integer."))
        }

        if let rootTeam = profile.teamIdentifiers?.first,
           let entitlementTeam = profile.entitlementTeamIdentifier,
           rootTeam != entitlementTeam {
            findings.append(finding(.inconsistentMetadata, "TeamIdentifier and the team entitlement disagree."))
        }

        var validity: ProvisioningProfileValidity?
        if let creationDate = profile.creationDate,
           let expirationDate = profile.expirationDate {
            if creationDate > expirationDate {
                findings.append(finding(.invalidDate, "CreationDate is later than ExpirationDate."))
                validity = ProvisioningProfileValidity(
                    periodStatus: .malformed,
                    evaluationDate: clock.now(),
                    creationDate: creationDate,
                    expirationDate: expirationDate
                )
            } else {
                validity = ProvisioningProfileValidity.evaluate(
                    creationDate: creationDate,
                    expirationDate: expirationDate,
                    at: clock.now()
                )
            }
        }

        let classification: ValidationClassification = findings.contains(where: { $0.isRejecting })
            ? .invalid
            : .valid
        return ProvisioningProfileValidation(
            classification: classification,
            findings: findings,
            validity: validity
        )
    }

    private func finding(
        _ code: ProvisioningProfileValidationIssueCode,
        _ detail: String
    ) -> ProvisioningProfileValidationFinding {
        ProvisioningProfileValidationFinding(severity: .error, code: code, detail: detail)
    }
}
