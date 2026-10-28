import SwiftUI
import UIKit

/// The Sideload Studio: what is installed, when it stops launching, and what
/// the signing materials can do about it — one screen, read from the stores
/// that already own each fact.
///
/// The screen is a workshop, not a claim. Nothing here says an app is
/// installed on a device: a lease says ZynSign signed a package at a moment and
/// that the profile behind it expires on a date, which is what the signing
/// journal recorded and nothing more. A build that is due, or already past its
/// expiry, is offered a re-sign; a build whose application has left the library
/// says so instead of offering a button that cannot work.
///
/// It is pushed from Settings → Devices → Sideloading and from Home's refresh
/// row, so it opens no navigation stack of its own.
struct SideloadStudioView: View {

    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        SideloadStudioContent(environment: environment)
    }
}

/// The studio itself, split out so it can own the model the environment built.
private struct SideloadStudioContent: View {

    let environment: ApplicationEnvironment
    @StateObject private var model: SideloadStudioModel
    @State private var signingEntry: LibraryEntry?
    @State private var blockedNotice: BlockedRefreshNotice?
    @State private var isLoading = true
    @State private var copiedSchedule = false

    @Environment(\.appTheme) private var theme

    init(environment: ApplicationEnvironment) {
        self.environment = environment
        _model = StateObject(wrappedValue: SideloadStudioModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.lg) {
                heroCard
                accountRow
                calendarSection
                refreshQueueSection
                materialsSection
                installedSection
                containerSection
                truthSection
            }
            .padding(ZSpacing.md)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sideload Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .navigationDestination(item: $signingEntry) { entry in
            SigningView(entry: entry)
        }
        .alert(
            "Cannot Sign Again Yet",
            isPresented: Binding(
                get: { blockedNotice != nil },
                set: { if !$0 { blockedNotice = nil } }
            ),
            presenting: blockedNotice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text("\(notice.appName) — \(notice.reason)")
        }
    }

    // MARK: - Reading

    /// The instant every countdown on the screen is measured from.
    ///
    /// It is the model's read instant rather than the clock at render time, so
    /// the hero, the rings and the rows all describe the same snapshot — and a
    /// screenshot can be reproduced.
    private var readInstant: Date { model.lastReadAt ?? Date() }

    private func reload() async {
        isLoading = true
        await model.load()
        isLoading = false
    }

    // MARK: - Hero

    private var heroCard: some View {
        ZStudioHeroCard(
            eyebrow: "Next to expire",
            headline: model.headlineCountdown,
            detail: model.headlineDetail,
            badges: heroBadges,
            fraction: model.nextLease?.remainingFraction(at: readInstant)
        )
    }

    private var heroBadges: [(text: String, tone: SideloadStatusTone)] {
        var badges: [(text: String, tone: SideloadStatusTone)] = []
        if let account = model.activeAccount {
            badges.append((account.shortLabel, .neutral))
        }
        if model.plan.dueCount > 0 {
            badges.append(("\(model.plan.dueCount) to re-sign", .warning))
        } else if !model.plan.isEmpty {
            badges.append(("Nothing due", .success))
        }
        if !model.overLimitAccounts.isEmpty {
            badges.append(("Over an app limit", .error))
        }
        return badges
    }

    // MARK: - Accounts

