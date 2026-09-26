import Foundation

/// Evidence obtained by reading a library archive, never by modifying or
/// extracting it. The archive reader is closed before this value is returned.
enum SigningPackageEvidence {
    case missing
    case changed
    case unreadable
    case inspected(SigningPackageInspection)
}

struct SigningPackageInspection {
    let validation: ValidationResult
    let metadata: ApplicationMetadata?
    let metadataFailure: ValidationIssueCode?
    let executablePresent: Bool
    let discovery: NestedCodeDiscoveryOutcome?
    let images: SigningImageSupport
}

struct SigningImageSupport {
    /// `nil` means no image could be read and checked against the signer's
    /// exact, narrow admission rule. The root and nested code are independent.
    let rootSupported: Bool?
    let nestedSupported: Bool?

    static let unchecked = SigningImageSupport(rootSupported: nil, nestedSupported: nil)
}

enum SigningIdentityEvidence {
    case notSelected, unavailable, storeUnavailable
    case selected(SigningIdentity)
}

enum SigningProfileProblem {
    case invalid, unsupported, unauthenticated, unreadable
}

enum SigningProfileEvidence {
    case notSelected
    case failed(SigningProfileProblem)
    /// The CMS payload is authenticated AND the profile is structurally valid.
    /// The policy is re-evaluated at scan time with the *actual* claims the
    /// signing UI will hand to the pipeline (not a guessed empty claim set).
    case verified(policy: ProvisioningPolicyValidationResult, expiration: Date?, claimsRepresentable: Bool)
}

/// Pure report construction. All wording is redacted and controlled here;
/// nothing from a foreign error, plist value, bundle path or identity label is
/// copied into an issue. Unknown policy states are never turned into passes.
struct SigningDiagnosticsEvaluation {
    private(set) var states: [SigningDiagnosticArea: SigningCheckState] = [:]
    private(set) var issues: [SigningDiagnostic] = []

    static func evaluate(
        record: ApplicationRecord,
        package: SigningPackageEvidence,
        identity: SigningIdentityEvidence,
        profile: SigningProfileEvidence,
        emitDEREntitlements: Bool,
        at date: Date
    ) -> SigningDiagnosticsReport {
        var builder = SigningDiagnosticsEvaluation()
        builder.package(package, record: record)
        builder.identity(identity, at: date)
        builder.profile(profile, identitySelected: builder.hasIdentity(identity), at: date)
        if emitDEREntitlements {
            builder.add(.derUnavailable, .signingOptions, .unsupported,
                        "DER signing is not implemented",
                        "The current pipeline cannot embed or verify a DER entitlement slot. It will refuse this option rather than silently write an XML-only signature.",
                        "Slot 7 is not wired into the signer, so selecting this option is unsupported even though DER serialization exists separately.",
                        "Turn off this option for local XML-only signing. If your target requires DER, use a signer with verified DER support.")
            builder.mark(.signingOptions, .unsupported)
        } else {
            builder.add(.legacyEntitlements, .signingOptions, .warning,
                        "XML-only entitlements",
                        "The current pipeline embeds XML entitlements only. Its iOS 15+ DER requirements have not been established.",
                        "The signer writes CodeDirectory v0x20200 and slot 5, but not slot 7. External iOS-format validation remains outstanding.",
                        "For a target that requires DER, use a signer with verified DER support; this build cannot enable it.")
            builder.mark(.signingOptions, .attention)
        }
        let checks = SigningDiagnosticArea.allCases.map {
            SigningDiagnosticCheck(area: $0, state: builder.states[$0] ?? .notChecked)
        }
        // Keep the order stable within each severity for history and VoiceOver.
        let urgency: [SigningDiagnosticSeverity: Int] = [
            .error: 0, .unsupported: 1, .warning: 2, .info: 3, .success: 4
        ]
        let ordered = builder.issues.enumerated().sorted {
            (urgency[$0.element.severity] ?? 5, $0.offset) < (urgency[$1.element.severity] ?? 5, $1.offset)
        }.map(\.element)
        return SigningDiagnosticsReport(recordID: record.id, analyzedAt: date, checks: checks, issues: ordered)
    }

