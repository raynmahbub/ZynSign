import SwiftUI

/// Storage Manager — what ZynSign is keeping, and what it will take away.
///
/// The dashboard reports allocated space per category and a total that is the
/// sum of those rows, so a number can always be traced to a location. The
/// actions remove exactly what they name and nothing else: shared directories
/// are restricted to entries ZynSign itself created, and every destructive
/// action asks first.
///
/// The one thing this page will not do is remove an imported application.
/// Imported packages are the library, and the library has its own screen.
struct StorageManagerSection: View {

    @Environment(\.settingsCenter) private var settings
    @State private var isConfirmingTemporaryClear = false
    @State private var isConfirmingCacheClear = false
    @State private var isConfirmingExportPrune = false

    static let descriptor = SettingsSectionDescriptor(
        identifier: .storage,
        title: "Storage",
        symbolName: "internaldrive",
        summary: "What ZynSign keeps, and how to clear it.",
        footer: "Everything here is inside ZynSign's own container. Clearing cache or temporary files never removes an imported application."
    )

    var body: some View {
        List {
            usageSection
            actionsSection
            preferencesSection
            locationsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refreshStorageUsage() }
        .refreshable { await settings.refreshStorageUsage() }
        .alert("Clear Temporary Files?", isPresented: $isConfirmingTemporaryClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await settings.clearTemporaryFiles() } }
        } message: {
            Text("Staged imports and working copies are removed. Exported reports and certificate backups are kept. Imported applications are never touched.")
        }
        .alert("Clear Cache?", isPresented: $isConfirmingCacheClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await settings.clearCache() } }
        } message: {
            Text("Cached application icons are removed and re-created the next time ZynSign shows a library card. Nothing else is affected.")
        }
        .alert("Remove Old Exports?", isPresented: $isConfirmingExportPrune) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await settings.removeOldExports() } }
        } message: {
            Text("Signed packages older than \(settings.preferences.storage.exportRetentionDays) days are permanently deleted from Documents/Signed. This cannot be undone.")
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        Section {
            if settings.isMeasuringStorage && settings.storageReport == nil {
                ZSkeleton(rows: 3)
            } else {
                ZSettingsValueRow(
                    title: "Total",
                    symbol: "internaldrive.fill",
                    subtitle: "Everything ZynSign holds, across every category."
                ) {
                    Text(settings.storageReport.map { ByteCountFormatter.string(fromByteCount: $0.total, countStyle: .file) } ?? "—")
                        .font(.headline)
                }
                ForEach(StorageCategory.allCases, id: \.self) { category in
                    let report = settings.storageReport
                    ZSettingsValueRow(
                        title: category.title,
                        symbol: category.systemImage,
                        subtitle: category.explanation
                    ) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(report.map { ByteCountFormatter.string(fromByteCount: $0.bytes(for: category), countStyle: .file) } ?? "—")
                                .font(.subheadline)
                            ZStorageUsageBar(fraction: report?.fraction(for: category) ?? 0)
                                .frame(width: 72)
                        }
                    }
                }
                if let measuredAt = settings.storageReport?.measuredAt {
                    Text("Measured \(measuredAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Space is measured as the files allocate it, so the total is the sum of the rows rather than an estimate. Cache is derived data: the system may reclaim it at any time.")
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            ZSettingsButtonRow(
                title: "Clear Temporary Files",
                subtitle: "Remove staged imports and working copies.",
                symbol: "trash",
                action: { isConfirmingTemporaryClear = true }
            )
            ZSettingsButtonRow(
                title: "Clear Cache",
                subtitle: "Remove cached application icons.",
                symbol: "trash",
                action: { isConfirmingCacheClear = true }
            )
            ZSettingsButtonRow(
                title: "Remove Old Exports",
                subtitle: "Delete signed packages older than \(settings.preferences.storage.exportRetentionDays) days.",
                symbol: "clock.arrow.circlepath",
                action: { isConfirmingExportPrune = true }
            )
            NavigationLink {
                StorageLargeFilesView()
            } label: {
                ZSettingsLabel(
                    title: "Review Large Files",
                    subtitle: "See the largest files ZynSign holds and remove any of them.",
                    symbol: "externaldrive.fill.badge.questionmark"
                )
            }
            if settings.isPerformingMaintenance {
                HStack(spacing: ZSpacing.xs) {
                    ProgressView()
                    Text("Working…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let message = settings.maintenanceMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Every action here asks first, and reports what it removed and how much it reclaimed. None of them can remove an imported application.")
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Automatic Temporary Cleanup",
                subtitle: "Let ZynSign tidy its scratch files without being asked.",
                symbol: "wand.and.stars",
                isOn: settings.binding(\.storage.automaticTemporaryCleanup)
            )
            Stepper(
                value: settings.binding(\.storage.exportRetentionDays),
                in: 1...365,
                step: 1
            ) {
                ZSettingsLabel(
                    title: "Export Retention",
                    subtitle: "How old a signed package must be before \"Remove Old Exports\" takes it.",
                    symbol: "calendar"
                )
            }
        } header: {
            Text("Preferences")
        } footer: {
            Text("Automatic cleanup follows the temporary-file policy in Advanced. Exported reports are never removed automatically.")
        }
    }

    // MARK: - Locations

    private var locationsSection: some View {
        Section {
            LabeledContent("Imported apps", value: "Application Support/ZynSignLibrary/Artifacts")
            LabeledContent("Signed packages", value: "Documents/Signed")
            LabeledContent("Scratch files", value: "System temporary")
            LabeledContent("Cache", value: "Library/Caches")
            LabeledContent("Records", value: "Application Support/ZynSignLibrary")
        } header: {
            Text("Where things live")
        } footer: {
            Text("All of it is inside ZynSign's container. Nothing is shared outside the sandbox, and nothing is uploaded.")
        }
    }
}

/// The largest files ZynSign holds.
///
/// Listing them is the point: a user who wants space back should be able to
/// see what is actually large rather than guess from a total. Removing a file
/// here removes that file and nothing else, and asks first.
private struct StorageLargeFilesView: View {

    @Environment(\.settingsCenter) private var settings
    @State private var pendingRemoval: StoredFileDescription?

    var body: some View {
        List {
            if settings.largestFiles.isEmpty {
                ContentUnavailableView {
                    Label("No Large Files", systemImage: "externaldrive.fill.badge.questionmark")
                } description: {
                    Text("Nothing ZynSign keeps is large enough to list. Measure storage again from the Storage screen to refresh this list.")
                }
            } else {
                Section {
                    ForEach(settings.largestFiles) { file in
                        HStack(spacing: ZSpacing.sm) {
                            Image(systemName: file.category.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1)
                                Text("\(file.category.title) · \(file.formattedDate)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(file.formattedByteCount)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRemoval = file
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(settings.largestFiles.count) largest")
                } footer: {
                    Text("Removing a file here removes that file. Imported applications are listed as \"Imported Apps\" — removing one is the same as removing it from the library.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Large Files")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refreshLargestFiles() }
        .alert(
            "Remove this file?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let file = pendingRemoval {
                    Task { await settings.removeStoredFile(file) }
                }
                pendingRemoval = nil
            }
        } message: {
            Text("\(pendingRemoval?.name ?? "") is \(pendingRemoval?.formattedByteCount ?? ""). It will be permanently deleted. This cannot be undone.")
        }
    }
}

#Preview {
    NavigationStack {
        StorageManagerSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: ZynSignStorageLayout.preferencesDocument()),
        environment: CompositionRoot.makeApplicationEnvironment()
    ))
}
