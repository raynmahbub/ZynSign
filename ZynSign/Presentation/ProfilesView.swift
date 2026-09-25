import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Profiles area: ZynSign's Provisioning Profile Manager.
///
/// The tab lists imported `.mobileprovision` summaries as rows or cards,
/// searchable by name, team, or bundle identifier, sortable by expiration,
/// name, import date, or type, and filterable by type and expiration
/// state. Every card carries the facts the manager promises — name, team
/// name, team ID, profile type, expiration status with remaining days,
/// device count, import date, and a compatibility indicator — plus a
/// "Selected" marker on the profile pinned for signing.
///
/// Importing copies the `.mobileprovision` into ZynSign's profile storage,
/// records the summary, and presents an import summary sheet; a corrupted
/// or unsupported file is refused with the typed reason and nothing is
/// stored. Deleting removes the stored copy and the summary together.
struct ProfilesView: View {

    @StateObject private var model: ProvisioningProfilesModel

    @AppStorage("zynsign.profiles.showsGrid") private var showsGrid = false

    /// Creates the tab over the profile library, importer, compatibility
    /// use case, and selection store the composition root supplied. `nil`
    /// library renders an honest unavailable state; `nil` importer
    /// disables importing with a written reason rather than a dead control.
    init(
        profiles: ProvisioningProfileLibrary?,
        importer: ProvisioningProfileImporter?,
        compatibility: ProfileCompatibilityUseCase? = nil,
        selections: (any ProfileSelectionStore)? = nil,
        recordEvent: ((String, Bool) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: ProvisioningProfilesModel(
            profiles: profiles,
            importer: importer,
            compatibility: compatibility,
            selections: selections,
            recordEvent: recordEvent
        ))
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.clearNotice() } }
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(ShellSection.profiles.title)
                .navigationDestination(for: ProvisioningProfileSummary.self) { summary in
                    ProfileDetailView(summary: summary) {
                        Task { await model.refresh() }
                    }
                }
                .navigationDestination(item: $model.pendingDetail) { summary in
                    ProfileDetailView(summary: summary) {
                        Task { await model.refresh() }
                    }
                }
                .searchable(
                    text: $model.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Name, Team, or Bundle ID")
                )
                .toolbar { toolbarContent }
        }
        .task { await model.load() }
        .fileImporter(
            isPresented: Binding(
                get: { model.isShowingImporter },
                set: { model.isShowingImporter = $0 }
            ),
            allowedContentTypes: ProvisioningProfilesModel.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            model.handlePickerResult(result)
        }
        .sheet(item: $model.importedProfile) { summary in
            ProfileImportSummaryView(
                summary: summary,
                report: model.report(for: summary),
                onViewDetails: {
                    model.pendingDetail = summary
                    model.importedProfile = nil
                }
            )
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: noticeBinding,
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { summary in
            Button("Delete Profile", role: .destructive) {
                let pending = summary
                model.pendingRemoval = nil
                Task { await model.remove(pending) }
            }
            Button("Cancel", role: .cancel) {
                model.pendingRemoval = nil
            }
        } message: { summary in
            Text("“\(summary.name)” and its stored .mobileprovision file will be permanently deleted. This cannot be undone.")
        }
        .zToast(
            isPresented: Binding(
                get: { model.isShowingToast },
                set: { model.isShowingToast = $0 }
            ),
            message: model.toastMessage,
            style: model.toastStyle
        )
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { ZSkeleton(rows: 4).padding() }
                .accessibilityLabel("Loading profiles")
        case .empty:
            emptyContent
        case .failed(let message):
            ContentUnavailableView {
                Label("Profiles Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            profileContent
        }
    }

    /// The friendly empty state: an illustration, an explanation in plain
    /// words, and the one action that matters.
    private var emptyContent: some View {
        ContentUnavailableView {
            VStack(spacing: ZSpacing.sm) {
                ProfilesEmptyIllustration()
                Text("No Profiles Yet")
                    .font(.title3.weight(.semibold))
            }
        } description: {
            Text("A profile tells iOS which apps your certificates may sign. Import a .mobileprovision file — ZynSign reads it, keeps the original safe on this device, and helps you choose the right profile for each app.")
        } actions: {
            if model.canImport {
                Button("Import Profile…") {
                    model.showImporter()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Profile importing is not available in this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The loaded library: the visible projection of the current search,
    /// sort, and filters, with explicit states when nothing matches.
    @ViewBuilder
    private var profileContent: some View {
        let summaries = model.visibleProfiles()
        if summaries.isEmpty && hasActiveQuery {
            ContentUnavailableView.search(Text(model.searchText))
        } else if summaries.isEmpty {
            ContentUnavailableView {
                Label("No Matching Profiles", systemImage: ShellSection.profiles.symbolName)
            } description: {
                Text("Every profile is filtered out by the current search or filters.")
            } actions: {
                Button("Clear Search and Filters") {
                    model.searchText = ""
                    model.typeFilter = .all
                    model.expirationFilter = .all
                }
            }
        } else if showsGrid {
            profileGrid(summaries)
        } else {
            profileList(summaries)
        }
    }

    private var hasActiveQuery: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func profileList(_ summaries: [ProvisioningProfileSummary]) -> some View {
        List {
            Section {
                ForEach(summaries, id: \.id) { summary in
                    NavigationLink(value: summary) {
                        ProvisioningProfileRow(
                            summary: summary,
                            report: model.report(for: summary),
                            isPreferred: model.preferredProfileID == summary.id
                        )
                    }
                    .contextMenu { contextActions(for: summary) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        useForSigningSwipeAction(summary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            model.requestRemoval(summary)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("\(summaries.count) profile\(summaries.count == 1 ? "" : "s") · Profiles are read from each file's own declarations; ZynSign adds nothing to them.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }

    private func profileGrid(_ summaries: [ProvisioningProfileSummary]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: ZSpacing.sm)],
                spacing: ZSpacing.sm
            ) {
                ForEach(summaries, id: \.id) { summary in
                    NavigationLink(value: summary) {
                        ProvisioningProfileCard(
                            summary: summary,
                            report: model.report(for: summary),
                            isPreferred: model.preferredProfileID == summary.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextActions(for: summary) }
                }
            }
            .padding(ZSpacing.sm)
        }
        .refreshable { await model.refresh() }
    }

    // MARK: - Quick actions

    /// The quick actions every entry point offers: View Details, Use for
    /// Signing, Copy Team ID, Copy Bundle ID, Refresh Validation, Remove.
    @ViewBuilder
    private func contextActions(for summary: ProvisioningProfileSummary) -> some View {
        Button {
            model.pendingDetail = summary
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
        Button {
            model.useForSigning(summary)
            ZHaptics.tap()
            model.toast("“\(summary.name)” selected for signing. Apps it suits will suggest it first.")
        } label: {
            Label("Use for Signing", systemImage: "checkmark.shield")
        }
        if let team = summary.teamIdentifier {
            Button {
                UIPasteboard.general.string = team
                model.toast("Team ID copied.", style: .info)
            } label: {
                Label("Copy Team ID", systemImage: "person.text.rectangle")
            }
        }
        if let bundleID = copyableBundleIdentifier(for: summary) {
            Button {
                UIPasteboard.general.string = bundleID
                model.toast("Bundle ID copied.", style: .info)
            } label: {
                Label("Copy Bundle ID", systemImage: "app.badge.checkmark")
            }
        }
        Button {
            Task { await model.refreshValidation(summary) }
        } label: {
            Label("Refresh Validation", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            model.requestRemoval(summary)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func useForSigningSwipeAction(_ summary: ProvisioningProfileSummary) -> some View {
        Button {
            model.useForSigning(summary)
            ZHaptics.tap()
            model.toast("“\(summary.name)” selected for signing. Apps it suits will suggest it first.")
        } label: {
            Label("Use for Signing", systemImage: "checkmark.shield")
        }
        .tint(.blue)
    }

    /// The identifier a "Copy Bundle ID" action copies: the explicit bundle
    /// identifier when the profile has one, otherwise the first declared
    /// pattern, otherwise the full App ID.
    private func copyableBundleIdentifier(for summary: ProvisioningProfileSummary) -> String? {
        if let bundle = summary.bundleIdentifier { return bundle }
        if let pattern = summary.bundleIdentifierPatterns.first { return pattern }
        return summary.applicationIdentifier
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            sortMenu
            filterMenu
            layoutToggle
            Button {
                model.showImporter()
            } label: {
                Label("Import Profile…", systemImage: "plus")
            }
            .disabled(!model.canImport || model.isImporting)
            .accessibilityHint("Imports a .mobileprovision file into the profile library.")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(ProvisioningProfilesModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort profiles")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $model.typeFilter) {
                ForEach(ProvisioningProfilesModel.TypeFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Picker("Expiration", selection: $model.expirationFilter) {
                ForEach(ProvisioningProfilesModel.ExpirationFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            if model.typeFilter != .all || model.expirationFilter != .all {
                Button("Clear Filters") {
                    model.typeFilter = .all
                    model.expirationFilter = .all
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.typeFilter == .all && model.expirationFilter == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel("Filter profiles by type and expiration")
    }

    private var layoutToggle: some View {
        Button {
            ZHaptics.tap()
            withAnimation(.easeInOut(duration: 0.2)) {
                showsGrid.toggle()
            }
        } label: {
            Label(
                showsGrid ? "List View" : "Grid View",
                systemImage: showsGrid ? "list.bullet" : "square.grid.2x2"
            )
        }
        .accessibilityLabel(showsGrid ? "Switch to list view" : "Switch to grid view")
    }
}

// MARK: - Row

/// One profile row: name, team, type and expiration badges, device count,
/// import date, and the compatibility indicator the manager computes.
struct ProvisioningProfileRow: View {

    let summary: ProvisioningProfileSummary
    let report: ProfileCompatibilityReport?
    let isPreferred: Bool

    private var assessment: ProfileExpirationAssessment {
        summary.expirationAssessment()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ZSpacing.xs) {
                Text(summary.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPreferred {
                    ZStatusBadge("Selected", systemImage: "star.fill", kind: .info)
                }
            }
            if let teamLine {
                Text(teamLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: ZSpacing.xs) {
                ProfileTypeBadge(type: summary.resolvedProfileType)
                ProfileExpirationBadge(assessment)
                if let devices = summary.deviceCount {
                    ZStatusBadge(
                        "\(devices) device\(devices == 1 ? "" : "s")",
                        systemImage: "iphone",
                        kind: .neutral
                    )
                } else if summary.resolvedProfileType == .enterprise {
                    ZStatusBadge("All devices", systemImage: "iphone", kind: .neutral)
                }
            }
            HStack {
                Text("Imported \(summary.importedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: ZSpacing.xs)
                if let report {
                    ProfileCompatibilityBadge(outcome: report.overall)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var teamLine: String? {
        switch (summary.teamName, summary.teamIdentifier) {
        case (let name?, let team?): return "\(name) · \(team)"
        case (let name?, nil): return name
        case (nil, let team?): return team
        case (nil, nil): return nil
        }
    }

    private var accessibilityDescription: String {
        var parts = [summary.name]
        if let teamLine { parts.append(teamLine) }
        parts.append("\(summary.resolvedProfileType.displayName) profile, \(assessment.countdownText)")
        if let devices = summary.deviceCount {
            parts.append("\(devices) device\(devices == 1 ? "" : "s")")
        }
        parts.append("imported \(summary.importedAt.formatted(date: .abbreviated, time: .omitted))")
        if let report {
            parts.append("compatibility \(report.overall.displayName)")
        }
        if isPreferred { parts.append("selected for signing") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card

/// The grid card: the same facts as the row, stacked for a narrower cell.
struct ProvisioningProfileCard: View {

    let summary: ProvisioningProfileSummary
    let report: ProfileCompatibilityReport?
    let isPreferred: Bool

    private var assessment: ProfileExpirationAssessment {
        summary.expirationAssessment()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
                Text(summary.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isPreferred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Selected for signing")
                }
            }
            if let teamLine = summary.teamName ?? summary.teamIdentifier {
                Text(teamLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: ZSpacing.xs) {
                ProfileTypeBadge(type: summary.resolvedProfileType)
                if let devices = summary.deviceCount {
                    ZStatusBadge("\(devices)", systemImage: "iphone", kind: .neutral)
                } else if summary.resolvedProfileType == .enterprise {
                    ZStatusBadge("All devices", systemImage: "iphone", kind: .neutral)
                }
            }
            ProfileExpirationBadge(assessment)
            HStack {
                Text("Imported \(summary.importedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let report {
                    ProfileCompatibilityBadge(outcome: report.overall)
                }
            }
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ZRadius.card)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZRadius.card)
                .stroke(isPreferred ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [summary.name]
        if let team = summary.teamName ?? summary.teamIdentifier { parts.append(team) }
        parts.append("\(summary.resolvedProfileType.displayName) profile, \(assessment.countdownText)")
        if let report { parts.append("compatibility \(report.overall.displayName)") }
        if isPreferred { parts.append("selected for signing") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Empty-state illustration

/// A friendly, asset-free illustration for the empty library: the profile
/// symbol on a soft disc, dressed with a sparkle. SF Symbols keep the empty
/// state crisp at every Dynamic Type size and in Dark Mode without adding
/// image assets to the bundle.
struct ProfilesEmptyIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 120, height: 120)
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.orange)
                .offset(x: 38, y: -34)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Import summary

/// The import summary sheet: what ZynSign read from the file just imported,
/// the compatibility quick look, and where the original bytes now live.
/// "View Details" opens the full profile detail screen.
struct ProfileImportSummaryView: View {

    let summary: ProvisioningProfileSummary
    let report: ProfileCompatibilityReport?
    let onViewDetails: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: ZSpacing.xs) {
                        ZStatusBadge("Imported", systemImage: "checkmark.seal.fill", kind: .success)
                        Text("“\(summary.name)” was added to your profile library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Section("Profile Facts") {
                    LabeledContent("Name", value: summary.name)
                    if let teamName = summary.teamName {
                        LabeledContent("Team", value: teamName)
                    }
                    if let team = summary.teamIdentifier {
                        LabeledContent("Team ID", value: team)
                    }
                    LabeledContent("Type", value: summary.resolvedProfileType.displayName)
                    LabeledContent("App ID") {
                        Text(summary.applicationIdentifier ?? "—")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    if let bundle = summary.bundleIdentifier {
                        LabeledContent("Bundle ID", value: bundle)
                        LabeledContent("App ID Kind", value: summary.isWildcard ? "Wildcard" : "Explicit")
                    }
                    LabeledContent("Devices", value: deviceText)
                    if let created = summary.creationDate {
                        LabeledContent("Created") {
                            Text(created, format: .dateTime.year().month().day())
                        }
                    }
                    LabeledContent("Expires") {
                        HStack(spacing: ZSpacing.xs) {
                            Text(summary.expirationDate, format: .dateTime.year().month().day())
                                .monospacedDigit()
                            ProfileExpirationBadge(summary.expirationAssessment())
                        }
                    }
                    if let uuid = summary.uuid {
                        LabeledContent("UUID") {
                            Text(uuid)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let fingerprints = summary.certificateFingerprints, !fingerprints.isEmpty {
                        LabeledContent("Certificates", value: "\(fingerprints.count)")
                    }
                }
                if let report {
                    Section {
                        HStack(spacing: ZSpacing.xs) {
                            ProfileCompatibilityBadge(outcome: report.overall)
                            Text(report.summaryLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("Compatibility")
                    } footer: {
                        Text(report.overall.explanation)
                    }
                }
                Section {
                    Text("The original .mobileprovision file was copied into ZynSign's profile storage on this device and is kept unchanged for signing and re-validation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile Imported")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("View Details") { onViewDetails() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var deviceText: String {
        if let devices = summary.deviceCount {
            return "\(devices)"
        }
        switch summary.resolvedProfileType {
        case .enterprise: return "All devices"
        case .appStore: return "—"
        case .development, .adHoc, .unknown: return "—"
        }
    }
}

// MARK: - Previews

#Preview("Profiles") {
    ProfilesView(
        profiles: CompositionRoot.makeProvisioningProfileLibrary(),
        importer: nil
    )
    .environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