    private func hasIdentity(_ evidence: SigningIdentityEvidence) -> Bool {
        if case .selected = evidence { return true }
        return false
    }

    private mutating func mark(_ area: SigningDiagnosticArea, _ state: SigningCheckState) {
        let rank: [SigningCheckState: Int] = [
            .notChecked: 0, .passed: 1, .attention: 2, .unsupported: 3, .blocked: 4
        ]
        if (rank[state] ?? 0) >= (rank[states[area] ?? .notChecked] ?? 0) {
            states[area] = state
        }
    }

    private mutating func add(
        _ code: SigningDiagnosticCode, _ area: SigningDiagnosticArea,
        _ severity: SigningDiagnosticSeverity, _ title: String,
        _ explanation: String, _ technical: String, _ action: String
    ) {
        guard !issues.contains(where: { $0.id == code }) else { return }
        issues.append(SigningDiagnostic(
            id: code, area: area, severity: severity, title: title,
            explanation: explanation, technicalDetails: technical,
            suggestedAction: action
        ))
    }

    private mutating func package(_ evidence: SigningPackageEvidence, record: ApplicationRecord) {
        switch evidence {
        case .missing:
            add(.packageMissing, .package, .error, "Package is missing",
                "ZynSign no longer has this app's IPA, so it cannot inspect or sign it.",
                "The library artifact lookup returned no file.", "Re-import the app before signing.")
            mark(.package, .blocked)
        case .changed:
            add(.packageChanged, .package, .error, "Package changed",
                "The stored IPA no longer has the size recorded when it was imported.",
                "The observed package length differs from the library record.", "Re-import the original IPA and re-run verification.")
            mark(.package, .blocked)
        case .unreadable:
            add(.packageUnreadable, .package, .error, "Package cannot be inspected",
                "ZynSign could not open or enumerate the stored IPA safely.",
                "The bounded archive reader could not produce its entry table.", "Re-import a readable IPA and re-run verification.")
            mark(.package, .blocked)
        case .inspected(let inspection):
            switch inspection.validation.classification {
            case .valid: mark(.package, .passed)
            case .unsupported:
                add(.packageInvalid, .package, .unsupported, "Package layout is unsupported",
                    "The IPA uses an archive feature this build cannot inspect safely.",
                    "Archive structural validation classified the entry table as unsupported.", "Use a package with a supported archive layout.")
                mark(.package, .unsupported)
            case .invalid, .ambiguous:
                add(.packageInvalid, .package, .error, "Package structure needs attention",
                    "The IPA did not pass ZynSign's structural checks.",
                    "Archive structural validation rejected the entry table; no bundle was assumed.", "Re-import a valid IPA and re-run verification.")
                mark(.package, .blocked)
            }
            guard inspection.validation.isValid else { return }
            guard let metadata = inspection.metadata else {
                add(.metadataUnavailable, .metadata,
                    inspection.metadataFailure == .unsupportedMetadataFormat ? .unsupported : .error,
                    "Required app metadata is unavailable",
                    "ZynSign could not establish the app's required bundle information.",
                    "Info.plist could not be read or did not satisfy supported metadata rules.",
                    "Check the app's Info.plist, then re-import the IPA.")
                mark(.metadata, inspection.metadataFailure == .unsupportedMetadataFormat ? .unsupported : .blocked)
                return
            }
            if metadata.identity.bundleIdentifier != record.bundleIdentifier ||
                metadata.executableName != record.executableName {
                add(.metadataChanged, .metadata, .error, "App metadata changed",
                    "The stored package no longer agrees with the library record.",
                    "The reread identifier or executable declaration differs from the imported record.",
                    "Re-import the package and re-run verification.")
                mark(.metadata, .blocked)
            } else {
                mark(.metadata, .passed)
            }
            if !inspection.executablePresent {
                add(.executableMissing, .executable, .error, "Executable is missing",
                    "The app's declared executable is not a regular file inside its bundle.",
                    "The CFBundleExecutable entry could not be resolved as a regular archive entry.",
                    "Use an IPA with its declared executable intact.")
                mark(.executable, .blocked)
            } else if inspection.images.rootSupported == false {
                add(.executableInvalid, .executable, .unsupported, "Executable layout is unsupported",
                    "The main executable does not meet this build's narrow signing layout rules.",
                    "The read-only Mach-O check used the signer's own image admission rule. A readable Mach-O can still be unsupported.",
                    "Use a supported unsigned build; ZynSign cannot rewrite this executable layout.")
                mark(.executable, .unsupported)
            } else if inspection.images.rootSupported == true {
                mark(.executable, .passed)
            } else {
                add(.executableInvalid, .executable, .warning, "Executable not fully inspected",
                    "ZynSign could not establish whether this executable meets its signing layout rules.",
                    "No supported main Mach-O image was established by the bounded read.", "Re-run verification with a readable IPA.")
                mark(.executable, .attention)
            }
            nestedCode(inspection.discovery, images: inspection.images)
        }
    }

