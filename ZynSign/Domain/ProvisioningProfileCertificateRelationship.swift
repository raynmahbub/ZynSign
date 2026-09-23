import Foundation

/// Whether a CMS signer certificate and a profile's own certificate
/// information correspond.
///
/// Comparison uses cryptographic identity — the SHA-256 fingerprint of exact
/// certificate DER — and never a subject name, a label, or an issuer name. A
/// match says two certificate encodings are the same certificate. It does not
/// say the profile is authentic on its own, that a private key for that
/// certificate exists on this device, that the certificate is trusted, or that
/// Apple authorized anything.
enum CertificateMatchOutcome: String, CaseIterable, Equatable, Hashable {

    /// No comparison was possible because there was no signer certificate.
    case notEvaluated

    /// The signer certificate is one of the certificates the profile names.
    case matched

    /// The profile names certificates, and none of them is the signer.
    case mismatched

    /// More than one embedded certificate could be the signer, so no single
    /// comparison is meaningful.
    case ambiguous

    /// A signer certificate exists but the profile offers nothing comparable:
    /// no certificate entries, entries whose metadata could not be attached, or
    /// a profile that was never parsed because the container did not verify.
    /// This is not a mismatch — nothing was found to disagree.
    case incomparable

    /// Whether the two sides were shown to be the same certificate.
    var isMatched: Bool { self == .matched }
}

/// What the local signing-identity lookup produced.
///
/// "No store was consulted" and "the store could not be read" are different
/// facts and must not collapse into one another: the first means the question
/// was not asked, the second means the answer is unknown. Neither is a claim
/// about the profile.
enum LocalSigningIdentityLookup: Equatable, Hashable {

    /// No identity store was supplied, so the question was not asked.
    case notRequested

    /// The identities an identity store listed. An empty list is an answer, not
    /// a failure.
    case identities([SigningIdentity])

    /// The identity store could not be read.
    case failed
}

/// Whether a locally available signing identity's certificate is one the
/// profile names.
///
/// This is a certificate-presence question answered from identity metadata
/// only. It is deliberately not answered by performing a signing operation, and
/// a match is not platform authorization: possessing a private key for a
/// certificate a profile names does not make the profile valid, the certificate
/// trusted, or an application signable.
enum LocalSigningIdentityRelationship: Equatable, Hashable {

    /// No identity store was consulted.
    case notEvaluated

    /// Exactly one available identity's certificate is named by the profile.
    case matched(SigningIdentityIdentifier)

    /// More than one available identity's certificate is named by the profile.
    /// ZynSign does not choose between them.
    case multipleMatches(Int)

    /// No available identity's certificate is named by the profile.
    case noMatch

    /// The identity store could not be read, so no conclusion is drawn.
    case lookupFailed

    /// Whether a single local identity was related to the profile.
    var isMatched: Bool {
        if case .matched = self { return true }
        return false
    }
}

/// The certificate relationships around one provisioning profile, kept as
/// separate facts.
///
/// Four questions are answered independently, because they are independent:
///
/// 1. is there a signer certificate in the CMS message;
/// 2. does the profile itself carry certificate references;
/// 3. do the two correspond by cryptographic identity;
/// 4. is a locally available signing identity's certificate among them.
///
/// Nothing here is a trust evaluation and nothing here is an authorization
/// decision; `trustEvaluation` is carried so that a caller cannot read a match
/// as trust. Fingerprints are the only certificate rendering intended to leave
/// this value.
struct ProvisioningProfileCertificateRelationship: Equatable, Hashable {

    /// How signer-certificate extraction ended at the CMS boundary.
    let signerCertificateStatus: CMSSignerCertificateStatus

    /// The signer certificate's fingerprint, when a signer certificate exists.
    let signerFingerprint: CertificateFingerprint?

    /// How many certificate references the profile carried.
    let profileCertificateCount: Int

    /// The fingerprints of the profile's certificate references, in profile
    /// order, including duplicates. References whose metadata could not be
    /// attached contribute no fingerprint.
    let profileCertificateFingerprints: [CertificateFingerprint]

