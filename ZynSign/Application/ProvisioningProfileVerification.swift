import Foundation

/// How far profile parsing got during verification.
///
/// Parsing is attempted only for a container whose CMS signature verified.
/// Payload parsing is therefore not a separate way to reach unauthenticated
/// profile metadata: a container that did not verify contributes evidence about
/// itself and no parsed profile at all.
enum ProvisioningProfileVerificationParsingState: String, CaseIterable, Equatable, Hashable {

    /// The CMS boundary did not verify the container, so no payload was parsed.
    case notAttempted

    /// The authenticated payload was parsed into typed profile metadata.
    case parsed
}

/// A safe, high-level rendering of one profile verification.
///
/// This is the only shape intended for presentation. It carries states, counts,
/// and the signer certificate's fingerprint — never container bytes, payload
/// bytes, certificate bodies, or platform error text — and it offers no action:
/// nothing here signs, re-signs, installs, generates, or modifies a profile.
struct ProvisioningProfileVerificationSummary: Equatable, Hashable {

    /// Whether the authenticated payload was parsed into profile metadata.
    let profileParsed: Bool

    /// Whether the parsed profile satisfied the structural validator.
    let structurallyValid: Bool

    /// Whether the parsed profile's validity period contains the evaluation
    /// instant. A period fact, not a trust or authorization fact.
    let currentlyValid: Bool

    /// The CMS signature outcome.
    let cmsSignatureStatus: CMSSignatureVerificationStatus

    /// Whether a signer certificate was extracted from the container.
    let signerCertificatePresent: Bool

    /// The signer certificate's SHA-256 fingerprint, hexadecimal text only.
    let signerCertificateFingerprint: String?

    /// The signer/profile certificate comparison outcome.
    let certificateMatch: CertificateMatchOutcome

    /// The local signing-identity relationship.
    let localSigningIdentity: LocalSigningIdentityRelationship

    /// Trust evaluation state. Always `.notPerformed` in this increment.
    let trustEvaluation: CMSTrustEvaluationStatus

    /// Authorization state. Always `.notEvaluated` in this increment.
    let authorization: ProvisioningProfileAuthorizationStatus
}

/// The application-layer result of verifying one provisioning profile.
///
/// Each security claim keeps its own evidence, and there is deliberately no
/// `isValid`:
///
/// - parsing — `parsingState` and `inspection?.profile`;
/// - structural validity — `inspection?.validation`;
/// - CMS authenticity — `cms.status`, with the signer, payload, and attribute
///   evidence that produced it;
/// - certificate relationship — `certificateRelationship`;
/// - certificate trust — `trustEvaluation`, never performed here;
/// - platform authorization — `authorization`, never evaluated here.
///
/// A verified CMS signature means the payload is the payload the signer's key
/// signed. It does not mean the signer's certificate is trusted, that Apple
/// issued it, that ZynSign holds its private key, or that the profile
/// authorizes anything.
struct ProvisioningProfileVerification: Equatable, Hashable {

    /// The CMS evidence.
    let cms: CMSVerificationResult

    /// The parsed and structurally validated profile, when parsing was attempted.
    let inspection: ProvisioningProfileInspection?

    /// Whether parsing was attempted.
    let parsingState: ProvisioningProfileVerificationParsingState

    /// The signer/profile/local-identity certificate relationships.
    let certificateRelationship: ProvisioningProfileCertificateRelationship

    /// Certificate-chain trust evaluation state.
    let trustEvaluation: CMSTrustEvaluationStatus

    /// Platform authorization state.
    let authorization: ProvisioningProfileAuthorizationStatus

    init(
        cms: CMSVerificationResult,
        inspection: ProvisioningProfileInspection?,
        parsingState: ProvisioningProfileVerificationParsingState,
        certificateRelationship: ProvisioningProfileCertificateRelationship,
        trustEvaluation: CMSTrustEvaluationStatus = .notPerformed,
        authorization: ProvisioningProfileAuthorizationStatus = .notEvaluated
    ) {
        self.cms = cms
        self.inspection = inspection
        self.parsingState = parsingState
        self.certificateRelationship = certificateRelationship
        self.trustEvaluation = trustEvaluation
        self.authorization = authorization
    }

