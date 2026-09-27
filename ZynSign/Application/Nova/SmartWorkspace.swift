import Foundation

// MARK: - Ports

/// Persists the Smart Workspace's own small state: which widgets the user
/// opens, and what they were last doing. Display state only — no secrets,
/// no paths — so a store that fails is tolerated: the workspace falls back
/// to the default order and no “continue” card.
protocol WorkspaceStateStore: Sendable {
    func usage() throws -> [WorkspaceUsageSignal]
    func recordOpen(of widget: WorkspaceWidget, at date: Date) throws
    func lastSession() throws -> WorkspaceSession?
    func setLastSession(_ session: WorkspaceSession?) throws
}

// MARK: - Snapshot

/// Everything the Smart Workspace renders, read in one pass so the cards
/// can never disagree with each other.
struct SmartWorkspaceSnapshot: Equatable, Sendable {
    let greeting: String
    let widgetOrder: [WorkspaceWidget]
    let lastSession: WorkspaceSession?
    let recommendations: [NovaRecommendation]
    let facts: NovaFacts
    let readAt: Date

    static let empty = SmartWorkspaceSnapshot(
        greeting: WorkspaceDaypart(hour: 12).greeting,
        widgetOrder: WorkspaceWidget.defaultOrder,
        lastSession: nil,
        recommendations: [],
        facts: NovaFacts(),
        readAt: .distantPast
    )
}

// MARK: - Use case

/// Assembles the Smart Workspace: reads the same stores the tabs read,
/// turns them into `NovaFacts`, asks the advisor and the layout policy, and
/// returns one snapshot. Each source fails independently — a profile
/// library that cannot be read never blanks the certificate advice.
struct SmartWorkspaceService {

    let identityStore: any IdentityStore
    let profiles: ProvisioningProfileLibrary?
    let library: ApplicationLibrary
    let signingHistory: (any SigningHistoryStore)?
    let state: any WorkspaceStateStore
    var advisor = NovaAdvisor()
    var layout = WorkspaceLayoutPolicy()
    var clock: () -> Date = { Date() }

    init(
        identityStore: any IdentityStore,
        profiles: ProvisioningProfileLibrary?,
        library: ApplicationLibrary,
        signingHistory: (any SigningHistoryStore)?,
        state: any WorkspaceStateStore,
        advisor: NovaAdvisor = NovaAdvisor(),
        layout: WorkspaceLayoutPolicy = WorkspaceLayoutPolicy(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.identityStore = identityStore
        self.profiles = profiles
        self.library = library
        self.signingHistory = signingHistory
        self.state = state
        self.advisor = advisor
        self.layout = layout
        self.clock = clock
    }

    func snapshot(activeSigningJobs: Int = 0, activeDownloads: Int = 0) async -> SmartWorkspaceSnapshot {
        let now = clock()
        let facts = await collectFacts(now: now)
        let session = (try? state.lastSession()).flatMap { $0.isResumable(now: now) ? $0 : nil }
        let usage = (try? state.usage()) ?? []

        let context = WorkspaceContext(
            hasLastSession: session != nil,
            activeSigningJobs: activeSigningJobs,
            activeDownloads: activeDownloads,
            expiringProfiles: facts.profiles.filter { NovaAdvisor.wholeDays(from: now, to: $0.expiresAt) <= advisor.expiryWarningDays }.count,
            expiringCertificates: facts.certificates.filter { NovaAdvisor.wholeDays(from: now, to: $0.expiresAt) <= advisor.expiryWarningDays }.count,
            daysSinceBackup: facts.daysSinceBackup
        )

        return SmartWorkspaceSnapshot(
            greeting: WorkspaceDaypart(hour: Calendar.current.component(.hour, from: now)).greeting,
            widgetOrder: layout.order(usage: usage, context: context, now: now),
            lastSession: session,
            recommendations: advisor.recommendations(for: facts, now: now),
            facts: facts,
            readAt: now
        )
    }

    /// Records that the user opened a widget. Failure to record is not an
    /// error the user needs to hear about.
    func noteOpened(_ widget: WorkspaceWidget) {
        try? state.recordOpen(of: widget, at: clock())
    }

    /// Records what the user is doing now, for “Continue Last Session”.
    func noteSession(_ activity: WorkspaceSession.Activity, recordID: String? = nil, displayName: String? = nil) {
        try? state.setLastSession(WorkspaceSession(
            activity: activity,
            applicationRecordID: recordID,
            applicationDisplayName: displayName,
            recordedAt: clock()
        ))
    }

    func clearSession() {
        try? state.setLastSession(nil)
    }

    // MARK: - Facts

    func collectFacts(now: Date) async -> NovaFacts {
        var facts = NovaFacts()

        if let identities = try? identityStore.listIdentities() {
            facts.certificates = identities.map {
                NovaFacts.CertificateFact(
                    name: $0.certificate.subjectCommonName ?? "Certificate",
                    expiresAt: $0.certificate.notValidAfter
                )
            }
        }

        if let profiles, let summaries = try? await profiles.allProfiles() {
            facts.profiles = summaries.map {
                NovaFacts.ProfileFact(
                    name: $0.name,
                    expiresAt: $0.expirationDate,
                    bundleIdentifierPatterns: $0.bundleIdentifierPatterns
                )
            }
        }

        var signedBundles = Set<String>()
        if let signingHistory, let records = try? await signingHistory.allRecords() {
            for record in records where record.outcome.isSuccess {
                if let bundle = record.sourceBundleIdentifier { signedBundles.insert(bundle) }
            }
        }

        if let entries = try? await library.entries() {
            facts.applications = entries.map { entry in
                let bundle = entry.record.bundleIdentifier.rawValue
                return NovaFacts.ApplicationFact(
                    displayName: entry.record.displayName ?? bundle,
                    bundleIdentifier: bundle,
                    importedAt: entry.record.importedAt,
                    wasSignedBefore: signedBundles.contains(bundle)
                )
            }
        }

        return facts
    }
}
