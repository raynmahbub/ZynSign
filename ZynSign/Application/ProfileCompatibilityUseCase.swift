import Foundation

/// The application-layer face of the Smart Compatibility Engine and the
/// Profile Matching engine.
///
/// The domain engines are pure: they take a profile, a context, and an
/// instant. This use case assembles the context — the local certificates
/// read through `IdentityStore`, the reference instant from the injected
/// clock — and hands the engine's report back to the presentation layer.
/// It never touches files, and it never decides anything the domain types
/// do not already model.
struct ProfileCompatibilityUseCase {

    /// The identity store supplying local certificate facts. `nil` in
    /// compositions without one; the context then carries no certificates
    /// and the certificate check reports honestly instead of guessing.
    private let identityStore: (any IdentityStore)?

    /// The instant expiration is judged against.
    private let clock: any EvaluationClock

    private let engine = ProfileCompatibilityEngine()
    private let matcher = ProfileMatcher()

    init(
        identityStore: (any IdentityStore)?,
        clock: any EvaluationClock = SystemEvaluationClock()
    ) {
        self.identityStore = identityStore
        self.clock = clock
    }

    /// The local certificates reduced to compatibility facts. A store that
    /// cannot be read yields no facts — the checks then report missing
    /// certificates rather than inventing them.
    func localCertificates() -> [LocalCertificateFact] {
        guard let identityStore else { return [] }
        guard let identities = try? identityStore.listIdentities() else { return [] }
        return identities.map { identity in
            LocalCertificateFact(
                fingerprintHex: identity.certificate.sha256Fingerprint.hexDigest.lowercased(),
                teamIdentifier: identity.certificate.subject.organizationalUnit,
                displayName: identity.certificate.subject.displayName,
                isUsableForSigning: identity.isUsableForSigning
            )
        }
    }

    /// A context for evaluating profiles against `targetBundleIdentifier`,
    /// with the local certificates and the clock's instant.
    func context(targetBundleIdentifier: String? = nil) -> ProfileCompatibilityContext {
        ProfileCompatibilityContext(
            targetBundleIdentifier: targetBundleIdentifier,
            localCertificates: localCertificates(),
            referenceDate: clock.now()
        )
    }

    /// The full compatibility report for one profile in one context.
    func evaluate(
        profile: ProvisioningProfileSummary,
        targetBundleIdentifier: String? = nil
    ) -> ProfileCompatibilityReport {
        engine.evaluate(
            profile: profile,
            context: context(targetBundleIdentifier: targetBundleIdentifier)
        )
    }

    /// Reports for a whole library against one shared context, so the local
    /// certificates are read once instead of once per profile.
    func reports(
        for profiles: [ProvisioningProfileSummary],
        targetBundleIdentifier: String? = nil
    ) -> [ProvisioningProfileIdentifier: ProfileCompatibilityReport] {
        let evaluationContext = context(targetBundleIdentifier: targetBundleIdentifier)
        var reports: [ProvisioningProfileIdentifier: ProfileCompatibilityReport] = [:]
        for profile in profiles {
            reports[profile.id] = engine.evaluate(profile: profile, context: evaluationContext)
        }
        return reports
    }

    /// Every eligible profile for the target app, ranked best-first.
    func rank(
        profiles: [ProvisioningProfileSummary],
        targetBundleIdentifier: String?
    ) -> [ProfileMatch] {
        matcher.rank(
            profiles: profiles,
            context: context(targetBundleIdentifier: targetBundleIdentifier)
        )
    }

    /// The single best profile for the target app, when one is eligible.
    func bestMatch(
        profiles: [ProvisioningProfileSummary],
        targetBundleIdentifier: String?
    ) -> ProfileMatch? {
        matcher.bestMatch(
            profiles: profiles,
            context: context(targetBundleIdentifier: targetBundleIdentifier)
        )
    }
}
