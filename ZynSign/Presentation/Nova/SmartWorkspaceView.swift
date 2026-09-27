import SwiftUI

/// The Smart Workspace — the command center Home shows once the release
/// train switches it on.
///
/// The view renders one `SmartWorkspaceSnapshot`: a greeting, the Nova
/// Assistant's suggestions (when that feature is on), and the widgets in
/// the order the layout policy chose. It reads nothing itself — every fact
/// on screen came through `SmartWorkspaceService`, which read the same
/// stores the tabs read — and it never acts on a suggestion: each card is a
/// door to the tab that owns the work.
///
/// The cards are the shared dashboard components in `DesignSystem`; this
/// file only maps Domain values onto them.
struct SmartWorkspaceView: View {

    let service: SmartWorkspaceService
    let entries: [LibraryEntry]
    var onOpenSection: (ShellSection) -> Void = { _ in }
    var onOpenSigningQueue: () -> Void = {}
    var onOpenInstallation: () -> Void = {}

    @Environment(\.applicationEnvironment) private var environment
    @State private var snapshot: SmartWorkspaceSnapshot = .empty
    @State private var dismissed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.lg) {
            GreetingCard(greeting: snapshot.greeting, title: "ZynSign Workspace", subtitle: summaryLine)
            if ReleaseTrain.isAvailable(.novaAssistant), !visibleRecommendations.isEmpty {
                assistantCard
            }
            ForEach(snapshot.widgetOrder, id: \.self) { widget in
                widgetView(widget)
            }
        }
        .task { await refresh() }
        .onReceive(environment.importHub.$items) { _ in
            Task { await refresh() }
        }
    }

    private var summaryLine: String {
        let facts = snapshot.facts
        return "\(facts.applications.count) apps · \(facts.certificates.count) identities · \(facts.profiles.count) profiles"
    }

    // MARK: - Nova Assistant

    private var visibleRecommendations: [NovaRecommendation] {
        snapshot.recommendations.filter { !dismissed.contains($0.id) }
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(ZynBrand.indigoTop)
                    .accessibilityHidden(true)
                Text("Nova")
                    .font(ZTypography.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("On-device · suggestions only")
                    .font(ZTypography.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleRecommendations) { recommendation in
                NovaRecommendationRow(recommendation: recommendation) {
                    open(recommendation.destination)
                } onDismiss: {
                    withAnimation(ZMotion.interactive) {
                        _ = dismissed.insert(recommendation.id)
                    }
                }
                if recommendation.id != visibleRecommendations.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    private func open(_ destination: NovaRecommendation.Destination?) {
        ZHaptics.play(.navigate)
        switch destination {
        case .certificates: onOpenSection(.certificates)
        case .profiles: onOpenSection(.profiles)
        case .library, .signing: onOpenSection(.library)
        case .backup: onOpenSection(.settings)
        case nil: break
        }
    }

    // MARK: - Widgets

    private func card<Content: View>(_ widget: WorkspaceWidget, actionTitle: String? = nil, action: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) -> some View {
        ZDashboardCard(title: widget.title, symbol: widget.symbolName, actionTitle: actionTitle, action: action, content: content)
    }

    private func openSection(_ widget: WorkspaceWidget, _ section: ShellSection) {
        service.noteOpened(widget)
        ZHaptics.play(.navigate)
        onOpenSection(section)
    }

    @ViewBuilder
    private func widgetView(_ widget: WorkspaceWidget) -> some View {
        switch widget {
        case .continueLastSession:
            if let session = snapshot.lastSession {
                card(widget) {
                    ZDashboardLinkRow(title: session.summary, symbol: "arrow.uturn.forward", detail: session.recordedAt.formatted(.relative(presentation: .named))) {
                        openSection(widget, .library)
                    }
                }
            }
        case .quickSign:
            if let entry = recentEntries.first {
                card(widget) {
                    NavigationLink(value: entry) {
                        QuickActionCard(
                            title: "Sign \(entry.record.displayName ?? "Application")",
                            subtitle: quickSignHint(for: entry),
                            symbol: "signature"
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { service.noteOpened(widget) })
                    .accessibilityHint("Opens the most recent app with signing one tap away.")
                }
            }
        case .healthScore:
            if let entry = recentEntries.first, let app = fact(for: entry) {
                let report = InstallHealthReport.preview(for: app, facts: snapshot.facts, now: snapshot.readAt)
                card(widget) {
                    HealthCard(
                        score: report.score,
                        verdict: report.verdict.title,
                        subject: entry.record.displayName ?? "Application",
                        tint: tint(for: report),
                        rows: report.checks.filter { $0.status != .notPerformed }.map { check in
                            HealthCard.Row(
                                id: check.kind.rawValue,
                                title: check.kind.title,
                                note: check.note,
                                outcome: check.status == .failed ? .failed : (check.note.contains("expires in") ? .warning : .passed)
                            )
                        },
                        footnote: report.notPerformed.isEmpty ? nil
                            : "\(report.notPerformed.count) checks run when you sign: entitlements, frameworks, signature, device."
                    )
                }
            }
        case .recentApps:
            if !entries.isEmpty {
                card(widget, actionTitle: "Open Library", action: { openSection(widget, .library) }) {
                    RecentListCard(items: recentEntries, id: \.record.id) { entry in
                        NavigationLink(value: entry) {
                            RecentApplicationRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .signingQueue:
            if SigningQueueAvailability.isAvailable {
                card(widget) {
                    ZDashboardLinkRow(title: "Open the signing queue", symbol: "tray.full") {
                        service.noteOpened(widget); ZHaptics.play(.navigate); onOpenSigningQueue()
                    }
                }
            }
        case .downloads:
            if ReleaseTrain.isAvailable(.downloads) {
                card(widget) {
                    DownloadCard(active: 0) { openSection(widget, .downloads) }
                }
            }
        case .identityHealth:
            if ReleaseTrain.isAvailable(.identityCenter) {
                card(widget) {
                    IdentityCard(
                        total: snapshot.facts.certificates.count,
                        expiring: snapshot.facts.certificates.filter { NovaAdvisor.wholeDays(from: snapshot.readAt, to: $0.expiresAt) <= 14 }.count
                    ) { openSection(widget, .certificates) }
                }
            }
        case .profileExpiry:
            if ReleaseTrain.isAvailable(.provisioningProfileManager), let soonest = snapshot.facts.profiles.min(by: { $0.expiresAt < $1.expiresAt }) {
                let days = NovaAdvisor.wholeDays(from: snapshot.readAt, to: soonest.expiresAt)
                card(widget) {
                    ZDashboardLinkRow(
                        title: days < 0 ? "“\(soonest.name)” has expired" : "Next expiry: “\(soonest.name)” in \(NovaAdvisor.dayPhrase(days))",
                        symbol: days <= 14 ? "calendar.badge.exclamationmark" : "calendar"
                    ) { openSection(widget, .profiles) }
                }
            }
        case .backupStatus:
            card(widget) {
                ZDashboardLinkRow(title: "Recovery & backups in Settings", symbol: "externaldrive.badge.timemachine") {
                    openSection(widget, .settings)
                }
            }
        case .collections:
            if ReleaseTrain.isAvailable(.libraryPowerFeatures), !entries.isEmpty {
                card(widget) {
                    ZDashboardLinkRow(title: "Browse collections", symbol: "folder") { openSection(widget, .library) }
                }
            }
        case .activity:
            if ReleaseTrain.isAvailable(.activityJournal) {
                card(widget) {
                    ZDashboardLinkRow(title: "Local activity journal", symbol: "list.bullet.rectangle") { openSection(widget, .settings) }
                }
            }
        }
    }

    // MARK: - Domain → card values

    private func tint(for report: InstallHealthReport) -> Color {
        switch report.verdict {
        case .ready: return ZColors.success
        case .attention: return report.score >= 50 ? ZynBrand.indigoTop : ZColors.warning
        case .blocked: return ZColors.error
        }
    }

    private func fact(for entry: LibraryEntry) -> NovaFacts.ApplicationFact? {
        let bundle = entry.record.bundleIdentifier.rawValue
        return snapshot.facts.applications.first { $0.bundleIdentifier == bundle && $0.displayName == (entry.record.displayName ?? bundle) }
            ?? snapshot.facts.applications.first { $0.bundleIdentifier == bundle }
    }

    private func quickSignHint(for entry: LibraryEntry) -> String {
        guard let app = fact(for: entry) else { return "Open the app, then Sign." }
        let report = InstallHealthReport.preview(for: app, facts: snapshot.facts, now: snapshot.readAt)
        switch report.verdict {
        case .blocked: return report.failed.first?.note ?? "Something needs attention first."
        case .attention, .ready:
            return app.wasSignedBefore ? "Signed before — same identity and profile are ready." : "Identity and profile are in place."
        }
    }

    private var recentEntries: [LibraryEntry] {
        Array(entries.sorted { $0.record.importedAt > $1.record.importedAt }.prefix(4))
    }

    // MARK: - Reading

    private func refresh() async {
        let fresh = await service.snapshot()
        withAnimation(ZMotion.relaxed) {
            snapshot = fresh
        }
    }
}

// MARK: - Nova row (Domain-specific, stays here)

private struct NovaRecommendationRow: View {
    let recommendation: NovaRecommendation
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.title).font(.subheadline.weight(.semibold))
                Text(recommendation.detail)
                    .font(ZTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if recommendation.destination != nil {
                Button("Open", action: onOpen)
                    .font(.footnote.weight(.semibold))
                    .zComfortableHitTarget()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .zComfortableHitTarget()
            .accessibilityLabel("Dismiss suggestion")
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch recommendation.severity {
        case .urgent: return "exclamationmark.octagon.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .info: return "lightbulb.fill"
        }
    }

    private var tint: Color {
        switch recommendation.severity {
        case .urgent: return ZColors.error
        case .attention: return ZColors.warning
        case .info: return ZynBrand.indigoTop
        }
    }
}
