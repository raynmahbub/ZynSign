import SwiftUI
import UIKit

/// The Developer Identity Center dashboard.
///
/// One screen answers every signing-identity question ZynSign can answer:
/// how many teams, certificates, and profiles the user holds, how many are
/// healthy, which conflicts the facts contain, what expires next, how the
/// identities group by team, how they relate, and what happened recently.
/// Everything on screen is a projection of the one snapshot the model
/// holds, so the dashboard, the workspace, the inspectors, and the graphs
/// can never disagree.
///
/// Security posture, shown and enforced:
/// - Private keys are never displayed, never exported, and never leave the
///   Keychain; the footer says so.
/// - Removing a registration asks for confirmation and — where the
///   platform supports it — authentication before the store is touched.
/// - No row shows more than the metadata the stores already publish.
struct IdentityCenterView: View {

    @StateObject private var model: IdentityCenterModel
    @Environment(\.appLock) private var appLock

    /// The certificate pending removal, when the confirmation is up.
    @State private var certificatePendingRemoval: IdentityCenterCertificate?

    /// The certificate whose linked profiles are being shown.
    @State private var certificateForLinkedProfiles: IdentityCenterCertificate?

    /// The certificate whose compatible apps are being shown.
    @State private var certificateForCompatibleApps: IdentityCenterCertificate?

    /// The profile whose compatible apps are being shown.
    @State private var profileForCompatibleApps: IdentityCenterProfile?

    /// A copy confirmation the toast shows.
    @State private var toastMessage: String?
    @State private var isShowingToast = false