    private mutating func nestedCode(_ outcome: NestedCodeDiscoveryOutcome?, images: SigningImageSupport) {
        guard let outcome else {
            add(.nestedUnverified, .nestedCode, .warning, "Nested code not inspected",
                "ZynSign could not finish checking the app's nested signing layout.",
                "No read-only discovery plan was produced.", "Re-run verification with a readable IPA.")
            mark(.nestedCode, .attention)
            return
        }
        switch outcome {
        case .rejected:
            add(.nestedInvalid, .nestedCode, .error, "Nested code layout was rejected",
                "The app's code layout could not be made into a safe signing order.",
                "Read-only nested discovery rejected the bundle; no target was signed.",
                "Check nested bundles and executables, then re-import the IPA.")
            mark(.nestedCode, .blocked)
        case .plan(let plan):
            if !plan.isComplete || images.nestedSupported == false {
                add(.nestedUnsupported, .nestedCode, .unsupported, "Nested code is unsupported",
                    "At least one nested target cannot be signed by this build.",
                    "Discovery found an incomplete target or a binary outside the signer's supported layout.",
                    "Use a package whose nested targets ZynSign can inspect and sign; do not strip code to bypass a check.")
                mark(.nestedCode, .unsupported)
            } else {
                do {
                    _ = try NestedSigningPlanValidator.validate(plan: plan)
                    if images.nestedSupported == true {
                        mark(.nestedCode, .passed)
                    } else {
                        add(.nestedUnverified, .nestedCode, .warning, "Nested signing not fully checked",
                            "ZynSign could not confirm every nested executable's signing layout.",
                            "The plan was coherent, but not every binary passed the signer's image rule.",
                            "Re-run verification with a readable IPA.")
                        mark(.nestedCode, .attention)
                    }
                } catch let failure as NestedSigningFailure {
                    add(.nestedUnsupported, .nestedCode,
                        failure.category == .unsupportedInput ? .unsupported : .error,
                        "Nested signing plan cannot be used",
                        "A discovered target does not satisfy the signing plan rules.",
                        "The signer's read-only plan validator rejected the discovered plan.",
                        "Use a package with supported nested code and re-run verification.")
                    mark(.nestedCode, failure.category == .unsupportedInput ? .unsupported : .blocked)
                } catch {
                    add(.nestedInvalid, .nestedCode, .error, "Nested signing plan could not be checked",
                        "ZynSign could not validate the discovered signing order.",
                        "The read-only signing-plan validation did not complete.", "Re-run verification.")
                    mark(.nestedCode, .blocked)
                }
            }
            let signatures = plan.items.map(\.existingSignature)
            if signatures.contains(where: { if case .malformed = $0 { return true }; return false }) {
                add(.signatureMalformed, .existingSignature, .error, "Existing signature is damaged",
                    "A discovered executable contains a signature that could not be parsed.",
                    "Read-only Mach-O signature inspection found a malformed signature region.",
                    "Use an original unsigned build. ZynSign cannot repair or replace signatures.")
                mark(.existingSignature, .blocked)
            } else if signatures.contains(where: {
                switch $0 { case .structurallyParsed, .incompleteSlices, .unsupported: return true; default: return false }
            }) {
                add(.signaturePresent, .existingSignature, .error, "App is already signed",
                    "At least one executable carries an existing signature. This pipeline only signs unsigned code.",
                    "Read-only inspection found a code-signature region. Its validity and trust were not evaluated.",
                    "Use the original unsigned app. Replacing an existing signature is not supported.")
                mark(.existingSignature, .blocked)
            } else if signatures.allSatisfy({ $0 == .absent }) {
                mark(.existingSignature, .passed)
            } else {
                add(.signatureUnverified, .existingSignature, .warning, "Signature state is unknown",
                    "ZynSign could not inspect every executable for an existing signature.",
                    "One or more candidate images could not be read within the inspection bounds.",
                    "Re-run verification with a readable IPA.")
                mark(.existingSignature, .attention)
            }
        }
    }

