import Foundation
import Combine

/// The presentation-side state machine for the Developer Identity Center.
///
/// The model carries exactly one content phase at a time — loading,
/// loaded, or failed — so the dashboard can never show an empty center
/// while a snapshot is still being computed, and never silently drops a
/// store failure. Every screen of the center reads from the one snapshot
/// the model holds: the dashboard, the team workspace, the inspectors,
/// the forecast, the timeline, and the relationship graph are projections
/// of the same value, so they can never disagree.
///
/// The model coordinates nothing itself: it asks the service for a
/// snapshot, and it forwards the three mutations the center offers —
/// setting the default, clearing it, and removing a registration — to the
/// same stores the certificate manager uses. After every mutation the
/// model rebuilds the snapshot, so what the screens show is what the
/// stores hold.
@MainActor
final class IdentityCenterModel: ObservableObject {

    /// The content phase.
    enum Phase: Equatable {

        /// The first snapshot is being computed.
        case loading

        /// A snapshot is on screen.
        case loaded(IdentityCenterSnapshot)

        /// The identity store could not be read.
        case failed(String)
    }

    /// A one-line outcome the interface shows as a notice.
    struct Notice: Identifiable, Equatable {

        /// The notice's title.
        let title: String

        /// The notice's message.
        let message: String

        /// The notice's identity in the presentation.
        var id: String { title + message }
    }

    /// The current phase.
    @Published private(set) var phase: Phase = .loading

    /// Whether a refresh is in flight beyond the first load.
    @Published private(set) var isRefreshing = false

    /// The teams the user has collapsed. Empty means every team is
    /// expanded — the workspace starts open, since the team grouping is
    /// the point — and a collapse marks only the teams the user closed.
    @Published var collapsedTeamKeys: Set<String> = []

    /// The current notice, when one is showing.
    @Published var notice: Notice?

    /// The snapshot on screen, when the phase is loaded.
    private(set) var snapshot: IdentityCenterSnapshot?

    /// When the current snapshot was computed, for the load-once rule.
    private var lastLoadedAt: Date?

    /// The service the snapshot is computed with.
    private let service: IdentityCenterService

    /// How long a snapshot stays fresh before the next appearance
    /// recomputes it. Kept short: the center is a small read over local
    /// stores, and staleness here would quietly misreport health.
    static let freshnessInterval: TimeInterval = 15

    /// Creates the model over a service.
    init(service: IdentityCenterService) {
        self.service = service
    }

    /// The snapshot when loaded, for view convenience.
    var loadedSnapshot: IdentityCenterSnapshot? {
        if case .loaded(let snapshot) = phase { return snapshot }
        return nil
    }

    // MARK: - Loading

    /// Loads the first snapshot.
    func load() async {
        phase = .loading
        await loadSnapshot(isRefreshing: false)
    }

    /// Forces a fresh snapshot: pull-to-refresh, quick actions, and the
    /// Refresh Validation control all land here.
    func refresh() async {
        if phase != .loading { isRefreshing = true }
        await loadSnapshot(isRefreshing: true)
    }

    /// Loads a snapshot only when none is on screen or the one on screen
    /// has gone stale. The dashboard calls this on appearing, so returning
    /// to the tab never re-reads the Keychain unless the snapshot is old.
    func loadIfNeeded() async {
        if case .loaded = phase,
           let lastLoadedAt,
           Date().timeIntervalSince(lastLoadedAt) < Self.freshnessInterval {
            return
        }
        await refresh()
    }

    /// Expands every team, so the workspace shows the whole picture the
    /// dashboard summary promised.
    func expandAllTeams() {
        collapsedTeamKeys = []
    }

    /// Collapses every team.
    func collapseAllTeams() {
        guard let snapshot = loadedSnapshot else { return }
        collapsedTeamKeys = Set(snapshot.teams.map(\.id))
    }

    /// Toggles one team's expanded state.
    func toggleTeam(_ key: String) {
        if isTeamExpanded(key) {
            collapsedTeamKeys.insert(key)
        } else {
            collapsedTeamKeys.remove(key)
        }
    }

    /// Whether the team is expanded. Teams start expanded — the workspace
    /// is the point — until the user collapses one.
    func isTeamExpanded(_ key: String) -> Bool {
        !collapsedTeamKeys.contains(key)
    }

    private func loadSnapshot(isRefreshing: Bool) async {
        do {
            let snapshot = try await service.snapshot()
            self.snapshot = snapshot
            phase = .loaded(snapshot)
            lastLoadedAt = Date()
        } catch {
            snapshot = nil
            lastLoadedAt = nil
            phase = .failed(Self.failureMessage(for: error))
        }
        if isRefreshing { isRefreshing = false }
    }

    // MARK: - Actions

    /// Marks the certificate as the default signing identity.
    func setDefault(_ certificate: IdentityCenterCertificate) async {
        do {
            try await service.setDefaultIdentityFingerprint(certificate.facts.fingerprintHex)
            await refresh()
        } catch {
            notice = Notice(
                title: "Default Could Not Be Saved",
                message: Self.failureMessage(for: error)
            )
        }
    }

    /// Clears the default-identity mark.
    func clearDefault() async {
        do {
            try await service.setDefaultIdentityFingerprint(nil)
            await refresh()
        } catch {
            notice = Notice(
                title: "Default Could Not Be Saved",
                message: Self.failureMessage(for: error)
            )
        }
    }

    /// Forgets a certificate's registration, after the view has asked the
    /// user to confirm and — where the platform supports it — to
    /// authenticate. The key is never deleted; removing a registration
    /// never touches Keychain key material.
    func remove(_ certificate: IdentityCenterCertificate) async {
        do {
            try await service.removeIdentity(fingerprintHex: certificate.facts.fingerprintHex)
            await refresh()
        } catch {
            notice = Notice(
                title: "Removal Failed",
                message: Self.failureMessage(for: error)
            )
        }
    }

    /// Removes a profile from the profile library, after the view has
    /// asked the user to confirm and — where the platform supports it — to
    /// authenticate. Only ZynSign's stored copy is removed.
    func removeProfile(_ profile: IdentityCenterProfile) async {
        do {
            try await service.removeProfile(id: profile.facts.id)
            await refresh()
        } catch {
            notice = Notice(
                title: "Removal Failed",
                message: Self.failureMessage(for: error)
            )
        }
    }

    /// Rebuilds the snapshot: the Refresh Validation control for a
    /// certificate re-reads the Keychain, and for a profile re-reads the
    /// profile library. The engines then recompute from the fresh facts.
    func refreshValidation() async {
        await refresh()
    }

    /// Clears the notice once it has been shown.
    func clearNotice() {
        notice = nil
    }

    /// The user-presentable message for a failure. A typed error's own
    /// user-facing text carries no diagnostic detail; a foreign error is
    /// reduced to a fixed explanation and is never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "Secure identity storage could not be accessed."
    }
}
