import Foundation

/// One library application a profile can sign, reduced to what the
/// Identity Center shows: the bundle identifier and the declared display
/// name.
struct CompatibleApp: Equatable, Hashable, Sendable {

    /// The application's declared bundle identifier.
    let bundleIdentifier: String

    /// The application's declared display name, exactly as declared, when
    /// it declared one.
    let declaredName: String?

    /// The name the Identity Center shows.
    var displayName: String {
        if let declaredName, !declaredName.isEmpty { return declaredName }
        return bundleIdentifier
    }

    /// Creates the pair from its parts.
    init(bundleIdentifier: String, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.declaredName = displayName
    }
}

/// One certificate as the Identity Center presents it: the secure store's
/// identity joined with the facts the engines computed and the local
/// annotation.
struct IdentityCenterCertificate: Equatable, Identifiable, Sendable {

    /// The secure store's snapshot of the identity.
    let identity: SigningIdentity

    /// The facts every engine was fed.
    let facts: IdentityCertificateFacts

    /// The team the certificate groups under, by the workspace's key.
    let teamKey: String

    /// The certificate's health report at the snapshot instant.
    let health: IdentityHealthReport

    /// The identifiers of the profiles linked to this certificate, by
    /// embedded fingerprint or declared team.
    let linkedProfileIDs: [ProvisioningProfileIdentifier]

    /// The library applications this certificate's profiles can sign.
    let compatibleApps: [CompatibleApp]

    /// The certificate's fingerprint: the stable identifier of the
    /// certificate's bytes, and the key of every local note.
    var id: String { facts.fingerprintHex }

    /// The name the Identity Center shows.
    var displayName: String { facts.displayName }

    /// Creates the presentation entry from its parts.
    init(
        identity: SigningIdentity,
        facts: IdentityCertificateFacts,
        teamKey: String,
        health: IdentityHealthReport,
        linkedProfileIDs: [ProvisioningProfileIdentifier],
        compatibleApps: [CompatibleApp]
    ) {
        self.identity = identity
        self.facts = facts
        self.teamKey = teamKey
        self.health = health
        self.linkedProfileIDs = linkedProfileIDs
        self.compatibleApps = compatibleApps
    }

    static func == (lhs: IdentityCenterCertificate, rhs: IdentityCenterCertificate) -> Bool {
        lhs.facts == rhs.facts
            && lhs.teamKey == rhs.teamKey
            && lhs.health == rhs.health
            && lhs.linkedProfileIDs == rhs.linkedProfileIDs
            && lhs.compatibleApps == rhs.compatibleApps
    }
}

/// One provisioning profile as the Identity Center presents it.
struct IdentityCenterProfile: Equatable, Identifiable, Sendable {

    /// The status badge the profile card shows.
    enum Status: String, Equatable, Hashable, Sendable {
        case ready
        case expiring
        case expired
        case conflict

        /// The badge text.
        var displayName: String {
            switch self {
            case .ready: return "Ready"
            case .expiring: return "Expiring"
            case .expired: return "Expired"
            case .conflict: return "Conflict"
            }
        }
    }

    /// The profile library's summary.
    let summary: ProvisioningProfileSummary

    /// The facts every engine was fed.
    let facts: IdentityProfileFacts

    /// The team the profile groups under, by the workspace's key.
    let teamKey: String

    /// The profile's health report at the snapshot instant.
    let health: IdentityHealthReport

    /// The status badge.
    let status: Status

    /// The identifiers of the local certificates this profile embeds.
    let linkedCertificateFingerprints: [String]

    /// The library applications the profile can sign.
    let compatibleApps: [CompatibleApp]

    /// The profile's identifier.
    var id: ProvisioningProfileIdentifier { facts.id }

    /// The name the Identity Center shows.
    var displayName: String { facts.name }

    /// Creates the presentation entry from its parts.
    init(
        summary: ProvisioningProfileSummary,
        facts: IdentityProfileFacts,
        teamKey: String,
        health: IdentityHealthReport,
        status: Status,
        linkedCertificateFingerprints: [String],
        compatibleApps: [CompatibleApp]
    ) {
        self.summary = summary
        self.facts = facts
        self.teamKey = teamKey
        self.health = health
        self.status = status
        self.linkedCertificateFingerprints = linkedCertificateFingerprints
        self.compatibleApps = compatibleApps
    }

