import SwiftUI

/// Advanced — the options for people who want to know what ZynSign is doing.
///
/// This section is deliberately separated from everyday settings and says so
/// at the top. Everything in it is reversible, nothing in it can lose an
/// imported application, and nothing in it is a feature that does not exist:
/// where a later version will offer more, the row says so rather than
/// pretending.
struct AdvancedSettingsSection: View {

    @Environment(\.settingsCenter) private var settings

    static let descriptor = SettingsSectionDescriptor(
        identifier: .advanced,
        title: "Advanced",
        symbolName: "slider.horizontal.3",
        summary: "Working directory, cleanup policy, and verification strictness.",
        footer: "Advanced settings change how ZynSign works internally. Every one of them is reversible, and none of them can remove an imported application.",
        isAdvanced: true
    )

    var body: some View {
        List {
            ZSettingsBanner(
                title: "These settings change how ZynSign works",
                message: "Leave them alone unless you know what they do. Everything here is reversible, and nothing here touches your imported applications.",
                kind: .warning
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            workingDirectorySection
            cleanupSection
            verificationSection
            if ReleaseTrain.isAvailable(.performanceDashboard) {
                performanceSection
            }
            experimentalSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Working directory

    private var workingDirectorySection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Working Directory",
                symbol: "folder",
                subtitle: "Where ZynSign stages work in progress.",
                selection: settings.binding(\.advanced.workingDirectoryBehavior)
            ) {
                ForEach(WorkingDirectoryBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            ZSettingsValueRow(
                title: "Current Location",
                symbol: "externaldrive",
                subtitle: "Where ZynSign is staging right now."
            ) {
                Text(
                    CompositionRoot.importStagingDirectory(preferences: settings.preferences).path
                )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("Working Directory")
        } footer: {
            Text("The system temporary directory is reclaimable and cleared by the cleanup policy; a workspace under Application Support survives longer and is yours to clean. Changes take effect the next time ZynSign launches.")
        }
    }

    // MARK: - Cleanup

    private var cleanupSection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Temporary-File Cleanup",
                symbol: "trash",
                subtitle: "When ZynSign clears its scratch files.",
                selection: settings.binding(\.advanced.temporaryCleanupPolicy)
            ) {
                ForEach(TemporaryCleanupPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("\"Only when I ask\" disables automatic cleanup entirely; Storage → Clear Temporary Files still works. Cleanup never touches imported applications, signed packages, or exported reports.")
        }
    }

    // MARK: - Verification

    private var verificationSection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Verification Strictness",
                symbol: "checkmark.shield",
                subtitle: "How strictly ZynSign reads its own results.",
                selection: settings.binding(\.advanced.verificationStrictness)
            ) {
                ForEach(VerificationStrictness.allCases, id: \.self) { strictness in
                    Text(strictness.displayName).tag(strictness)
                }
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Standard reports every finding and leaves the decision to you. Strict additionally asks for confirmation before signing when the compatibility assessment carries any finding — including informational ones. Strict never refuses to sign; it only makes you confirm.")
        }
    }

    // MARK: - Performance

    /// The hidden Performance page. Listed only when the release exposes
    /// it; the page itself says so when the engine is not composed.
    private var performanceSection: some View {
        Section {
            NavigationLink {
                PerformanceDashboardSection(
                    model: PerformanceDashboardModel(
                        engine: settings.environment.performanceEngine,
                        benchmarkSuite: { CompositionRoot.makePerformanceBenchmarks(environment: settings.environment) }
                    )
                )
            } label: {
                ZSettingsLabel(
                    title: "Performance",
                    subtitle: "Library index, caches, memory, and benchmarks.",
                    symbol: "gauge.with.dots.needle.33percent"
                )
            }
            .accessibilityHint("Opens the Performance page")
        } header: {
            Text("Performance")
        } footer: {
            Text("What the Performance Engine is doing: how many applications are indexed, what the caches hold, and how fast the library, search, import, signing preparation, and store loading are on this device.")
        }
    }

    // MARK: - Experimental

    /// Experimental features, listed honestly.
    ///
    /// A flag appears here only once the feature behind it is implemented and
    /// reachable, because this list is the only place the interface looks for
    /// something to offer. There are none today, so the section says exactly
    /// that instead of showing switches that do nothing.
    private var experimentalSection: some View {
        Section {
            ZSettingsValueRow(
                title: "Experimental Features",
                symbol: "flag",
                subtitle: "Implemented features that are not on by default."
            ) {
                Text("None available")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Experimental")
        } footer: {
            Text("Nothing in this build is waiting behind a flag: an experimental feature appears here only once it works and can be switched off again. When one does, it will be listed with a description of exactly what it changes.")
        }
    }
}

#Preview {
    NavigationStack {
        AdvancedSettingsSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.makeApplicationEnvironment()
    ))
}
