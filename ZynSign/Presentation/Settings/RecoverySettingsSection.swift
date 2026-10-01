import SwiftUI

/// Settings entry for Backup & Recovery and the existing reset tools.
/// Backup and restore use a separate guided flow; the reset controls retain
/// their explicit confirmations and sensitive-action authorization.
struct RecoverySettingsSection: View {

    @Environment(\.settingsCenter) private var settings
    @Environment(\.appLock) private var appLock
    @State private var pendingReset: RecoveryActionKind?

    static let descriptor = SettingsSectionDescriptor(
        identifier: .recovery,
        title: "Recovery Center",
        symbolName: "externaldrive.badge.timemachine",
        summary: "Encrypted backups, selective restore, and workspace recovery.",
        footer: "Restore replaces only selected categories after a preview. Reset Library is destructive and asks before deleting imported applications.",
        isDestructive: true
    )

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RecoveryCenterView()
                } label: {
                    Label("Open Backup & Recovery", systemImage: "lock.shield")
                }
            } header: { Text("Backup & Recovery") } footer: {
                Text("Backups are encrypted with your passphrase. Keys and provisioning profiles are never exported.")
            }
            safeSection
            destructiveSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pendingReset?.title ?? "",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingReset = nil }
            Button(pendingReset?.confirmTitle ?? "Continue", role: .destructive) {
                if let action = pendingReset { perform(action) }
                pendingReset = nil
            }
        } message: {
            Text(pendingReset?.confirmationMessage ?? "")
        }
    }

    // MARK: - Safe recovery

    private var safeSection: some View {
        Section {
            ZSettingsButtonRow(
                title: "Reset Preferences",
                subtitle: "Restore every setting to its shipped default.",
                symbol: "arrow.counterclockwise",
                action: { pendingReset = .preferences }
            )
            ZSettingsButtonRow(
                title: "Clean Temporary Workspace",
                subtitle: "Remove working copies and leftovers from interrupted operations.",
                symbol: "clock.arrow.circlepath",
                action: { pendingReset = .workspace }
            )
            ZSettingsButtonRow(
                title: "Rebuild Library Index",
                subtitle: "Re-read the library and clear artifacts no record refers to.",
                symbol: "arrow.triangle.2.circlepath",
                action: { pendingReset = .libraryIndex }
            )
        } header: {
            Text("Safe Recovery")
        } footer: {
            Text("None of these removes an imported application, a certificate, or a provisioning profile. Resetting preferences keeps the record of finished onboarding — showing the welcome card again is its own action in General.")
        }
    }

    // MARK: - Destructive reset

    private var destructiveSection: some View {
        Section {
            ZSettingsButtonRow(
                title: "Reset Library",
                subtitle: "Remove every imported application and its package file.",
                symbol: "trash.fill",
                isDestructive: true,
                action: { pendingReset = .library }
            )
        } header: {
            Text("Destructive")
        } footer: {
            Text("This is the only action in ZynSign that deletes your imported applications. Certificates and provisioning profiles are not affected — remove those in their own tabs.")
        }
    }

    // MARK: - Actions

    private func perform(_ kind: RecoveryActionKind) {
        Task {
            // Authentication is asked for only when the user asked for it;
            // `authorize` returns immediately otherwise, and a locked ZynSign
            // is unlocked by the same attempt.
            if let action = SensitiveAction.forRecovery(kind) {
                let outcome = await appLock.authorize(action)
                guard outcome.isAuthenticated else { return }
            }
            await run(kind)
        }
    }

    @MainActor
    private func run(_ kind: RecoveryActionKind) async {
        switch kind {
        case .preferences:
            settings.resetPreferences()
        case .workspace:
            await settings.clearTemporaryFiles()
        case .libraryIndex:
            await settings.rebuildLibraryIndex()
        case .library:
            await settings.resetLibrary()
        }
    }
}

private extension RecoveryActionKind {

    var title: String {
        switch self {
        case .preferences: return "Reset Preferences?"
        case .workspace: return "Clean Temporary Workspace?"
        case .libraryIndex: return "Rebuild Library Index?"
        case .library: return "Reset Library?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .preferences: return "Reset"
        case .workspace: return "Clean"
        case .libraryIndex: return "Rebuild"
        case .library: return "Reset"
        }
    }

}

#Preview {
    NavigationStack {
        RecoverySettingsSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.fallbackEnvironment
    ))
    .environment(\.appLock, AppLockController(
        authenticator: LocalAuthenticationBiometricAuthenticator(),
        preferences: { ZynSignPreferences.shippedDefault }
    ))
}