    /// The parsed profile, when there is one.
    var profile: ProvisioningProfile? { inspection?.profile }

    /// Whether a parsed profile exists.
    var isParsed: Bool { inspection != nil }

    /// Whether the parsed profile satisfied the structural validator.
    var isStructurallyValid: Bool { inspection?.isStructurallyValid == true }

    /// Whether the parsed profile's validity period contains the evaluation
    /// instant.
    var isCurrentlyValid: Bool { inspection?.isCurrentlyValid == true }

    /// Whether the CMS signature verified and the payload carries that
    /// evidence. Distinct from trust and from authorization.
    var isCMSAuthenticated: Bool {
        cms.status.isVerified && authenticity == .authenticated
    }

    /// The authenticity state carried by the parsed payload, or the state the
    /// CMS outcome implies when no payload was parsed.
    ///
    /// A definitive CMS rejection is `.rejected`; an outcome that reached no
    /// cryptographic conclusion — an unavailable mechanism, an unsupported
    /// algorithm, a signer certificate that could not be obtained — is
    /// `.notEvaluated`, because unknown authenticity must not be reported as
    /// inauthenticity.
    var authenticity: ProvisioningProfileAuthenticityStatus {
        if let inspection { return inspection.authenticity }
        if cms.status.isVerified { return .authenticated }
        return cms.status.isRejection ? .rejected : .notEvaluated
    }

    /// The signer certificate's fingerprint, when one was extracted.
    var signerFingerprint: CertificateFingerprint? { cms.signerFingerprint }

    /// The presentation-safe rendering of this result.
    var summary: ProvisioningProfileVerificationSummary {
        ProvisioningProfileVerificationSummary(
            profileParsed: isParsed,
            structurallyValid: isStructurallyValid,
            currentlyValid: isCurrentlyValid,
            cmsSignatureStatus: cms.status,
            signerCertificatePresent: certificateRelationship.signerCertificatePresent,
            signerCertificateFingerprint: cms.signerFingerprint?.hexDigest,
            certificateMatch: certificateRelationship.match,
            localSigningIdentity: certificateRelationship.localSigningIdentity,
            trustEvaluation: trustEvaluation,
            authorization: authorization
        )
    }

    /// A redacted diagnostic rendering of every stage's evidence.
    var diagnosticDescription: String {
        [
            "profile.parsing(\(parsingState.rawValue))",
            "profile.structurallyValid(\(isStructurallyValid))",
            "profile.authenticity(\(authenticity.rawValue))",
            "profile.authorization(\(authorization.rawValue))",
            cms.description,
            certificateRelationship.diagnosticDescription,
        ].joined(separator: " ")
    }
}

/// Verifies one provisioning-profile container and reports what each stage
/// established.
///
/// The use case orchestrates and nothing else. It does not read ASN.1 or CMS
/// structures, does not own keychain logic, does not perform a signing
/// operation, does not evaluate a certificate chain, does not decide
/// entitlement, device, bundle, or profile-type compatibility, and does not
/// persist the profile, its payload, or its certificates. Low-level work stays
/// behind the `CMSVerifier` port and the existing ZS-017 parser and validator.
///
/// Sequence:
///
///     ProvisioningProfileVerificationUseCase
///             ↓
///     CMSVerifier → CMSVerificationResult → authenticated payload
///             ↓
///     existing ProvisioningProfileParser/Validator → ProvisioningProfile
///             ↓
///     CertificateRelationshipAnalyzer → relationship facts
struct ProvisioningProfileVerificationUseCase {

    private let cmsVerifier: any CMSVerifier
    private let inspection: ProvisioningProfileInspectionUseCase
    private let identityStore: (any IdentityStore)?
    private let relationshipAnalyzer: CertificateRelationshipAnalyzer