    /// The four accounts, with the one in play marked.
    ///
    /// Every account is shown, not only the ones that signed something: the
    /// difference between a seven-day and a year-long profile is the decision a
    /// person makes *before* importing a certificate, and a row that only
    /// appears afterwards would teach nothing.
    private var accountRow: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Accounts", subtitle: "What each kind of Apple ID issues")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ZSpacing.sm) {
                    ForEach(SideloadAccount.allCases, id: \.self) { account in
                        ZStudioAccountCard(
                            account: account,
                            usage: model.usage.first { $0.account == account },
                            isActive: account == model.activeAccount
                        )
                    }
                }
                .padding(.horizontal, ZSpacing.xxs)
            }
            if let active = model.activeAccount {
                accountLimits(active)
            } else {
                Text("Import the certificate and profile your account issued, and the studio will name the account it read from the profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountLimits(_ account: SideloadAccount) -> some View {
        ZCard(variant: .outlined) {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                Text(account.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(account.limitRows) { row in
                    HStack {
                        Text(row.title).font(.caption)
                        Spacer(minLength: ZSpacing.xs)
                        Text(row.value)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if !account.uncarriedCapabilities.isEmpty {
                    Text("A profile from this account cannot carry: \(account.uncarriedCapabilities.joined(separator: ", ")).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Refresh queue

    private var refreshQueueSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Refresh queue", subtitle: queueSubtitle)
            if model.plan.due.isEmpty {
                ZCard {
                    HStack(spacing: ZSpacing.sm) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(ZColors.success)
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text(model.leases.isEmpty ? "Nothing signed yet" : "Nothing due")
                                .font(.subheadline.weight(.semibold))
                            Text(model.leases.isEmpty
                                 ? "Import a package, then sign it. The studio tracks the profile's expiry from the signing journal."
                                 : "Every recorded build has more time left than its account's refresh window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ZCard {
                    VStack(spacing: ZSpacing.sm) {
                        ForEach(model.plan.due) { lease in
                            ZStudioLeaseRow(
                                lease: lease,
                                status: lease.status(at: readInstant),
                                daysRemaining: lease.daysRemaining(at: readInstant),
                                fraction: lease.remainingFraction(at: readInstant),
                                now: readInstant,
                                isBusy: false,
                                action: { requestSigning(for: lease) }
                            )
                            if lease.id != model.plan.due.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    /// The queue's one-line subtitle, which counts what stops soonest rather
    /// than repeating the account table.
    private var queueSubtitle: String {
        switch model.urgentCount {
        case 0: return "Re-sign before the profile ends"
        case 1: return "One build stops launching within two days"
        default: return "\(model.urgentCount) builds stop launching within two days"
        }
    }

    // MARK: - Calendar

    /// The next two weeks, one cell per day, keyed by the day a person has to
    /// act rather than the day the build stops launching. Read-only by design:
    /// a calendar is a plan, and the queue below it is the action.
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Next 14 days", subtitle: model.calendarSubtitle)
            ZCard {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ZSpacing.xxs) {
                            ForEach(model.calendarDays) { row in
                                calendarCell(row)
                            }
                        }
                        .padding(.horizontal, ZSpacing.xxs)
                    }
                    .accessibilityLabel("Re-signs over the next fourteen days")
                    if let busiest = model.busiestDayLine {
                        Text(busiest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.calendar.outsideCount > 0 {
                        Text(outsideWindowLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        UIPasteboard.general.string = model.scheduleText
                        copiedSchedule = true
                    } label: {
                        Label(
                            copiedSchedule ? "Schedule copied" : "Copy the schedule",
                            systemImage: copiedSchedule ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .disabled(model.calendar.days.isEmpty)
                    if model.remindersSupported {
                        Divider()
                        Toggle(isOn: Binding(
                            get: { model.remindersEnabled },
                            set: { newValue in Task { await model.setRemindersEnabled(newValue) } }
                        )) {
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text("Remind me before a build stops launching")
                                    .font(.footnote.weight(.medium))
                                Text(model.reminderSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(theme.accent)
                        .accessibilityHint("Posts a local notification on the day a build should be signed again.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What the window could not place, named rather than dropped.
    private var outsideWindowLine: String {
        var parts: [String] = []
        if !model.calendar.beyondWindow.isEmpty {
            parts.append("\(model.calendar.beyondWindow.count) later than the window")
        }
        if !model.calendar.scheduledWithoutDate.isEmpty {
            parts.append("\(model.calendar.scheduledWithoutDate.count) with no expiry recorded")
        }
        return "Outside the window: " + parts.joined(separator: " · ") + "."
    }

    private func calendarCell(_ row: SideloadStudioModel.CalendarDayRow) -> some View {
        VStack(spacing: ZSpacing.xxs) {
            Text(row.weekday)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(row.dayNumber)
                .font(.footnote.weight(row.isToday ? .bold : .regular))
                .monospacedDigit()
            Circle()
                .fill(row.count == 0 ? Color.secondary.opacity(0.18) : theme.accent)
                .frame(width: 6, height: 6)
            Text(row.count == 0 ? " " : "\(row.count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(row.count == 0 ? Color.secondary : theme.accent)
        }
        .frame(width: 34)
        .padding(.vertical, ZSpacing.xxs)
        .background {
            if row.isToday {
                RoundedRectangle(cornerRadius: ZynSignTokens.Radius.sm, style: .continuous)
                    .fill(theme.accent.opacity(0.12))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(calendarCellLabel(row))
    }

    private func calendarCellLabel(_ row: SideloadStudioModel.CalendarDayRow) -> String {
        let day = row.isToday ? "Today" : "\(row.weekday) \(row.dayNumber)"
        switch row.count {
        case 0: return day + ", nothing to re-sign"
        case 1: return day + ", one re-sign"
        default: return day + ", \(row.count) re-signs"
        }
    }

    // MARK: - Materials

    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Signing materials", subtitle: "What a re-sign would use")
            ZCard {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    materialRow(
                        symbol: "signature",
                        title: "Certificates",
                        value: model.identities.isEmpty
                            ? "None imported"
                            : "\(model.usableIdentities.count) of \(model.identities.count) usable"
                    )
                    materialRow(
                        symbol: "person.text.rectangle",
                        title: "Profiles",
                        value: model.profiles.isEmpty ? "None imported" : "\(model.profiles.count) stored"
                    )
                    if !model.expiringIdentities.isEmpty {
                        attentionLine("\(model.expiringIdentities.count) certificate\(model.expiringIdentities.count == 1 ? "" : "s") expire within 30 days.")
                    }
                    if !model.expiringProfiles.isEmpty {
                        attentionLine("\(model.expiringProfiles.count) profile\(model.expiringProfiles.count == 1 ? " expires" : "s expire") within 30 days.")
                    }
                    if !model.canSignAgain {
                        Text("A re-sign needs one usable certificate and one provisioning profile. Add both under Certificates & Profiles, then come back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func materialRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: ZSpacing.xs) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(theme.accent)
            Text(title).font(.caption)
            Spacer(minLength: ZSpacing.xs)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func attentionLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(ZColors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Ledger", subtitle: "Every build the journal recorded")
            if model.leases.isEmpty {
                ZCard(variant: .outlined) {
                    Text("A lease appears here after a signing run delivers a package. ZynSign reads the journal; it keeps no second list of its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ZCard {
                    VStack(spacing: ZSpacing.sm) {
                        ForEach(model.leases) { lease in
                            ZStudioLeaseRow(
                                lease: lease,
                                status: lease.status(at: readInstant),
                                daysRemaining: lease.daysRemaining(at: readInstant),
                                fraction: lease.remainingFraction(at: readInstant),
                                now: readInstant,
                                isBusy: false,
                                action: { requestSigning(for: lease) }
                            )
                            if lease.id != model.leases.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                if let readAt = model.lastReadAt {
                    Text("Read from the journal on \(SideloadStudioModel.formatted(readAt, now: readAt)). The countdowns move when the screen is read again, not while you watch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let notice = model.readNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(ZColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Container

    /// The delivery report: pairing, installation, guest containers and the
    /// package edits a run can make. It is the other half of sideloading — the
    /// build that never reaches an installer — so the studio links to it rather
    /// than repeating it, and keeps one line of it visible.
    private var containerSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("Delivery", subtitle: "Pairing, installation, guest containers")
            NavigationLink {
                SideloadingView(embedsNavigationStack: false)
            } label: {
                ZCard(variant: .outlined) {
                    HStack(spacing: ZSpacing.sm) {
                        Image(systemName: "shippingbox.and.arrow.backward.fill")
                            .font(.title3)
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text("Delivery and guest container")
                                .font(.subheadline.weight(.semibold))
                            Text("Pairing, installation, package edits and guest containers — each row names the requirement this build is missing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            Text(SideloadingTruth.containerEvidenceRule)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Truth

    private var truthSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            sectionHeader("What stays true", subtitle: "Whatever this screen shows")
            ZCard(variant: .outlined) {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    ForEach(SideloadingTruth.leaseStatements + SideloadingTruth.statements, id: \.self) { statement in
                        Text(statement)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func requestSigning(for lease: SideloadLease) {
        ZHaptics.tap()
        if let reason = model.refreshBlockedReason(for: lease) {
            blockedNotice = BlockedRefreshNotice(appName: lease.displayName, reason: reason)
            return
        }
        signingEntry = model.libraryEntry(for: lease)
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Why a lease could not be handed to a signing run, shown once.
private struct BlockedRefreshNotice: Identifiable {
    let id = UUID()
    let appName: String
    let reason: String
}

#Preview {
    NavigationStack {
        SideloadStudioView()
    }
}