    static func == (lhs: IdentityCenterProfile, rhs: IdentityCenterProfile) -> Bool {
        lhs.summary == rhs.summary
            && lhs.teamKey == rhs.teamKey
            && lhs.health == rhs.health
            && lhs.status == rhs.status
            && lhs.linkedCertificateFingerprints == rhs.linkedCertificateFingerprints
            && lhs.compatibleApps == rhs.compatibleApps
    }
}

/// The dashboard's counts: what the Identity Center holds and how much of
/// it is healthy.
struct IdentityCenterStatistics: Equatable, Hashable, Sendable {

    /// How many teams the identities group into, including the ungrouped
    /// bucket when it holds anything.
    let teamCount: Int

    /// How many certificates are registered.
    let certificateCount: Int

    /// How many profiles are stored.
    let profileCount: Int

    /// How many identities — certificates and profiles together — are
    /// healthy.
    let healthyCount: Int

    /// How many identities want attention: any warning or blocked report.
    let needsAttentionCount: Int

    /// Creates the statistics from their parts.
    init(
        teamCount: Int,
        certificateCount: Int,
        profileCount: Int,
        healthyCount: Int,
        needsAttentionCount: Int
    ) {
        self.teamCount = teamCount
        self.certificateCount = certificateCount
        self.profileCount = profileCount
        self.healthyCount = healthyCount
        self.needsAttentionCount = needsAttentionCount
    }
}

/// One snapshot of the Developer Identity Center: every identity, its
/// health, the conflicts the facts contain, the expiration forecast, the
/// timeline, and the dashboard's counts — all computed at one instant from
/// one read of each store.
///
/// The snapshot is a value: nothing in it can change under the interface,
/// and a refresh builds a fresh one. Health results live here, so a
/// screen that renders from the snapshot never recomputes a check.
struct IdentityCenterSnapshot: Equatable, Sendable {

    /// The instant the snapshot was computed at.
    let generatedAt: Date

    /// Every registered certificate.
    let certificates: [IdentityCenterCertificate]

    /// Every stored profile.
    let profiles: [IdentityCenterProfile]

    /// The teams the identities group into, workspace order.
    let teams: [DeveloperTeam]

    /// The conflicts the facts contain, most urgent first.
    let conflicts: [IdentityConflict]

    /// The expiration forecast, most urgent first.
    let forecast: [ExpirationForecastEntry]

    /// The timeline events, most recent first.
    let timeline: [IdentityTimelineEvent]

    /// The dashboard's counts.
    let statistics: IdentityCenterStatistics

    /// The fingerprint the user marked as the default identity, when one
    /// is set and still names a registered certificate.
    let defaultFingerprintHex: String?

    /// Creates a snapshot from its parts.
    init(
        generatedAt: Date,
        certificates: [IdentityCenterCertificate],
        profiles: [IdentityCenterProfile],
        teams: [DeveloperTeam],
        conflicts: [IdentityConflict],
        forecast: [ExpirationForecastEntry],
        timeline: [IdentityTimelineEvent],
        statistics: IdentityCenterStatistics,
        defaultFingerprintHex: String?
    ) {
        self.generatedAt = generatedAt
        self.certificates = certificates
        self.profiles = profiles
        self.teams = teams
        self.conflicts = conflicts
        self.forecast = forecast
        self.timeline = timeline
        self.statistics = statistics
        self.defaultFingerprintHex = defaultFingerprintHex
    }

    /// The team for a workspace key, when the snapshot holds one.
    func team(for key: String) -> DeveloperTeam? {
        teams.first { $0.id == key }
    }

    /// The certificate for a fingerprint, when the snapshot holds one.
    func certificate(fingerprintHex: String) -> IdentityCenterCertificate? {
        certificates.first { $0.facts.fingerprintHex == fingerprintHex }
    }

    /// The profile for an identifier, when the snapshot holds one.
    func profile(id: ProvisioningProfileIdentifier) -> IdentityCenterProfile? {
        profiles.first { $0.facts.id == id }
    }
}

