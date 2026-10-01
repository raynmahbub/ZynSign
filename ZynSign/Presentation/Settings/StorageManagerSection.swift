import SwiftUI

/// Storage — what ZynSign is keeping, and what it will take away.
///
/// The usage table reports allocated space per category and a total that is
/// the sum of those rows, so a number can always be traced to a location. The
/// actions remove exactly what they name and nothing else, and every
/// destructive action asks first.
///
/// The one thing this page will not do is remove an imported application.
/// Imported packages are the library, and the library has its own screen:
/// the storage use case this page acts on has no code path that can reach one.
struct StorageManagerSection: View {

    @Environment(\.settingsCenter) private var settings
    @State private var isConfirmingTemporaryClear = false
    @State private var isConfirmingExportPrune = false
    @State private var isConfirmingHistoryPrune = false

    static let descriptor = SettingsSectionDescriptor(
        identifier: .storage,
        title: "Storage",
        symbolName: "internaldrive",
        summary: "What ZynSign keeps, and how to clear it.",
        footer: "Everything here is inside ZynSign's own container. Clearing temporary files, signed artifacts, or old history records never removes an imported application."
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
            Text("Working copies, staging files, and leftovers from interrupted operations are removed. Only entries older than the retention interval are taken, and only ones ZynSign recognises as its own work. Signed artifacts and imported applications are kept.")
        }
        .alert("Remove Signed Artifacts?", isPresented: $isConfirmingExportPrune) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await settings.removeOldExports() } }
        } message: {
            Text("Every signed package ZynSign produced is deleted, together with the export records that describe it. The applications they were signed from are untouched. This cannot be undone.")
        }
        .alert("Remove Old History Records?", isPresented: $isConfirmingHistoryPrune) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await settings.removeOldHistoryRecords() } }
        } message: {
            Text("Signing-history records older than the retention interval are deleted, oldest first. The most recent records are kept whatever their age. This cannot be undone.")
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        Section {
            if settings.isMeasuringStorage && settings.storageFootprint == nil {
                ZSkeleton(rows: 3)
            } else {
                ZSettingsValueRow(
                    title: "Total",
                    symbol: "internaldrive.fill",
                    subtitle: "Everything ZynSign holds, across every category."
                ) {
                    Text(formatted(bytes: settings.storageFootprint?.totalByteCount))
                        .font(.headline)
                }
                ForEach(StorageCategory.allCases) { category in
                    let usage = settings.storageFootprint?.usage(of: category)
                    ZSettingsValueRow(
                        title: category.displayName,
                        symbol: symbol(for: category),
                        subtitle: category.explanation
                    ) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(formatted(bytes: usage?.byteCount))
                                .font(.subheadline)
                            ZStorageUsageBar(
                                fraction: fraction(of: usage?.byteCount, in: settings.storageFootprint?.totalByteCount)
                            )
                            .frame(width: 72)
                            Text(countLabel(for: usage))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Space is measured as the files allocate it, so the total is the sum of the rows rather than an estimate. Imported Apps is measured but never offered for cleanup here — removing an imported application is a Library action, one application at a time.")
        }
    }

    /// The symbol for one category.
    private func symbol(for category: StorageCategory) -> String {
        switch category {
        case .importedApplications: return "app.badge"
        case .exportedArtifacts: return "shippingbox.fill"
        case .temporaryFiles: return "clock.arrow.circlepath"
        case .history: return "list.bullet.rectangle.portrait"
        }
    }

    /// How many items a category holds, in words.
    private func countLabel(for usage: StorageCategoryUsage?) -> String {
        guard let usage else { return "—" }
        let count = usage.itemCount
        return "\(count) \(count == 1 ? "item" : "items")"
    }

    /// A category's share of the total, as a fraction in 0…1.
    private func fraction(of bytes: Int?, in total: Int?) -> Double {
        guard let bytes, let total, total > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }

    /// A byte count, formatted the way the rest of the system formats it.
    private func formatted(bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            ZSettingsButtonRow(
                title: "Clear Temporary Files",
                subtitle: "Remove working copies and leftovers from finished or interrupted operations.",
                symbol: "trash",
                action: { isConfirmingTemporaryClear = true }
            )
            ZSettingsButtonRow(
                title: "Remove Signed Artifacts",
                subtitle: "Delete every package ZynSign signed, and the export records that describe it.",
                symbol: "shippingbox",
                action: { isConfirmingExportPrune = true }
            )
            ZSettingsButtonRow(
                title: "Remove Old History Records",
                subtitle: "Delete signing-history records older than the retention interval, always keeping the most recent.",
                symbol: "list.bullet.rectangle.portrait",
                action: { isConfirmingHistoryPrune = true }
            )
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
            Text("Every action asks first, and reports what it removed and how much it reclaimed. None of them can remove an imported application.")
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
        } header: {
            Text("Preferences")
        } footer: {
            Text("Automatic cleanup follows the temporary-file policy in Advanced, which decides whether ZynSign tidies its own scratch files when it quits or when it launches. When it is off, the actions above are the only way anything is removed — which is why each one asks first.")
        }
    }

    // MARK: - Locations

    private var locationsSection: some View {
        Section {
            LabeledContent("Imported apps", value: "Application Support/ZynSignLibrary/Artifacts")
            LabeledContent("Signed packages", value: "Documents/Signed")
            LabeledContent("Scratch files", value: "System temporary")
            LabeledContent("Records", value: "Application Support/ZynSignLibrary")
        } header: {
            Text("Where things live")
        } footer: {
            Text("All of it is inside ZynSign's container. Nothing is shared outside the sandbox, and nothing is uploaded.")
        }
    }
}

#Preview {
    NavigationStack {
        StorageManagerSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.fallbackEnvironment
    ))
}
