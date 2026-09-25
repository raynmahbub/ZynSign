import Foundation

/// Assesses whether a (identity, provisioning profile, bundle) combination
/// is likely to succeed at signing, without running the signing pipeline.
///
/// The assessment is purely informational — a low score does not block
/// signing, because ZynSign does not refuse to run the pipeline on
/// legitimate user intent. The score explains, in plain terms, what the
/// pipeline will probably say.
///
/// The inputs are domain values: certificate metadata, profile summary,
/// and the bundle identifier of the application. The output is a
/// `SigningHealthScore` value with a numeric score (0…100), a band
/// (excellent … risky), and a list of findings explaining why.
///
/// The assessment is an actor-isolated class so it can hold a clock for
/// deterministic tests.
actor SigningHealthAssessment {

    /// The certificate metadata to assess against, when known.
    private let certificate: CertificateMetadata?

    /// The key availability the identity store reported.
    private let keyAvailability: SigningKeyAvailability

    /// Whether the key is non-exportable (a positive signal).
    private let isKeyNonExportable: Bool?

    /// The provisioning profile summary to assess against, when known.
    private let profile: ProvisioningProfileSummary?

    /// The bundle identifier of the application the user wants to sign.
    private let bundleIdentifier: String?

    /// The clock used to evaluate expiry windows. Injectable for tests.
    private let now: @Sendable () -> Date

    init(
        certificate: CertificateMetadata?,
        keyAvailability: SigningKeyAvailability = .unknown,
        isKeyNonExportable: Bool? = nil,
        profile: ProvisioningProfileSummary?,
        bundleIdentifier: String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.certificate = certificate
        self.keyAvailability = keyAvailability
        self.isKeyNonExportable = isKeyNonExportable
        self.profile = profile
        self.bundleIdentifier = bundleIdentifier
        self.now = now
    }

    /// Computes the assessment.
    func assess() -> SigningHealthScore {
        var findings: [SigningHealthScore.Finding] = []
        var score = 50   // start neutral: we have no reason to recommend or warn yet.

        // --- Inputs gate ---
        if certificate == nil {
            findings.append(SigningHealthScore.Finding(
                id: "missing.certificate",
                title: "No certificate selected",
                detail: "Choose a signing certificate from Settings → Certificates before signing.",
                weight: -30
            ))
            score -= 30
        }
        if profile == nil {
            findings.append(SigningHealthScore.Finding(
                id: "missing.profile",
                title: "No provisioning profile selected",
                detail: "Choose a .mobileprovision file before signing. Without a profile, the signed application cannot be installed.",
                weight: -30
            ))
            score -= 30
        }
        if bundleIdentifier == nil {
            findings.append(SigningHealthScore.Finding(
                id: "missing.bundle",
                title: "No bundle identifier",
                detail: "The application to sign has no bundle identifier. ZynSign cannot pick a matching profile.",
                weight: -25
            ))
            score -= 25
        }

        // --- Strengths ---
        if let key = isKeyNonExportable, key {
            findings.append(SigningHealthScore.Finding(
                id: "key.nonExportable",
                title: "Private key cannot be exported",
                detail: "Your private key stays inside the Keychain and never leaves the device. That is the strongest protection ZynSign can verify.",
                weight: 8
            ))
            score += 8
        }
        if keyAvailability.isAvailable {
            findings.append(SigningHealthScore.Finding(
                id: "key.available",
                title: "Private key is available",
                detail: "The Keychain reports the private key is ready to use.",
                weight: 5
            ))
            score += 5
        } else if keyAvailability == .unknown {
            findings.append(SigningHealthScore.Finding(
                id: "key.unknown",
                title: "Key availability not confirmed",
                detail: "ZynSign could not confirm the private key is currently usable. Signing may fail at the cryptographic step.",
                weight: -8
            ))
            score -= 8
        } else {
            findings.append(SigningHealthScore.Finding(
                id: "key.unavailable",
                title: "Private key is not available",
                detail: "The Keychain reports the private key cannot be used right now. Signing will fail until the key is restored.",
                weight: -25
            ))
            score -= 25
        }

        // --- Expiry windows ---
        var certificateExpiry: Date?
        var profileExpiry: Date?
        if let certificate {
            certificateExpiry = certificate.notValidAfter
            let days = daysUntil(certificate.notValidAfter)
            if days < 0 {
                findings.append(SigningHealthScore.Finding(
                    id: "cert.expired",
                    title: "Certificate has expired",
                    detail: "This certificate stopped being valid \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago. Apple will refuse any signature made with it.",
                    weight: -45
                ))
                score -= 45
            } else if days < 14 {
                findings.append(SigningHealthScore.Finding(
                    id: "cert.expiringSoon",
                    title: "Certificate expires in \(days) day\(days == 1 ? "" : "s")",
                    detail: "Renew the certificate before it expires. Apple rejects signatures with expired certificates.",
                    weight: -20
                ))
                score -= 20
            } else if days < 60 {
                findings.append(SigningHealthScore.Finding(
                    id: "cert.expiringWithin60d",
                    title: "Certificate expires in \(days) days",
                    detail: "Plan a renewal in the next two months.",
                    weight: -5
                ))
                score -= 5
            }
        }
        if let profile {
            profileExpiry = profile.expirationDate
            let days = daysUntil(profile.expirationDate)
            if days < 0 {
                findings.append(SigningHealthScore.Finding(
                    id: "profile.expired",
                    title: "Provisioning profile has expired",
                    detail: "This profile stopped being valid \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago. Apple will refuse installations with it.",
                    weight: -35
                ))
                score -= 35
            } else if days < 14 {
                findings.append(SigningHealthScore.Finding(
                    id: "profile.expiringSoon",
                    title: "Provisioning profile expires in \(days) day\(days == 1 ? "" : "s")",
                    detail: "Re-import a fresh profile from your developer account before signing.",
                    weight: -15
                ))
                score -= 15
            } else if days < 60 {
                findings.append(SigningHealthScore.Finding(
                    id: "profile.expiringWithin60d",
                    title: "Provisioning profile expires in \(days) days",
                    detail: "Plan to refresh the profile within the next two months.",
                    weight: -4
                ))
                score -= 4
            }
        }

        // --- Compatibility ---
        if let profile, let bundleIdentifier {
            if profile.covers(bundleIdentifier: bundleIdentifier) {
                findings.append(SigningHealthScore.Finding(
                    id: "compat.covers",
                    title: "Profile covers this bundle identifier",
                    detail: "The provisioning profile is allowed to sign for \(bundleIdentifier).",
                    weight: 12
                ))
                score += 12
            } else {
                let patterns = profile.bundleIdentifierPatterns.joined(separator: ", ")
                findings.append(SigningHealthScore.Finding(
                    id: "compat.mismatch",
                    title: "Profile does not cover this bundle identifier",
                    detail: "The profile's declared identifiers (\(patterns.isEmpty ? "none" : patterns)) do not include \(bundleIdentifier). Pick a profile that does.",
                    weight: -25
                ))
                score -= 25
            }
        }

        return SigningHealthScore(
            score: score,
            findings: findings,
            certificateExpiry: certificateExpiry,
            profileExpiry: profileExpiry
        )
    }

    private func daysUntil(_ date: Date) -> Int {
        let interval = date.timeIntervalSince(now())
        return Int((interval / 86400).rounded(.toNearestOrEven))
    }
}
