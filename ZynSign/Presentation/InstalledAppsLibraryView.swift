import SwiftUI

/// The Installed Apps Library: every application ZynSign records as
/// installed, with its version, source, last installation, and update
/// status — and the actions each situation allows.
///
/// Installed apps and imported-only apps are different things and the
/// library keeps them visually distinct: an installed card carries the
/// record's own monogram, its channel, and its update state, never a
/// library signing badge. What belongs to the Library stays in the
/// Library; what the user confirmed lives here.
struct InstalledAppsLibraryView: View {

    @ObservedObject var model: InstallationWorkspaceModel

    @State private var isSelecting = false
    @State private var confirmClearAll = false
    @State private var removalTarget: InstallationWorkspaceModel.InstalledRow?
    @State private var detailRow: InstallationWorkspaceModel.InstalledRow?

    var body: some View {
        content
            .navigationTitle("Installed Apps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.query.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Name or Bundle ID"
            )
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bulkBar }
            .confirmationDialog(
                "Remove “\(removalTarget?.record.displayOrIdentifier ?? "")”?",
                isPresented: Binding(
                    get: { removalTarget != nil },
                    set: { if !$0 { removalTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Record", role: .destructive) {
                    if let target = removalTarget {
                        Task { await model.removeInstalledRecord(target) }
                    }
                    removalTarget = nil
                }
                Button("Cancel", role: .cancel) { removalTarget = nil }
            } message: {
                Text("The record of the installation is removed. The signed artifact, its export, and every other record stay.")
            }
            .confirmationDialog(
                "Remove every installed-app record?",
                isPresented: $confirmClearAll,
                titleVisibility: .visible
            ) {
                Button("Remove All Records", role: .destructive) {
                    Task { await model.clearAllInstalledRecords() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every record in the Installed Apps Library is removed. Signed artifacts, exports, and imported applications are not touched.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.installedRows.isEmpty {
            VStack(spacing: ZSpacing.sm) {
                Image(systemName: "arrow.down.app")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Nothing recorded as installed").font(.headline)
                Text("After a delivery, confirm the attempt on the dashboard — or record an installation from a checklist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            list
        }
    }

    private var list: some View {
        List {
            scopeSection
            ForEach(model.visibleInstalledRows) { row in
                rowView(row)
            }
            if model.visibleInstalledRows.isEmpty {
                Text("No installed app matches the current search and scope.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    /// The scope bar: All, Updates, Recently Installed, Needs Attention.
    private var scopeSection: some View {
        Section {
            Picker("Scope", selection: $model.query.scope) {
                ForEach(InstallationWorkspaceScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("\(model.visibleInstalledRows.count) of \(model.installedRows.count) shown · \(model.counts.updatesAvailable) with updates")
                .font(.caption2)
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func rowView(_ row: InstallationWorkspaceModel.InstalledRow) -> some View {
        if isSelecting {
            Button {
                if model.selection.contains(row.id) {
                    model.selection.remove(row.id)
                } else {
                    model.selection.insert(row.id)
                }
            } label: {
                HStack {
                    Image(systemName: model.selection.contains(row.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.tint)
                    InstalledAppRow(row: row)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                InstalledAppDetailView(model: model, row: row)
            } label: {
                InstalledAppRow(row: row)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    removalTarget = row
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                Button {
                    detailRow = row
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .tint(.blue)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    ZHaptics.tap()
                    model.queueSelected()
                } label: {
                    Label(
                        model.selection.isEmpty ? "Queue Selected (none selected)" : "Queue Selected (\(model.selection.count))",
                        systemImage: "tray.and.arrow.down"
                    )
                }
                .disabled(model.selection.isEmpty)

                Button {
                    ZHaptics.tap()
                    model.verifyAll()
                } label: {
                    Label("Verify All", systemImage: "checkmark.seal")
                }

                Button {
                    ZHaptics.tap()
                    model.prepareAll()
                } label: {
                    Label("Prepare All", systemImage: "wrench.and.screwdriver")
                }

                if model.preparationQueue.failedCount > 0 {
                    Button { model.retryFailedPreparations() } label: {
                        Label("Retry Failed", systemImage: "arrow.clockwise")
                    }
                }
                if model.preparationQueue.completedCount > 0 {
                    Button { model.clearCompletedPreparations() } label: {
                        Label("Clear Completed", systemImage: "tray.full")
                    }
                }

                Divider()

                Button {
                    model.query.order = .recentlyInstalled
                } label: {
                    Label("Order: Recently Installed", systemImage: "clock")
                }
                Button {
                    model.query.order = .name
                } label: {
                    Label("Order: Name", systemImage: "textformat")
                }
                Button {
                    model.query.order = .updateStatus
                } label: {
                    Label("Order: Update Status", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Installed library actions")

            Button {
                ZHaptics.tap()
                withAnimation { isSelecting.toggle() }
                if !isSelecting { model.selection = [] }
            } label: {
                Text(isSelecting ? "Done" : "Select")
            }
        }
    }

    // MARK: - Bulk bar

    @ViewBuilder
    private var bulkBar: some View {
        if isSelecting && !model.selection.isEmpty {
            HStack(spacing: ZSpacing.sm) {
                Button {
                    ZHaptics.tap()
                    model.queueSelected()
                } label: {
                    Label("Queue Selected", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) {
                    Task { await model.removeSelectedRecords() }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .background(.ultraThinMaterial)
        }
    }
}

/// One installed application's details: identity, update state, the
/// artifact relationship, the delivery channel, and the contextual
/// actions.
struct InstalledAppDetailView: View {

    @ObservedObject var model: InstallationWorkspaceModel
    let row: InstallationWorkspaceModel.InstalledRow

    @State private var confirmRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            identitySection
            updateSection
            sourceSection
            relationshipSection
            historySection
            actionsSection
            honestySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.record.displayOrIdentifier)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove “\(row.record.displayOrIdentifier)”?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Record", role: .destructive) {
                Task { await model.removeInstalledRecord(row) }
                // The detail screen describes a record that no longer
                // exists, so it dismisses itself.
                dismissAfterRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The record of the installation is removed. The signed artifact, its export, and every other record stay.")
        }
    }

    /// Pops this detail screen after its record is removed.
    private func dismissAfterRemoval() {
        dismiss()
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: ZSpacing.sm) {
                InstalledAppMark(bundleIdentifier: row.record.bundleIdentifier, name: row.record.displayOrIdentifier, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.record.displayOrIdentifier).font(.headline)
                    Text(row.record.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZStatusBadge(
                    InstallationPresentation.updateLabel(for: row.updateState),
                    systemImage: row.updateState.offersUpdate ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                    kind: InstallationPresentation.badgeKind(for: row.updateState)
                )
            }
            LabeledContent("Installed version", value: row.record.installedVersionDisplay)
            if let installedAt = row.record.lastInstalledAt {
                LabeledContent("Last installation", value: InstallationPresentation.timestamp(installedAt))
            }
            if let channel = row.record.installedChannel {
                LabeledContent("Source", value: channel.displayName)
            }
            LabeledContent("Recorded by you", value: "Since \(InstallationPresentation.day(row.record.recordedAt))")
        } header: {
            Text("Installed Application")
        }
    }

    private var updateSection: some View {
        Section {
            Text(InstallationPresentation.updateExplanation(for: row.updateState))
                .font(.footnote)
            if case .updateAvailable(let candidate) = row.updateState {
                LabeledContent("Newer output", value: candidate.versionDisplay)
                LabeledContent("Artifact", value: candidate.exportFileName)
                if let status = candidate.verificationStatus {
                    LabeledContent("Verification", value: status.displayName)
                }
            }
        } header: {
            Text("Update Status")
        } footer: {
            Text("“Update” delivers the newer signed output through your channel. Whether the device accepts it is the platform's decision.")
        }
    }

    private var sourceSection: some View {
        Section {
            if let event = row.record.latestEvent {
                LabeledContent("Action", value: event.kind.displayName)
                LabeledContent("Confirmed", value: InstallationPresentation.timestamp(event.at))
                if let exportName = event.exportFileName {
                    LabeledContent("Artifact used", value: exportName)
                }
                if let status = event.verificationStatus {
                    LabeledContent("Verification then", value: status.displayName)
                }
                LabeledContent("Channel", value: event.channel.displayName)
                Text(event.channel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.record.latestEvent?.exportFileName != nil && !row.isArtifactHeld {
                Label("The artifact behind this record is no longer held in export storage. The record and its history stay.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Latest Delivery")
        }
    }

    @ViewBuilder
    private var relationshipSection: some View {
        Section {
            NavigationLink {
                InstallationRelationshipView(model: model, row: row)
            } label: {
                Label("Artifact Relationship", systemImage: "arrow.down.app.circle")
            }
        } header: {
            Text("Lifecycle")
        } footer: {
            Text("How this application moved from an import to an installed record, step by step.")
        }
    }

    private var historySection: some View {
        Section {
            ForEach(row.record.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind.displayName).font(.subheadline.weight(.medium))
                    Text("\(event.versionDisplay) · \(InstallationPresentation.timestamp(event.at)) · via \(event.channel.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("This Record's History")
        }
    }

    private var actionsSection: some View {
        Section {
            if let candidate = model.candidateRows.first(where: { $0.candidate.bundleIdentifier == row.record.bundleIdentifier }) {
                if candidate.candidate.exportEntry?.permitsArtifactActions == true {
                    if row.updateState.offersUpdate {
                        NavigationLink {
                            deliveryDestination(for: candidate)
                        } label: {
                            Label("Update…", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    NavigationLink {
                        deliveryDestination(for: candidate)
                    } label: {
                        Label("Reinstall…", systemImage: "arrow.counterclockwise.circle")
                    }
                    Button {
                        Task { await model.verifyAgain(candidate) }
                    } label: {
                        Label("Verify Again", systemImage: "checkmark.shield")
                    }
                } else {
                    Label("Verify the artifact in the Library to enable delivery actions", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) {
                confirmRemoval = true
            } label: {
                Label("Remove Record…", systemImage: "trash")
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("The safest workflow is shown for each situation. Removing the record never removes the signed artifact.")
        }
    }

    @ViewBuilder
    private func deliveryDestination(for candidate: InstallationWorkspaceModel.CandidateRow) -> some View {
        if let entry = candidate.candidate.exportEntry, entry.isAvailable, let fileURL = entry.fileURL {
            InstallationDeliveryView(package: InstallationDeliveryPackage(export: entry.record, fileURL: fileURL))
        } else {
            Text("The artifact is no longer held, so there is nothing to deliver.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var honestySection: some View {
        Section {
            Text(InstallationPresentation.historyHonestyLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
