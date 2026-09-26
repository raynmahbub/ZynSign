import Foundation

/// What the Identity Center knows about one local signing certificate,
/// reduced to the facts its engines need.
///
/// The Identity Center's engines — team grouping, health, conflict
/// detection, the expiration forecast, the timeline, and the signing
/// recommendation — are pure domain logic. To stay pure they cannot read
/// the Keychain, the profile library, or the annotation store; the
/// application layer reads those once and hands each engine exactly these
/// facts. A fact is an observation, never a trust statement: `isUsable`
/// repeats what the secure store last observed about the key, and the
/// expiration classification is the certificate's own interval judged at
/// one instant.
///
/// The type carries no key material, no DER bytes, and no secret of any
/// kind. The fingerprint is public information about public certificate
/// bytes.
struct IdentityCertificateFacts: Equatable, Hashable, Sendable {

    /// The identity's stable identifier, as the secure store registered it.
    let identityID: SigningIdentityIdentifier

    /// The certificate's SHA-256 fingerprint, lowercase hex. The stable key
    /// for every local note and every cross-reference from profiles.
    let fingerprintHex: String

    /// The name the certificate's subject presents (the user's local label,
    /// when one is set, is applied by the caller before the facts are
    /// built).
    let displayName: String

    /// The Team ID the certificate's subject declares, when recognisable.
    let teamID: String?

    /// The team name the certificate's subject declares, when recognisable.
    let teamName: String?

    /// The purpose the certificate's common name declares.
    let kind: SigningCertificateKind

    /// The certificate's remaining validity, judged at one instant.
    let expiration: CertificateExpirationAssessment

    /// The last observed availability of the private key.
    let keyAvailability: SigningKeyAvailability

    /// Whether the last observation established a matching, ready signing
    /// capability. Not proof of a successful signature or of trust.
    let isUsableForSigning: Bool

    /// When ZynSign imported the identity, when recorded.
    let importedAt: Date?

    /// Whether the user has marked this identity as the default.
    let isDefault: Bool

    /// Whether the certificate can sign at the evaluation instant: inside
    /// its validity window, with a usable key observed.
    var canSignAtEvaluationDate: Bool {
        expiration.isUsableAtEvaluationDate && isUsableForSigning
    }

    /// Creates facts from their parts.
    init(
        identityID: SigningIdentityIdentifier,
        fingerprintHex: String,
        displayName: String,
        teamID: String?,
        teamName: String?,
        kind: SigningCertificateKind,
        expiration: CertificateExpirationAssessment,
        keyAvailability: SigningKeyAvailability,
        isUsableForSigning: Bool,
        importedAt: Date?,
        isDefault: Bool
    ) {
        self.identityID = identityID
        self.fingerprintHex = fingerprintHex
        self.displayName = displayName
        self.teamID = teamID
        self.teamName = teamName
        self.kind = kind
        self.expiration = expiration
        self.keyAvailability = keyAvailability
        self.isUsableForSigning = isUsableForSigning
        self.importedAt = importedAt
        self.isDefault = isDefault
    }
}

/// What the Identity Center knows about one stored provisioning profile,
/// reduced to the facts its engines need.
///
/// Like the certificate facts, this is an observation of the profile's own
/// declarations — read once from the profile library's summary — and not a
/// verification result. The summary the library holds is the verified
/// record of an import; these facts simply carry what the engines need
/// from it.
struct IdentityProfileFacts: Equatable, Hashable, Sendable {

    /// The profile's stable identifier in the profile library.
    let id: ProvisioningProfileIdentifier

    /// The profile's declared name.
    let name: String

    /// The team identifier the profile declares, when it declares one.
    let teamID: String?

    /// The human team name the profile declares, when it declares one.
    let teamName: String?

    /// The distribution type derived from the profile's own fields.
    let profileType: ProvisioningProfileClassification

    /// The profile's expiration date.
    let expirationDate: Date

    /// The App-ID bundle patterns the profile declares.
    let bundleIdentifierPatterns: [String]

    /// The explicit bundle identifier, when the App ID is exact.
    let bundleIdentifier: String?

    /// The certificate fingerprints the profile embeds, lowercase hex;
    /// empty when none were recorded.
    let certificateFingerprints: [String]

    /// When the profile was imported, when recorded.
    let importedAt: Date?

    /// Whether the profile allows debug builds.
    let allowsDebug: Bool

    /// Creates profile facts from their parts.
    init(
        id: ProvisioningProfileIdentifier,
        name: String,
        teamID: String?,
        teamName: String?,
        profileType: ProvisioningProfileClassification,
        expirationDate: Date,
        bundleIdentifierPatterns: [String],
        bundleIdentifier: String?,
        certificateFingerprints: [String],
        importedAt: Date?,
        allowsDebug: Bool
    ) {
        self.id = id
        self.name = name
        self.teamID = teamID
        self.teamName = teamName
        self.profileType = profileType
        self.expirationDate = expirationDate
        self.bundleIdentifierPatterns = bundleIdentifierPatterns
        self.bundleIdentifier = bundleIdentifier
        self.certificateFingerprints = certificateFingerprints
        self.importedAt = importedAt
        self.allowsDebug = allowsDebug
    }

    /// Whether the profile has expired at `referenceDate`.
    func isExpired(referenceDate: Date) -> Bool {
        referenceDate >= expirationDate
    }

    /// Whole days until expiration at `referenceDate`; negative once past.
    func daysUntilExpiration(referenceDate: Date) -> Int {
        Int(expirationDate.timeIntervalSince(referenceDate) / 86400)
    }

    /// Whether the profile's declared patterns cover `bundleIdentifier`.
    /// An exact App ID covers only itself; wildcard patterns reuse the
    /// summary's matching rule, so the engines and the profile library can
    /// never disagree about what "covers" means.
    func covers(bundleIdentifier target: String) -> Bool {
        if let bundleIdentifier {
            return bundleIdentifier == target
        }
        return bundleIdentifierPatterns.contains {
            ProvisioningProfileSummary.pattern($0, covers: target)
        }
    }
}

/// One past signing run, reduced to what the recommendation engine may
/// learn from history.
///
/// The Identity Center reads the on-device signing journal and reduces
/// each record to these facts, so the recommendation engine stays pure and
/// the journal's richer fields — outputs, verification findings, failures —
/// never leak into identity scoring. A fingerprint identifies a
/// certificate; it is not a trust statement.
struct IdentityHistoryFact: Equatable, Hashable, Sendable {

    /// The certificate fingerprint the run used, lowercase hex, when
    /// captured.
    let certificateFingerprintHex: String?

    /// The bundle identifier the run signed, when captured.
    let bundleIdentifier: String?

    /// The display name the run's source application declared, when
    /// captured. A display convenience for the timeline; never a trust
    /// statement and never key material.
    let applicationName: String?

    /// The team identifier the run recorded, when one was established.
    let teamIdentifier: String?

    /// Whether the run delivered output.
    let succeeded: Bool

    /// When the run started.
    let startedAt: Date

    /// Creates a history fact from its parts.
    init(
        certificateFingerprintHex: String?,
        bundleIdentifier: String?,
        applicationName: String?,
        teamIdentifier: String?,
        succeeded: Bool,
        startedAt: Date
    ) {
        self.certificateFingerprintHex = certificateFingerprintHex
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.teamIdentifier = teamIdentifier
        self.succeeded = succeeded
        self.startedAt = startedAt
    }
}