    /// Creates the center over a service.
    init(service: IdentityCenterService) {
        _model = StateObject(wrappedValue: IdentityCenterModel(service: service))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                loadingView
            case .failed(let message):
                failedView(message)
            case .loaded(let snapshot):
                dashboard(snapshot)
            }
        }
        .navigationTitle("Developer Identity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .confirmationDialog(
            "Remove “\(certificatePendingRemoval?.displayName ?? "this certificate")”?",
            isPresented: Binding(
                get: { certificatePendingRemoval != nil },
                set: { if !$0 { certificatePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Registration", role: .destructive) {
                Task { await confirmRemoval() }
            }
            Button("Cancel", role: .cancel) { certificatePendingRemoval = nil }
        } message: {
            Text("ZynSign forgets the registration. The certificate and its key are not deleted, and nothing leaves the Keychain.")
        }
        .sheet(item: $certificateForLinkedProfiles) { certificate in
            LinkedProfilesSheet(certificate: certificate, snapshot: model.loadedSnapshot)
        }
        .sheet(item: $certificateForCompatibleApps) { certificate in
            CompatibleAppsSheet(
                title: "Compatible Apps",
                apps: certificate.compatibleApps,
                subjectName: certificate.displayName
            )
        }
        .sheet(item: $profileForCompatibleApps) { profile in
            CompatibleAppsSheet(
                title: "Compatible Apps",
                apps: profile.compatibleApps,
                subjectName: profile.displayName
            )
        }
        .zToast(
            isPresented: $isShowingToast,
            message: toastMessage ?? "",
            style: .success,
            duration: .seconds(2)
        )
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            toastMessage = "\(notice.title) — \(notice.message)"
            model.clearNotice()
            withAnimation { isShowingToast = true }
        }
    }

    // MARK: - Phases

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                ZSkeleton(rows: 1)
                ZSkeleton(rows: 2)
                ZSkeleton(rows: 3)
            }
            .padding(ZSpacing.md)
        }
        .accessibilityLabel("Loading the Developer Identity Center")
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Identity Center Unavailable", systemImage: "key.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await model.refresh() } }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Dashboard

    private func dashboard(_ snapshot: IdentityCenterSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZSpacing.lg, pinnedViews: []) {
                headerSection(snapshot)
                if !snapshot.conflicts.isEmpty {
                    conflictSection(snapshot)
                }
                if !snapshot.forecast.isEmpty {
                    forecastSection(snapshot)
                }
                teamWorkspaceSection(snapshot)
                healthCenterSection(snapshot)
                graphSection
                if !snapshot.timeline.isEmpty {
                    timelineSection(snapshot)
                }
                securityFooter
            }
            .padding(ZSpacing.md)
        }
    }

    // MARK: Header

    private func headerSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: overallStatus(of: snapshot).symbolName)
                    .foregroundStyle(IdentityCenterPalette.color(for: overallStatus(of: snapshot)))
                Text("Developer Identity")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Validation")
                .disabled(model.isRefreshing)
            }
            Text(spokenOverallSummary(of: snapshot))
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: ZSpacing.sm), GridItem(.flexible(), spacing: ZSpacing.sm)],
                spacing: ZSpacing.sm
            ) {
                IdentityStatCard(
                    value: snapshot.statistics.teamCount,
                    label: "Teams",
                    symbolName: "person.2",
                    tint: Color.accentColor
                )
                IdentityStatCard(
                    value: snapshot.statistics.certificateCount,
                    label: "Certificates",
                    symbolName: "signature",
                    tint: Color.accentColor
                )
                IdentityStatCard(
                    value: snapshot.statistics.profileCount,
                    label: "Profiles",
                    symbolName: "person.text.rectangle",
                    tint: Color.accentColor
                )
                IdentityStatCard(
                    value: snapshot.statistics.healthyCount,
                    label: "Healthy",
                    symbolName: "checkmark.circle.fill",
                    tint: .green
                )
                IdentityStatCard(
                    value: snapshot.statistics.needsAttentionCount,
                    label: "Needs Attention",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func overallStatus(of snapshot: IdentityCenterSnapshot) -> IdentityHealthStatus {
        if snapshot.statistics.needsAttentionCount == 0 { return .healthy }
        let hasBlocking = snapshot.certificates.contains { $0.health.status == .blocked }
            || snapshot.profiles.contains { $0.health.status == .blocked }
        return hasBlocking ? .blocked : .warning
    }

    private func spokenOverallSummary(of snapshot: IdentityCenterSnapshot) -> String {
        if snapshot.statistics.needsAttentionCount == 0 {
            return "All \(snapshot.statistics.certificateCount + snapshot.statistics.profileCount) identities are healthy."
        }
        return "\(snapshot.statistics.healthyCount) healthy, \(snapshot.statistics.needsAttentionCount) need attention."
    }

    // MARK: Conflicts

    private func conflictSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(snapshot.conflicts) { conflict in
                IdentityConflictCard(conflict: conflict)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Forecast

    private func forecastSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack {
                Label("Expiration Forecast", systemImage: "calendar.badge.exclamationmark")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    ExpirationForecastView(snapshot: snapshot)
                } label: {
                    Text("View All")
                        .font(.footnote)
                }
                .accessibilityLabel("View the full expiration forecast, \(snapshot.forecast.count) entries")
            }
            ZCard {
                VStack(spacing: ZSpacing.sm) {
                    ForEach(snapshot.forecast.prefix(3)) { entry in
                        ExpirationForecastRow(entry: entry)
                        if entry.id != snapshot.forecast.prefix(3).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Team workspace

    private func teamWorkspaceSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack {
                Label("Teams", systemImage: "person.2.fill")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Expand All") { model.expandAllTeams() }
                    Button("Collapse All") { model.collapseAllTeams() }
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .accessibilityLabel("Team workspace display options")
            }
            if snapshot.teams.isEmpty {
                emptyTeamNote
            } else {
                ForEach(snapshot.teams) { team in
                    teamCard(team, snapshot: snapshot)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyTeamNote: some View {
        ZCard {
            VStack(spacing: ZSpacing.xs) {
                Image(systemName: "person.2.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No identities yet.")
                    .font(.subheadline)
                Text("Import a .p12 certificate and a .mobileprovision profile, and they group here by team.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func teamCard(_ team: DeveloperTeam, snapshot: IdentityCenterSnapshot) -> some View {
        let isExpanded = model.isTeamExpanded(team.id)
        let certificates = snapshot.certificates.filter { $0.teamKey == team.id }
        let profiles = snapshot.profiles.filter { $0.teamKey == team.id }
        let compatibleCount = Self.compatibleAppCount(
            certificates: certificates,
            profiles: profiles
        )
        return ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        model.toggleTeam(team.id)
                    }
                } label: {
                    TeamWorkspaceHeader(
                        team: team,
                        isExpanded: isExpanded,
                        compatibleAppCount: compatibleCount
                    )
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    if certificates.isEmpty && profiles.isEmpty {
                        Text("This team holds no identities.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(certificates) { certificate in
                        certificateRow(certificate)
                    }
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The deduplicated count of library applications the team's
    /// certificates and profiles can sign together.
    private static func compatibleAppCount(
        certificates: [IdentityCenterCertificate],
        profiles: [IdentityCenterProfile]
    ) -> Int {
        var bundles = Set<String>()
        for certificate in certificates {
            for app in certificate.compatibleApps {
                bundles.insert(app.bundleIdentifier)
            }
        }
        for profile in profiles {
            for app in profile.compatibleApps {
                bundles.insert(app.bundleIdentifier)
            }
        }
        return bundles.count
    }

    // MARK: Rows

    private func certificateRow(_ certificate: IdentityCenterCertificate) -> some View {
        NavigationLink {
            IdentityCertificateInspectorView(model: model, fingerprint: certificate.facts.fingerprintHex)
        } label: {
            HStack(spacing: ZSpacing.sm) {
                IdentityHealthDot(status: certificate.health.status)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: ZSpacing.xxs) {
                        Text(certificate.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if certificate.facts.fingerprintHex == model.loadedSnapshot?.defaultFingerprintHex {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Default identity")
                        }
                    }
                    Text("\(certificate.facts.kind.displayName)\(teamSuffix(certificate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { certificateActions(certificate) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCertificateSummary(certificate))
        .accessibilityHint("Opens the certificate inspector.")
    }

    private func teamSuffix(_ certificate: IdentityCenterCertificate) -> String {
        guard let teamID = certificate.facts.teamID else { return "" }
        return " · Team \(teamID)"
    }

    private func spokenCertificateSummary(_ certificate: IdentityCenterCertificate) -> String {
        var summary = "Certificate \(certificate.displayName). "
        summary += "\(certificate.facts.kind.displayName). "
        summary += certificate.health.spokenSummary
        return summary
    }

    private func profileRow(_ profile: IdentityCenterProfile) -> some View {
        NavigationLink {
            IdentityProfileInspectorView(model: model, profileID: profile.facts.id)
        } label: {
            HStack(spacing: ZSpacing.sm) {
                IdentityHealthDot(status: profile.health.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(profile.summary.resolvedProfileType.displayName) · \(profile.status.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { profileActions(profile) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile \(profile.displayName). \(profile.summary.resolvedProfileType.displayName). \(profile.health.spokenSummary)")
        .accessibilityHint("Opens the profile inspector.")
    }

    // MARK: Quick actions

    @ViewBuilder
    private func certificateActions(_ certificate: IdentityCenterCertificate) -> some View {
        Button {
            Task { await model.setDefault(certificate) }
        } label: {
            Label("Set Default", systemImage: "star")
        }
        Button {
            certificateForLinkedProfiles = certificate
        } label: {
            Label("View Linked Profiles", systemImage: "link")
        }
        Button {
            certificateForCompatibleApps = certificate
        } label: {
            Label("View Compatible Apps", systemImage: "apps.iphone")
        }
        Button {
            Task { await model.refreshValidation() }
        } label: {
            Label("Refresh Validation", systemImage: "arrow.clockwise")
        }
        if let teamID = certificate.facts.teamID {
            Button {
                UIPasteboard.general.string = teamID
                showToast("Team ID \(teamID) copied")
            } label: {
                Label("Copy Team ID", systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            certificatePendingRemoval = certificate
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func profileActions(_ profile: IdentityCenterProfile) -> some View {
        Button {
            Task { await model.refreshValidation() }
        } label: {
            Label("Refresh Validation", systemImage: "arrow.clockwise")
        }
        Button {
            profileForCompatibleApps = profile
        } label: {
            Label("View Compatible Apps", systemImage: "apps.iphone")
        }
        if let teamID = profile.facts.teamID {
            Button {
                UIPasteboard.general.string = teamID
                showToast("Team ID \(teamID) copied")
            } label: {
                Label("Copy Team ID", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: Health center

    private func healthCenterSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            Label("Identity Health", systemImage: "stethoscope")
                .font(.headline)
            ZCard {
                VStack(spacing: ZSpacing.sm) {
                    ForEach(snapshot.certificates) { certificate in
                        healthRow(
                            name: certificate.displayName,
                            kind: "Certificate",
                            status: certificate.health.status,
                            destination: AnyView(
                                IdentityCertificateInspectorView(model: model, fingerprint: certificate.facts.fingerprintHex)
                            )
                        )
                    }
                    ForEach(snapshot.profiles) { profile in
                        healthRow(
                            name: profile.displayName,
                            kind: "Profile",
                            status: profile.health.status,
                            destination: AnyView(
                                IdentityProfileInspectorView(model: model, profileID: profile.facts.id)
                            )
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func healthRow(
        name: String,
        kind: String,
        status: IdentityHealthStatus,
        destination: AnyView
    ) -> some View {
        NavigationLink { destination } label: {
            HStack(spacing: ZSpacing.sm) {
                IdentityHealthDot(status: status)
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind) \(name). \(status.spokenSummary)")
    }

    // MARK: Graph

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            NavigationLink {
                IdentityRelationshipGraphView(snapshot: model.loadedSnapshot ?? IdentityCenterSnapshot.empty)
            } label: {
                ZCard {
                    HStack(spacing: ZSpacing.sm) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Relationship Graph")
                                .font(.subheadline.weight(.semibold))
                            Text("How certificates and profiles connect, team by team.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Timeline

    private func timelineSection(_ snapshot: IdentityCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack {
                Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    IdentityTimelineView(snapshot: snapshot)
                } label: {
                    Text("View All")
                        .font(.footnote)
                }
                .accessibilityLabel("View the full identity timeline")
            }
            ZCard {
                VStack(spacing: ZSpacing.sm) {
                    ForEach(Array(snapshot.timeline.prefix(5))) { event in
                        IdentityTimelineRow(event: event)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Footer

    private var securityFooter: some View {
        Label {
            Text("Private keys stay in the iOS Keychain. The Identity Center reads metadata only — nothing here displays, exports, or transmits key material, and removing a registration never deletes a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Toast

    private func showToast(_ message: String) {
        toastMessage = message
        withAnimation { isShowingToast = true }
        AccessibilityNotification.Announcement(message).post()
    }

    /// The removal the user confirmed: authenticate where the platform
    /// supports it, then remove the registration.
    private func confirmRemoval() async {
        guard let certificate = certificatePendingRemoval else { return }
        certificatePendingRemoval = nil
        let outcome = await appLock.authorize(.removeIdentity)
        guard outcome.isAuthenticated else {
            showToast("Removal needs authentication")
            return
        }
        await model.remove(certificate)
    }
}

extension IdentityCenterSnapshot {

    /// An empty snapshot for previews and for the graph's fallback.
    static let empty = IdentityCenterSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        certificates: [],
        profiles: [],
        teams: [],
        conflicts: [],
        forecast: [],
        timeline: [],
        statistics: IdentityCenterStatistics(
            teamCount: 0,
            certificateCount: 0,
            profileCount: 0,
            healthyCount: 0,
            needsAttentionCount: 0
        ),
        defaultFingerprintHex: nil
    )
}