    /// How many profile references carried no parseable metadata and therefore
    /// could not be compared.
    let profileReferenceWithoutMetadataCount: Int

    /// How many profile references repeat a certificate already listed.
    let duplicateProfileCertificateCount: Int

    /// The signer/profile comparison outcome.
    let match: CertificateMatchOutcome

    /// The local signing-identity relationship.
    let localSigningIdentity: LocalSigningIdentityRelationship

    /// The private-key availability reported for the matched identity, when
    /// exactly one matched. Reported separately from the match because a
    /// certificate match is not private-key possession.
    let localSigningIdentityKeyAvailability: SigningKeyAvailability?

    /// Trust evaluation state. Always `.notPerformed` in this increment.
    let trustEvaluation: CMSTrustEvaluationStatus

    init(
        signerCertificateStatus: CMSSignerCertificateStatus,
        signerFingerprint: CertificateFingerprint? = nil,
        profileCertificateCount: Int = 0,
        profileCertificateFingerprints: [CertificateFingerprint] = [],
        profileReferenceWithoutMetadataCount: Int = 0,
        duplicateProfileCertificateCount: Int = 0,
        match: CertificateMatchOutcome = .notEvaluated,
        localSigningIdentity: LocalSigningIdentityRelationship = .notEvaluated,
        localSigningIdentityKeyAvailability: SigningKeyAvailability? = nil,
        trustEvaluation: CMSTrustEvaluationStatus = .notPerformed
    ) {
        self.signerCertificateStatus = signerCertificateStatus
        self.signerFingerprint = signerFingerprint
        self.profileCertificateCount = profileCertificateCount
        self.profileCertificateFingerprints = profileCertificateFingerprints
        self.profileReferenceWithoutMetadataCount = profileReferenceWithoutMetadataCount
        self.duplicateProfileCertificateCount = duplicateProfileCertificateCount
        self.match = match
        self.localSigningIdentity = localSigningIdentity
        self.localSigningIdentityKeyAvailability = localSigningIdentityKeyAvailability
        self.trustEvaluation = trustEvaluation
    }

    /// Fact 1: the CMS message yielded a signer certificate.
    var signerCertificatePresent: Bool { signerCertificateStatus.isExtracted }

    /// Fact 2: the profile itself carries certificate information.
    var profileCertificateReferencePresent: Bool { profileCertificateCount > 0 }

    /// Fact 3: the signer certificate and a profile certificate are the same
    /// certificate. Not private-key possession, not trust, not authorization.
    var isCertificateMatch: Bool { match.isMatched }

    /// Fact 4: a locally available identity's certificate is named by the
    /// profile. Not Apple authorization.
    var hasLocalSigningIdentityForProfileCertificate: Bool { localSigningIdentity.isMatched }

    /// A redacted diagnostic rendering: states, counts, and fingerprints only.
    var diagnosticDescription: String {
        var parts = [
            "relationship.signer(\(signerCertificateStatus.rawValue))",
            "relationship.profileCertificates(\(profileCertificateCount))",
            "relationship.comparable(\(profileCertificateFingerprints.count))",
            "relationship.duplicates(\(duplicateProfileCertificateCount))",
            "relationship.match(\(match.rawValue))",
            "relationship.trust(\(trustEvaluation.rawValue))",
        ]
        if let signerFingerprint {
            parts.append("relationship.signerFingerprint(\(signerFingerprint.hexDigest))")
        }
        switch localSigningIdentity {
        case .notEvaluated: parts.append("relationship.localIdentity(notEvaluated)")
        case .matched(let identifier): parts.append("relationship.localIdentity(matched \(identifier.rawValue))")
        case .multipleMatches(let count): parts.append("relationship.localIdentity(multiple \(count))")
        case .noMatch: parts.append("relationship.localIdentity(noMatch)")
        case .lookupFailed: parts.append("relationship.localIdentity(lookupFailed)")
        }
        if let localSigningIdentityKeyAvailability {
            parts.append("relationship.localKey(\(localSigningIdentityKeyAvailability.rawValue))")
        }
        return parts.joined(separator: " ")
    }
}