    /// - Parameters:
    ///   - cmsVerifier: The CMS boundary.
    ///   - inspection: The existing parsing and structural-validation use case.
    ///   - identityStore: An optional read-only source of local signing
    ///     identities. Only its listing is used; a signing capability is never
    ///     requested and no signature is produced to establish a relationship.
    ///   - relationshipAnalyzer: The pure comparison rules.
    init(
        cmsVerifier: any CMSVerifier,
        inspection: ProvisioningProfileInspectionUseCase,
        identityStore: (any IdentityStore)? = nil,
        relationshipAnalyzer: CertificateRelationshipAnalyzer = CertificateRelationshipAnalyzer()
    ) {
        self.cmsVerifier = cmsVerifier
        self.inspection = inspection
        self.identityStore = identityStore
        self.relationshipAnalyzer = relationshipAnalyzer
    }

    /// Verifies raw profile input.
    ///
    /// - Throws: A typed `ZynSignError` when the input is empty or oversized,
    ///   when the container is not a decodable CMS message of a supported
    ///   shape, or when an authenticated payload could not be parsed. A
    ///   container that decoded but did not verify is returned as evidence
    ///   rather than thrown, so a caller can distinguish a rejected container
    ///   from one that could not be evaluated.
    /// - Returns: The staged evidence. A `.verified` CMS status is not a trust
    ///   or authorization result; `trustEvaluation` stays `.notPerformed` and
    ///   `authorization` stays `.notEvaluated`.
    func verify(_ input: ProvisioningProfileInput) throws -> ProvisioningProfileVerification {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.emptyProvisioningProfile()
        }
        guard input.bytes.count <= ProvisioningProfileInput.maximumByteCount else {
            throw ZynSignError.provisioningProfileInputTooLarge(
                diagnosticDetail: "The raw profile input exceeded the configured byte bound."
            )
        }

        let cms: CMSVerificationResult
        do {
            cms = try cmsVerifier.verify(input)
        } catch let error as ZynSignError
            where error.cmsFailure != nil || error.provisioningProfileFailure != nil {
            throw error
        } catch {
            throw ZynSignError.cms(
                .decodeFailed,
                diagnosticDetail: "CMS verification failed (cause: \(Self.safeCauseSummary(error)))."
            )
        }

        var inspectionResult: ProvisioningProfileInspection?
        if cms.status.isVerified {
            guard let payload = cms.profilePayload() else {
                throw ZynSignError.cms(
                    .payloadUnavailable,
                    diagnosticDetail: "The verified CMS message carried no payload to parse."
                )
            }
            inspectionResult = try inspection.inspect(payload: payload)
        }

        let relationship = relationshipAnalyzer.analyze(
            signerCertificateStatus: cms.signerCertificateStatus,
            signerCertificate: cms.signerCertificate,
            profileCertificates: inspectionResult?.profile.developerCertificates,
            localIdentities: localIdentityLookup()
        )

        return ProvisioningProfileVerification(
            cms: cms,
            inspection: inspectionResult,
            parsingState: inspectionResult == nil ? .notAttempted : .parsed,
            certificateRelationship: relationship,
            trustEvaluation: cms.trustEvaluation,
            authorization: .notEvaluated
        )
    }

    /// Reads identity metadata for the relationship question only.
    ///
    /// A store that cannot be read is recorded as a failed lookup rather than
    /// as an absent relationship, and rather than as a verification failure: an
    /// unreadable identity store says nothing about the profile. No capability
    /// is requested and nothing is signed.
    private func localIdentityLookup() -> LocalSigningIdentityLookup {
        guard let identityStore else { return .notRequested }
        do {
            return .identities(try identityStore.listIdentities())
        } catch {
            return .failed
        }
    }

    private static func safeCauseSummary(_ error: any Error) -> String {
        if let cocoaError = error as? NSError {
            return "platform error code \(cocoaError.code)"
        }
        return String(describing: type(of: error))
    }
}