/// The Developer Identity Center: one read of each store, one snapshot,
/// every signing relationship answered from it.
///
/// The service is the application-layer seam the Identity Center's screens
/// read. It assembles the facts the domain engines evaluate — one
/// `IdentityStore` read, one profile-library read, one library read, one
/// journal read per snapshot — so a dashboard render never re-reads the
/// Keychain, and the engines themselves stay pure and testable.
///
/// Security boundary, **Accepted**:
/// - Private keys live only in the Keychain. The service reads identities
///   through `IdentityStore`, which never exposes key bytes, and never
///   asks for a signing capability.
/// - The snapshot carries metadata and composed language only: no DER
///   bytes, no profile payloads, no passwords, no key references. Reports
///   exported from it hold the same metadata, which is public information
///   about public bytes.
/// - Removal goes through `IdentityStore.removeRegistration`, which never
///   deletes a key.
struct IdentityCenterService {

    /// The secure identity store the certificates are read from.
    private let identityStore: any IdentityStore

    /// The profile library, when one is composed.
    private let profiles: (any ProvisioningProfileLibrary)?

    /// The application library, when one is composed. Only its records'
    /// declared identities are read — no artifact bytes.
    private let library: ApplicationLibrary?

    /// The local annotation store, when one is composed.
    private let annotations: (any IdentityAnnotationsStore)?

    /// The signing journal, when one is composed.
    private let history: (any SigningHistoryStore)?

    /// The instant the engines judge at.
    private let clock: any EvaluationClock

    /// The engines, stateless and shared.
    private let grouper = DeveloperTeamGrouper()
    private let healthEngine = IdentityHealthEngine()
    private let conflictDetector = IdentityConflictDetector()
    private let forecastBuilder = ExpirationForecastBuilder()
    private let timelineBuilder = IdentityTimelineBuilder()
    private let recommender = IdentityRecommender()

    /// Creates the service over the given stores. Any store except the
    /// identity store may be absent; the snapshot then reports what it can
    /// and leaves the rest empty.
    init(
        identityStore: any IdentityStore,
        profiles: (any ProvisioningProfileLibrary)?,
        library: ApplicationLibrary?,
        annotations: (any IdentityAnnotationsStore)?,
        history: (any SigningHistoryStore)?,
        clock: any EvaluationClock = SystemEvaluationClock()
    ) {
        self.identityStore = identityStore
        self.profiles = profiles
        self.library = library
        self.annotations = annotations
        self.history = history
        self.clock = clock
    }

    // MARK: - Snapshot