    private mutating func identity(_ evidence: SigningIdentityEvidence, at date: Date) {
        switch evidence {
        case .notSelected:
            add(.certificateMissing, .certificate, .error, "Select a signing certificate",
                "No signing identity is selected. A certificate alone is not enough without its matching private key.",
                "No identity identifier was provided for the Keychain metadata lookup.",
                "Select a valid signing identity in Certificates.")
            mark(.certificate, .blocked)
        case .unavailable, .storeUnavailable:
            add(.certificateUnavailable, .certificate, .error, "Certificate is unavailable",
                "ZynSign cannot use the selected signing identity right now.",
                "The selected identity is absent or its metadata could not be read; no key was accessed.",
                "Select a valid certificate or re-import the matching identity.")
            mark(.certificate, .blocked)
        case .selected(let selected):
            if !selected.isUsableForSigning {
                add(.certificateUnavailable, .certificate, .error, "Signing key is not ready",
                    "The selected certificate does not currently have an established, usable signing capability.",
                    "Key availability, certificate-to-key association or capability state was not ready at the metadata lookup.",
                    "Select a valid identity with its matching private key, then re-run verification.")
                mark(.certificate, .blocked)
            } else { mark(.certificate, .passed) }
            switch CertificateValidity.evaluate(certificate: selected.certificate, at: date).periodStatus {
            case .expired:
                add(.certificateExpired, .certificate, .error, "Certificate expired",
                    "This certificate's declared validity period has ended.",
                    "The certificate's NotAfter date is before this scan's evaluation time.",
                    "Select a current signing certificate and a profile that includes it.")
                mark(.certificate, .blocked)
            case .notYetValid:
                add(.certificateNotYetValid, .certificate, .error, "Certificate is not yet valid",
                    "This certificate's declared validity period has not started.",
                    "The certificate's NotBefore date is after this scan's evaluation time.",
                    "Select a currently valid certificate.")
                mark(.certificate, .blocked)
            case .currentlyValid:
                if selected.certificate.notValidAfter.timeIntervalSince(date) < 30 * 86_400 {
                    add(.certificateExpiring, .certificate, .warning, "Certificate expires soon",
                        "The selected certificate expires within 30 days.",
                        "The declared NotAfter date is less than 30 days from the scan time.",
                        "Plan to renew the certificate and obtain a matching profile.")
                    mark(.certificate, .attention)
                }
            }
            if selected.certificate.publicKeyInfo.algorithm != .rsa {
                add(.certificateAlgorithmUnsupported, .certificate, .unsupported, "Key algorithm is unsupported",
                    "This build's application signer currently requires an RSA signing identity.",
                    "The signing pipeline uses RSA PKCS #1 with SHA-256; certificate metadata describes another key family.",
                    "Select a matching RSA signing identity. ZynSign cannot convert keys.")
                mark(.certificate, .unsupported)
            }
        }
    }