/// Relates a CMS signer certificate to the certificate information a profile
/// carries, and to the signing identities available locally.
///
/// The analyzer is pure: it compares values it is given and performs no
/// cryptography, no keychain access, no signing operation, and no trust
/// evaluation. Certificates are compared by the SHA-256 fingerprint of their
/// exact DER encoding, so duplicate entries, reordered entries, and entries
/// whose metadata could not be attached each produce an explicit outcome
/// instead of a guess.
struct CertificateRelationshipAnalyzer {

    init() {}

    /// Establishes the relationship facts.
    ///
    /// - Parameters:
    ///   - signerCertificateStatus: How signer-certificate extraction ended.
    ///   - signerCertificate: The signer's certificate, when one was extracted.
    ///   - profileCertificates: The profile's certificate references, or `nil`
    ///     when the profile was not parsed or carries no such field.
    ///   - localIdentities: What the local identity lookup produced.
    func analyze(
        signerCertificateStatus: CMSSignerCertificateStatus,
        signerCertificate: Certificate?,
        profileCertificates: [ProvisioningProfileCertificateReference]?,
        localIdentities: LocalSigningIdentityLookup
    ) -> ProvisioningProfileCertificateRelationship {
        let references = profileCertificates ?? []
        var fingerprints: [CertificateFingerprint] = []
        var unique: [CertificateFingerprint] = []
        var withoutMetadata = 0
        fingerprints.reserveCapacity(references.count)
        for reference in references {
            guard let fingerprint = reference.fingerprint else {
                withoutMetadata += 1
                continue
            }
            fingerprints.append(fingerprint)
            if !unique.contains(fingerprint) {
                unique.append(fingerprint)
            }
        }
        let duplicates = fingerprints.count - unique.count

        let match = matchOutcome(
            signerCertificateStatus: signerCertificateStatus,
            signerCertificate: signerCertificate,
            comparableFingerprints: unique
        )
        let (localRelationship, localAvailability) = localIdentityRelationship(
            identities: localIdentities,
            profileFingerprints: unique
        )

        return ProvisioningProfileCertificateRelationship(
            signerCertificateStatus: signerCertificateStatus,
            signerFingerprint: signerCertificate?.fingerprint,
            profileCertificateCount: references.count,
            profileCertificateFingerprints: fingerprints,
            profileReferenceWithoutMetadataCount: withoutMetadata,
            duplicateProfileCertificateCount: duplicates,
            match: match,
            localSigningIdentity: localRelationship,
            localSigningIdentityKeyAvailability: localAvailability
        )
    }

    private func matchOutcome(
        signerCertificateStatus: CMSSignerCertificateStatus,
        signerCertificate: Certificate?,
        comparableFingerprints: [CertificateFingerprint]
    ) -> CertificateMatchOutcome {
        if signerCertificateStatus == .ambiguous {
            return .ambiguous
        }
        guard let signerCertificate else { return .notEvaluated }
        guard !comparableFingerprints.isEmpty else { return .incomparable }
        return comparableFingerprints.contains(signerCertificate.fingerprint) ? .matched : .mismatched
    }

    private func localIdentityRelationship(
        identities lookup: LocalSigningIdentityLookup,
        profileFingerprints: [CertificateFingerprint]
    ) -> (LocalSigningIdentityRelationship, SigningKeyAvailability?) {
        let identities: [SigningIdentity]
        switch lookup {
        case .notRequested:
            return (.notEvaluated, nil)
        case .failed:
            return (.lookupFailed, nil)
        case .identities(let listed):
            identities = listed
        }
        var matches: [SigningIdentity] = []
        for identity in identities where profileFingerprints.contains(identity.fingerprint) {
            matches.append(identity)
        }
        switch matches.count {
        case 0:
            return (.noMatch, nil)
        case 1:
            guard let identity = matches.first else { return (.noMatch, nil) }
            return (.matched(identity.id), identity.keyAvailability)
        default:
            return (.multipleMatches(matches.count), nil)
        }
    }
}