    /// Computes a snapshot.
    ///
    /// A failure of the identity store fails the snapshot — the
    /// certificates are the center's subject. Every other store failing
    /// degrades its own section to empty: a profile library that cannot be
    /// read right now is an empty profile list, not a broken dashboard.
    ///
    /// - Returns: The snapshot.
    /// - Throws: A typed `ZynSignError` when the identity store cannot be
    ///   read.
    func snapshot() async throws -> IdentityCenterSnapshot {
        let now = clock.now()

        // One read of the Keychain-backed store per snapshot.
        let identities = try identityStore.listIdentities()

        var annotationsMap: [String: IdentityAnnotation] = [:]
        var defaultFingerprint: String?
        if let annotations {
            annotationsMap = (try? annotations.annotations()) ?? [:]
            defaultFingerprint = (try? annotations.defaultIdentityFingerprint()) ?? nil
        }

        var profileSummaries: [ProvisioningProfileSummary] = []
        if let profiles {
            profileSummaries = (try? await profiles.allProfiles()) ?? []
        }

        var libraryEntries: [LibraryEntry] = []
        if let library {
            libraryEntries = (try? await library.entries()) ?? []
        }

        var historyFacts: [IdentityHistoryFact] = []
        if let history {
            let records = (try? await history.allRecords()) ?? []
            historyFacts = records.map { record in
                IdentityHistoryFact(
                    certificateFingerprintHex: record.certificateFingerprint?.hexDigest.lowercased(),
                    bundleIdentifier: record.sourceBundleIdentifier,
                    applicationName: record.sourceDisplayName,
                    teamIdentifier: record.teamIdentifier,
                    succeeded: record.outcome.isSuccess,
                    startedAt: record.startedAt
                )
            }
        }

        // Certificates: facts joined to their identities, in store order.
        // The pair is kept together so no entry ever needs a lookup that
        // could miss.
        let joinedCertificates: [(identity: SigningIdentity, facts: IdentityCertificateFacts)] =
            identities.map { identity in
                let team = CertificateTeamIdentity.from(identity.certificate.subject)
                let fingerprint = identity.fingerprint.hexDigest.lowercased()
                let facts = IdentityCertificateFacts(
                    identityID: identity.id,
                    fingerprintHex: fingerprint,
                    displayName: annotationsMap[fingerprint]?.displayLabel ?? identity.displayName,
                    teamID: team.teamID,
                    teamName: team.teamName,
                    kind: SigningCertificateKind.classify(subject: identity.certificate.subject),
                    expiration: CertificateExpirationAssessment.assess(
                        certificate: identity.certificate,
                        at: now
                    ),
                    keyAvailability: identity.keyAvailability,
                    isUsableForSigning: identity.isUsableForSigning,
                    importedAt: annotationsMap[fingerprint]?.importedAt,
                    isDefault: fingerprint == defaultFingerprint
                )
                return (identity, facts)
            }
        let certificateFacts = joinedCertificates.map(\.facts)

        let joinedProfiles: [(summary: ProvisioningProfileSummary, facts: IdentityProfileFacts)] =
            profileSummaries.map { summary in
                let facts = IdentityProfileFacts(
                    id: summary.id,
                    name: summary.name,
                    teamID: summary.teamIdentifier,
                    teamName: summary.teamName,
                    profileType: summary.resolvedProfileType,
                    expirationDate: summary.expirationDate,
                    bundleIdentifierPatterns: summary.bundleIdentifierPatterns,
                    bundleIdentifier: summary.bundleIdentifier,
                    certificateFingerprints: summary.resolvedCertificateFingerprints,
                    importedAt: summary.importedAt,
                    allowsDebug: summary.allowsDebug
                )
                return (summary, facts)
            }
        let profileFacts = joinedProfiles.map(\.facts)

        // Compatible applications: which library records each profile
        // covers. Read once for all profiles; the count feeds the health
        // engine and the workspace summary alike.
        let compatibleAppsByProfile: [ProvisioningProfileIdentifier: [CompatibleApp]] =
            Dictionary(uniqueKeysWithValues: profileFacts.map { facts in
                let apps = libraryEntries.compactMap { entry -> CompatibleApp? in
                    let bundleID = entry.record.identity.bundleIdentifier.rawValue
                    guard facts.covers(bundleIdentifier: bundleID) else { return nil }
                    return CompatibleApp(bundleIdentifier: bundleID, displayName: entry.record.identity.displayName)
                }
                return (facts.id, apps)
            })

        let teams = grouper.group(certificates: certificateFacts, profiles: profileFacts)

        // Profiles: linkage to local certificates, then health.
        let localFingerprints = Set(certificateFacts.map(\.fingerprintHex))
        let profileEntries: [IdentityCenterProfile] = joinedProfiles.map { joined in
            let facts = joined.facts
            let linked = facts.certificateFingerprints.filter { localFingerprints.contains($0) }
            let compatible = compatibleAppsByProfile[facts.id] ?? []
            let health = healthEngine.assessProfile(
                facts,
                certificates: certificateFacts,
                compatibleAppCount: compatible.count,
                referenceDate: now
            )
            let status: IdentityCenterProfile.Status
            if facts.isExpired(referenceDate: now) {
                status = .expired
            } else if health.status == .blocked {
                status = .conflict
            } else if facts.daysUntilExpiration(referenceDate: now)
                <= ProfileExpirationAssessment.expiringSoonThreshold {
                status = .expiring
            } else if health.status == .warning {
                status = .conflict
            } else {
                status = .ready
            }
            return IdentityCenterProfile(
                summary: joined.summary,
                facts: facts,
                teamKey: Self.teamKey(for: facts.teamID),
                health: health,
                status: status,
                linkedCertificateFingerprints: linked,
                compatibleApps: compatible
            )
        }

        let certificateEntries: [IdentityCenterCertificate] = joinedCertificates.map { joined in
            let facts = joined.facts
            let linkedProfiles = profileFacts.filter { profile in
                profile.certificateFingerprints.contains(facts.fingerprintHex)
                    || (facts.teamID != nil
                        && profile.teamID?.caseInsensitiveCompare(facts.teamID!) == .orderedSame)
            }
            let linkedIDs = linkedProfiles.map(\.id)
            var compatible: [CompatibleApp] = []
            var seenBundles: Set<String> = []
            for profileID in linkedIDs {
                for app in compatibleAppsByProfile[profileID] ?? []
                where !seenBundles.contains(app.bundleIdentifier) {
                    seenBundles.insert(app.bundleIdentifier)
                    compatible.append(app)
                }
            }
            let health = healthEngine.assessCertificate(
                facts,
                linkedProfiles: linkedProfiles,
                compatibleAppCounts: Dictionary(
                    uniqueKeysWithValues: linkedIDs.map { ($0, compatibleAppsByProfile[$0]?.count ?? 0) }
                ),
                referenceDate: now
            )
            return IdentityCenterCertificate(
                identity: joined.identity,
                facts: facts,
                teamKey: Self.teamKey(for: facts.teamID),
                health: health,
                linkedProfileIDs: linkedIDs,
                compatibleApps: compatible
            )
        }

        let conflicts = conflictDetector.detect(
            certificates: certificateFacts,
            profiles: profileFacts,
            defaultFingerprintHex: defaultFingerprint,
            referenceDate: now
        )

        let forecast = forecastBuilder.build(
            certificates: certificateFacts,
            profiles: profileFacts,
            referenceDate: now
        )

        let timeline = timelineBuilder.events(
            certificates: certificateFacts,
            profiles: profileFacts,
            history: historyFacts,
            forecast: forecast,
            referenceDate: now
        )

        let reports = certificateEntries.map(\.health) + profileEntries.map(\.health)
        let healthy = reports.filter { $0.status == .healthy }.count
        let attention = reports.filter { $0.status != .healthy }.count
        let statistics = IdentityCenterStatistics(
            teamCount: teams.count,
            certificateCount: certificateEntries.count,
            profileCount: profileEntries.count,
            healthyCount: healthy,
            needsAttentionCount: attention
        )

        return IdentityCenterSnapshot(
            generatedAt: now,
            certificates: certificateEntries,
            profiles: profileEntries,
            teams: teams,
            conflicts: conflicts,
            forecast: forecast,
            timeline: timeline,
            statistics: statistics,
            defaultFingerprintHex: defaultFingerprint
        )
    }