    private mutating func profile(_ evidence: SigningProfileEvidence, identitySelected: Bool, at date: Date) {
        switch evidence {
        case .notSelected:
            add(.profileMissing, .profile, .error, "Select a provisioning profile",
                "No profile has been selected for this signing run.",
                "No profile bytes were supplied to the CMS verification boundary.",
                "Choose a matching, current .mobileprovision file.")
            mark(.profile, .blocked)
        case .failed(let problem):
            switch problem {
            case .invalid:
                add(.profileInvalid, .profile, .error, "Profile cannot be used",
                    "The profile's authenticated payload or required metadata did not pass validation.",
                    "The profile verification pipeline rejected the container or its structural checks.",
                    "Refresh the profile from your developer account and re-run verification.")
                mark(.profile, .blocked)
            case .unauthenticated:
                add(.profileUnverified, .profile, .error, "Profile authentication failed",
                    "ZynSign could not authenticate the selected profile's contents.",
                    "The CMS container did not establish an authenticated payload; no policy comparison was trusted.",
                    "Use an authentic profile and re-run verification.")
                mark(.profile, .blocked)
            case .unsupported:
                add(.profileUnsupported, .profile, .unsupported, "Profile format is unsupported",
                    "This build cannot evaluate the selected profile's container safely.",
                    "The CMS/profile pipeline reported an unsupported input form.",
                    "Choose a supported profile; do not bypass its signature check.")
                mark(.profile, .unsupported)
            case .unreadable:
                add(.profileUnverified, .profile, .error, "Profile could not be checked",
                    "The selected profile could not be verified, so compatibility is unknown.",
                    "The bounded profile verification did not return authenticated evidence.",
                    "Choose a readable profile and re-run verification.")
                mark(.profile, .blocked)
            }
        case .verified(let policy, let expiration, let claimsRepresentable):
            mark(.profile, .passed)
            switch policy.profileValidity {
            case .satisfied:
                if let expiration, expiration.timeIntervalSince(date) < 30 * 86_400 {
                    add(.profileExpiring, .profile, .warning, "Profile expires soon",
                        "The selected profile expires within 30 days.",
                        "The authenticated ExpirationDate is less than 30 days from this scan.",
                        "Refresh the profile before it expires.")
                    mark(.profile, .attention)
                }
            case .violated:
                let expired = policy.result(for: .profileValidity)?.findings.contains(where: { $0.code == .profileExpired }) == true
                add(expired ? .profileExpired : .profileNotYetValid, .profile, .error,
                    expired ? "Profile expired" : "Profile validity period is not current",
                    expired ? "This provisioning profile has expired and cannot be used for new signing operations." : "The profile's declared validity period does not include the current time.",
                    "The authenticated profile dates failed the provisioning validity rule.",
                    "Refresh the provisioning profile and re-run verification.")
                mark(.profile, .blocked)
            case .indeterminate:
                add(.profileUnverified, .profile, .unsupported, "Profile validity is uncertain",
                    "ZynSign could not establish the profile's current validity period.",
                    "The authenticated profile dates were missing or not comparable.", "Choose a complete, current profile.")
                mark(.profile, .unsupported)
            }
            policyArea(policy.profileType, area: .profile, mismatch: .profilePolicyMismatch, unknown: .profileUnverified,
                       title: "Profile type cannot be confirmed", explanation: "The profile's declared distribution type could not be established.",
                       action: "Choose a profile with a supported distribution type.")
            switch policy.platform {
            case .satisfied: break
            case .violated:
                add(.platformMismatch, .profile, .error, "Profile platform does not match",
                    "This profile does not declare a platform the app is intended to run on.",
                    "The authenticated profile's Platform list and the app's declared device families did not overlap.",
                    "Choose a profile intended for this app's platform.")
                mark(.profile, .blocked)
            case .indeterminate:
                add(.platformUnverified, .profile, .unsupported, "Platform match is unknown",
                    "The app or profile did not establish comparable platform information.",
                    "The provisioning platform policy returned indeterminate; the signing pipeline does not treat that as a pass.",
                    "Use a profile and app with comparable platform declarations.")
                mark(.profile, .unsupported)
            }
            switch policy.device {
            case .satisfied: break
            case .violated:
                add(.deviceMismatch, .profile, .error, "Device is not covered",
                    "The supplied device context was not in this profile's device list.",
                    "The provisioning device rule reported a mismatch. No device identifier is retained in history.",
                    "Choose a profile that covers the target device.")
                mark(.profile, .blocked)
            case .indeterminate:
                add(.deviceUnverified, .profile, .unsupported, "Device coverage cannot be checked here",
                    "This profile restricts devices, but ZynSign has no verified target-device identifier to compare.",
                    "The device policy is indeterminate; the current signing pipeline will not treat it as compatible.",
                    "Verify device coverage outside ZynSign or choose an appropriate profile without an uncheckable restriction.")
                mark(.profile, .unsupported)
            }
            policyArea(policy.bundleIdentifier, area: .bundleIdentifier, mismatch: .bundleMismatch, unknown: .bundleUnverified,
                       title: "Bundle ID does not match", explanation: "The profile's App ID does not cover this app's bundle identifier.",
                       action: "Use a matching profile; ZynSign will not change the app's bundle ID.")
            if identitySelected {
                policyArea(policy.teamIdentifier, area: .teamIdentifier, mismatch: .teamMismatch, unknown: .teamUnverified,
                           title: "Team ID does not match", explanation: "The certificate's structured team information conflicts with the profile.",
                           action: "Select a certificate and profile from the same team.")
                policyArea(policy.certificate, area: .certificate, mismatch: .certificateProfileMismatch, unknown: .certificateUnverified,
                           title: "Certificate is not in the profile", explanation: "The selected signing certificate is not authorized by this profile's certificate list.",
                           action: "Use a profile that includes the selected certificate or select a matching identity.")
            }
            if !claimsRepresentable {
                add(.entitlementsInvalid, .entitlements, .error, "Entitlements cannot be prepared",
                    "The authenticated profile's claims cannot be represented by this signer's entitlement model.",
                    "The exact profile claims failed structural conversion; ZynSign will not silently substitute an empty set.",
                    "Use a supported profile and re-run verification.")
                mark(.entitlements, .blocked)
            } else {
                policyArea(policy.entitlements, area: .entitlements, mismatch: .entitlementsMismatch, unknown: .entitlementsUnverified,
                           title: "Entitlements do not match", explanation: "At least one requested claim is not covered by the profile.",
                           action: "Use a profile that authorizes the claims; do not add unsupported entitlements.")
            }
        }
    }

    private mutating func policyArea(
        _ status: ProvisioningPolicyStatus, area: SigningDiagnosticArea,
        mismatch: SigningDiagnosticCode, unknown: SigningDiagnosticCode,
        title: String, explanation: String, action: String
    ) {
        switch status {
        case .satisfied: mark(area, .passed)
        case .violated:
            add(mismatch, area, .error, title, explanation,
                "The authenticated provisioning policy returned a violation for this check.", action)
            mark(area, .blocked)
        case .indeterminate:
            add(unknown, area, .unsupported, "\(area.title) could not be confirmed",
                "ZynSign cannot compare the available evidence for this check; the signing pipeline will not treat it as a pass.",
                "The authenticated provisioning policy returned indeterminate, not satisfied.",
                "Check the selected certificate and profile, then re-run verification.")
            mark(area, .unsupported)
        }
    }
}
