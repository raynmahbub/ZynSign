import Foundation
@testable import ZynSign

/// A `ProvisioningProfileLibrary` holding summaries in memory, for the
/// Identity Center's service and model tests.
final class MemoryProvisioningProfileLibrary: ProvisioningProfileLibrary, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [ProvisioningProfileSummary] = []
    private var readError: (any Error)?

    init(profiles: [ProvisioningProfileSummary] = []) {
        stored = profiles
    }

    /// Makes every read throw `error`.
    func failReads(with error: (any Error)?) {
        lock.withLock { readError = error }
    }

    /// Replaces the stored list.
    func replace(profiles: [ProvisioningProfileSummary]) {
        lock.withLock { stored = profiles }
    }

    func allProfiles() async throws -> [ProvisioningProfileSummary] {
        lock.withLock {
            if let readError { throw readError }
            return stored.sorted(by: ProvisioningProfileSummary.sortByExpiration)
        }
    }

    func profile(withID id: ProvisioningProfileIdentifier) async throws -> ProvisioningProfileSummary? {
        lock.withLock {
            if let readError { throw readError }
            return stored.first { $0.id == id }
        }
    }

    func profileBytes(withID id: ProvisioningProfileIdentifier) async throws -> Data? {
        nil
    }

    func upsert(_ summary: ProvisioningProfileSummary) async throws {
        lock.withLock {
            if let index = stored.firstIndex(where: { $0.id == summary.id }) {
                stored[index] = summary
            } else {
                stored.append(summary)
            }
        }
    }

    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws {
        lock.withLock {
            stored.removeAll { $0.id == id }
        }
    }

    func count() async throws -> Int {
        lock.withLock { stored.count }
    }
}

/// Builders for the Identity Center's facts and summaries, sharing the
/// synthetic certificate fixtures.
enum IdentityCenterFixtures {

    /// The reference instant the Identity Center tests evaluate at: the
    /// same 2026-10-01 instant the certificate fixtures were designed
    /// around.
    static let referenceDate = TestClocks.evaluationInstant.now()

    /// The fixed expiration assessment the valid fixture earns at the
    /// reference instant.
    static func validExpiration(
        at date: Date = referenceDate
    ) -> CertificateExpirationAssessment {
        CertificateExpirationAssessment.assess(
            certificate: metadata(for: CertificateFixtures.validDER),
            at: date
        )
    }

    /// Parses fixture DER into metadata. Force-try: the fixtures are
    /// known-good.
    static func metadata(for der: Data) -> CertificateMetadata {
        try! AppleCertificateParser().parseCertificate(derData: der)
    }

    /// A stable-looking fingerprint hex for tests that do not parse a
    /// certificate: 64 hex characters derived from a seed.
    static func fingerprintHex(seed: UInt8) -> String {
        String(repeating: String(format: "%02x", seed), count: 32)
    }

    /// Builds certificate facts, with explicit team and name fields the
    /// raw fixtures do not carry (their subjects declare no Team ID).
    static func certificateFacts(
        fingerprintHex: String = fingerprintHex(seed: 0xA1),
        displayName: String = "Apple Development: Test",
        teamID: String? = "TEAMABC123",
        teamName: String? = "ZynSign Team",
        kind: SigningCertificateKind = .development,
        expiration: CertificateExpirationAssessment? = nil,
        keyAvailability: SigningKeyAvailability = .available,
        isUsableForSigning: Bool = true,
        importedAt: Date? = nil,
        isDefault: Bool = false,
        notValidAfter: Date = TestClocks.utc(2027, 9, 22),
        referenceDate: Date = referenceDate
    ) -> IdentityCertificateFacts {
        IdentityCertificateFacts(
            identityID: SigningIdentityIdentifier(),
            fingerprintHex: fingerprintHex,
            displayName: displayName,
            teamID: teamID,
            teamName: teamName,
            kind: kind,
            expiration: expiration ?? CertificateExpirationAssessment.assess(
                notValidBefore: TestClocks.utc(2026, 1, 1),
                notValidAfter: notValidAfter,
                at: referenceDate
            ),
            keyAvailability: keyAvailability,
            isUsableForSigning: isUsableForSigning,
            importedAt: importedAt,
            isDefault: isDefault
        )
    }

    /// Builds profile facts.
    static func profileFacts(
        name: String = "Test Profile",
        teamID: String? = "TEAMABC123",
        teamName: String? = "ZynSign Team",
        profileType: ProvisioningProfileClassification = .development,
        expiresAt: Date = TestClocks.utc(2027, 6, 1),
        bundleIdentifier: String? = nil,
        bundleIdentifierPatterns: [String] = ["TEAMABC123.com.example.*"],
        certificateFingerprints: [String] = [],
        importedAt: Date? = nil,
        allowsDebug: Bool = true,
        id: ProvisioningProfileIdentifier = ProvisioningProfileIdentifier()
    ) -> IdentityProfileFacts {
        IdentityProfileFacts(
            id: id,
            name: name,
            teamID: teamID,
            teamName: teamName,
            profileType: profileType,
            expirationDate: expiresAt,
            bundleIdentifierPatterns: bundleIdentifierPatterns,
            bundleIdentifier: bundleIdentifier,
            certificateFingerprints: certificateFingerprints,
            importedAt: importedAt,
            allowsDebug: allowsDebug
        )
    }

    /// Builds the library summary a set of facts corresponds to, so a test
    /// can put the same profile into the library double and the facts.
    static func summary(for facts: IdentityProfileFacts) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            id: facts.id,
            name: facts.name,
            teamIdentifier: facts.teamID,
            bundleIdentifierPatterns: facts.bundleIdentifierPatterns,
            expirationDate: facts.expirationDate,
            entitlementsKeys: [],
            allowsDebug: facts.allowsDebug,
            sourceFileName: "\(facts.name).mobileprovision",
            importedAt: facts.importedAt ?? referenceDate,
            uuid: nil,
            teamName: facts.teamName,
            creationDate: nil,
            profileType: facts.profileType,
            deviceCount: nil,
            applicationIdentifier: nil,
            bundleIdentifier: facts.bundleIdentifier,
            certificateFingerprints: facts.certificateFingerprints
        )
    }
}