    // MARK: - Recommendation

    /// Recommends an identity–profile pairing for one application.
    ///
    /// Reads the same stores the snapshot reads — the Keychain once, the
    /// profile library once, the journal once — and hands the pure
    /// recommender the reduced facts. A recommendation is a proposal; the
    /// caller always asks the user to confirm it.
    ///
    /// - Parameter bundleIdentifier: The application to sign.
    /// - Returns: The recommendation, or `nil` when nothing qualifies.
    func recommendation(
        forBundleIdentifier bundleIdentifier: String?
    ) async -> SigningIdentityRecommendation? {
        let now = clock.now()
        guard let identities = try? identityStore.listIdentities(), !identities.isEmpty else {
            return nil
        }

        var annotationsMap: [String: IdentityAnnotation] = [:]
        var defaultFingerprint: String?
        if let annotations {
            annotationsMap = (try? annotations.annotations()) ?? [:]
            defaultFingerprint = (try? annotations.defaultIdentityFingerprint()) ?? nil
        }

        var profileSummaries: [ProvisioningProfileSummary] = []
        if let profiles {
            profileSummaries = (try? await profiles.allProfiles()) ?? []
        }

        var historyFacts: [IdentityHistoryFact] = []
        if let history {
            let records = (try? await history.allRecords()) ?? []
            historyFacts = records.map { record in
                IdentityHistoryFact(
                    certificateFingerprintHex: record.certificateFingerprint?.hexDigest.lowercased(),
                    bundleIdentifier: record.sourceBundleIdentifier,
                    applicationName: record.sourceDisplayName,
                    teamIdentifier: record.teamIdentifier,
                    succeeded: record.outcome.isSuccess,
                    startedAt: record.startedAt
                )
            }
        }

        let certificateFacts: [IdentityCertificateFacts] = identities.map { identity in
            let team = CertificateTeamIdentity.from(identity.certificate.subject)
            let fingerprint = identity.fingerprint.hexDigest.lowercased()
            return IdentityCertificateFacts(
                identityID: identity.id,
                fingerprintHex: fingerprint,
                displayName: annotationsMap[fingerprint]?.displayLabel ?? identity.displayName,
                teamID: team.teamID,
                teamName: team.teamName,
                kind: SigningCertificateKind.classify(subject: identity.certificate.subject),
                expiration: CertificateExpirationAssessment.assess(
                    certificate: identity.certificate,
                    at: now
                ),
                keyAvailability: identity.keyAvailability,
                isUsableForSigning: identity.isUsableForSigning,
                importedAt: annotationsMap[fingerprint]?.importedAt,
                isDefault: fingerprint == defaultFingerprint
            )
        }

        let profileFacts: [IdentityProfileFacts] = profileSummaries.map { summary in
            IdentityProfileFacts(
                id: summary.id,
                name: summary.name,
                teamID: summary.teamIdentifier,
                teamName: summary.teamName,
                profileType: summary.resolvedProfileType,
                expirationDate: summary.expirationDate,
                bundleIdentifierPatterns: summary.bundleIdentifierPatterns,
                bundleIdentifier: summary.bundleIdentifier,
                certificateFingerprints: summary.resolvedCertificateFingerprints,
                importedAt: summary.importedAt,
                allowsDebug: summary.allowsDebug
            )
        }

        return recommender.recommend(
            bundleIdentifier: bundleIdentifier,
            certificates: certificateFacts,
            profiles: profileFacts,
            history: historyFacts,
            defaultFingerprintHex: defaultFingerprint,
            referenceDate: now
        )
    }

    /// Removes a profile from the profile library. The library owns the
    /// record and its stored copy; the original file outside ZynSign is
    /// never touched.
    ///
    /// - Parameter id: The profile's identifier.
    /// - Throws: A typed error when the library cannot perform the
    ///   removal.
    func removeProfile(id: ProvisioningProfileIdentifier) async throws {
        guard let profiles else {
            throw ZynSignError.identity(.platformRestriction)
        }
        try await profiles.remove(profileWithID: id)
    }

    // MARK: - Actions

    /// Marks the certificate with `fingerprintHex` as the default identity,
    /// or clears the default with `nil`. The annotation store records the
    /// mark; nothing about the certificate or its key changes.
    func setDefaultIdentityFingerprint(_ fingerprintHex: String?) async throws {
        guard let annotations else {
            throw ZynSignError.identity(.platformRestriction)
        }
        try annotations.setDefaultIdentityFingerprint(fingerprintHex)
    }

    /// Forgets a certificate's registration. The Keychain key is never
    /// deleted; the local annotation and a default mark that pointed at
    /// the certificate are cleared with the registration.
    ///
    /// - Parameter fingerprintHex: The certificate's fingerprint.
    /// - Throws: A typed `ZynSignError` when the registration cannot be
    ///   removed.
    func removeIdentity(fingerprintHex: String) async throws {
        guard let identity = try identityStore.listIdentities().first(where: {
            $0.fingerprint.hexDigest.lowercased() == fingerprintHex
        }) else {
            throw ZynSignError.identity(.identityNotFound)
        }
        try identityStore.removeRegistration(identity.id)
        if let annotations {
            try? annotations.removeAnnotation(forFingerprint: fingerprintHex)
            if let current = try? annotations.defaultIdentityFingerprint(),
               current == fingerprintHex {
                try? annotations.setDefaultIdentityFingerprint(nil)
            }
        }
    }

    // MARK: - Helpers

    /// The workspace key a Team ID groups under: the upper-cased Team ID,
    /// or the ungrouped marker.
    static func teamKey(for teamID: String?) -> String {
        teamID?.uppercased() ?? DeveloperTeam.ungroupedIdentifier
    }
}
