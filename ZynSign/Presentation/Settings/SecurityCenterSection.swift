import SwiftUI

/// Security Center — how ZynSign guards itself, and what it shows while
/// guarded.
///
/// The center is deliberately short. It configures four things — whether Face
/// ID or Touch ID guards the application, whether sensitive actions ask
/// first, how long an unlocked session lasts, and how identifying values are
/// shown — and it states plainly what it cannot do: no setting here exposes,
/// exports, or produces private key material, because private keys are not
/// readable through any interface ZynSign has.
struct SecurityCenterSection: View {

    @Environment(\.settingsCenter) private var settings
    @Environment(\.appLock) private var appLock
    @State private var testOutcome: AuthenticationOutcome?

    static let descriptor = SettingsSectionDescriptor(
        identifier: .security,
        title: "Security",
        symbolName: "faceid",
        summary: "Face ID, sensitive actions, session timeout, and visibility.",
        footer: "Authentication is handled by the system. ZynSign learns only whether it succeeded — never a passcode, a key, or a certificate."
    )

    var body: some View {
        List {
            statusSection
            protectionSection
            sensitiveActionsSection
            visibilitySection
            guaranteeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { appLock.refreshAvailability() }
        .alert(
            "Authentication",
            isPresented: Binding(
                get: { testOutcome != nil },
                set: { if !$0 { testOutcome = nil } }
            )
        ) {
            Button("OK", role: .cancel) { testOutcome = nil }
        } message: {
            Text(testOutcome?.message ?? "")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(
                    appLock.availability.statusText,
                    systemImage: appLock.availability.isAvailable ? "faceid" : "lock.slash",
                    kind: appLock.availability.isAvailable ? .success : .neutral
                )
                ZStatusBadge(
                    appLock.isLocked ? "Locked" : "Unlocked",
                    systemImage: appLock.isLocked ? "lock.fill" : "lock.open.fill",
                    kind: appLock.isLocked ? .warning : .neutral
                )
                ZStatusBadge(
                    appLock.isProtectionEnabled ? "Protection on" : "Protection off",
                    systemImage: "shield",
                    kind: appLock.isProtectionEnabled ? .info : .neutral
                )
            }
            if !appLock.availability.isAvailable {
                Text(appLock.availability.unavailableReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("ZynSign asks for Face ID or Touch ID through the system. The answer comes back as yes or no; nothing about the attempt is stored anywhere.")
        }
    }

    // MARK: - Protection

    private var protectionSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Face ID / Touch ID Protection",
                subtitle: "Lock ZynSign when it opens or returns from the background.",
                symbol: "faceid",
                isOn: settings.binding(\.security.biometricLockEnabled)
            )
            .disabled(!appLock.availability.isAvailable)

            ZSettingsPickerRow(
                title: "Secure Session Timeout",
                symbol: "timer",
                subtitle: "How long ZynSign stays unlocked while you are not using it.",
                selection: settings.binding(\.security.sessionTimeout)
            ) {
                ForEach(SessionTimeout.allCases, id: \.self) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            .disabled(!settings.preferences.security.biometricLockEnabled)

            ZSettingsButtonRow(
                title: "Lock Now",
                subtitle: "Lock ZynSign immediately.",
                symbol: "lock.fill",
                isDestructive: true,
                action: { appLock.lock() }
            )
            .disabled(!appLock.isProtectionEnabled || appLock.isLocked)

            ZSettingsButtonRow(
                title: "Test Authentication",
                subtitle: "Check that Face ID or Touch ID works here.",
                symbol: "checkmark.shield",
                action: testAuthentication
            )
        } header: {
            Text("Protection")
        } footer: {
            Text("Protection takes effect the next time ZynSign is backgrounded or the session lapses — never in the middle of what you are doing.")
        }
    }

    // MARK: - Sensitive actions

    private var sensitiveActionsSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Require Authentication Before Sensitive Actions",
                subtitle: "Ask before signing, resetting, clearing, or exporting.",
                symbol: "hand.raised",
                isOn: settings.binding(\.security.requireAuthenticationForSensitiveActions)
            )
            ForEach(SensitiveAction.allCases, id: \.rawValue) { action in
                Label(action.title, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 4, trailing: 16))
            }
        } header: {
            Text("Sensitive Actions")
        } footer: {
            Text("With this off, a locked ZynSign still asks — the lock is the stronger protection. With it on, these actions ask even while ZynSign is unlocked.")
        }
    }

    // MARK: - Visibility

    private var visibilitySection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Hide Sensitive Information When Locked",
                subtitle: "Mask certificate and profile details while ZynSign is locked.",
                symbol: "eye.slash",
                isOn: settings.binding(\.security.hideSensitiveInformationWhenLocked)
            )

            ZSettingsPickerRow(
                title: "Sensitive-Data Visibility",
                symbol: "eye",
                subtitle: "How certificate fingerprints and profile details are shown.",
                selection: settings.binding(\.security.sensitiveDataVisibility)
            ) {
                ForEach(SensitiveDataVisibility.allCases, id: \.self) { visibility in
                    Text(visibility.displayName).tag(visibility)
                }
            }

            ZSettingsValueRow(
                title: "Preview",
                symbol: "rectangle.and.text.magnifyingglass",
                subtitle: "How an identifying value is shown right now."
            ) {
                SensitiveValueText(value: "a1b2c3d4e5f6")
            }
        } header: {
            Text("Visibility")
        } footer: {
            Text("\"Hidden\" removes the value entirely; \"masked\" shows it only while ZynSign is unlocked. Private key material is never shown in any case — it is not readable through ZynSign at all.")
        }
    }

    // MARK: - Guarantee

    private var guaranteeSection: some View {
        Section {
            Label("Private keys stay in the Keychain, marked non-extractable.", systemImage: "checkmark.shield")
            Label("No setting here exports, copies, or reveals key material.", systemImage: "checkmark.shield")
            Label("Authentication is the system's; ZynSign receives only the answer.", systemImage: "checkmark.shield")
        } header: {
            Text("What this page cannot do")
        } footer: {
            Text("Signing identities are managed in the Certificates tab. This page controls how ZynSign guards itself, never what it can reach.")
        }
    }

    // MARK: - Actions

    private func testAuthentication() {
        Task {
            let outcome = await appLock.authenticate(action: .changeSecuritySettings)
            testOutcome = outcome
        }
    }
}

#Preview {
    NavigationStack {
        SecurityCenterSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.makeApplicationEnvironment()
    ))
    .environment(\.appLock, AppLockController(
        authenticator: LocalAuthenticationBiometricAuthenticator(),
        preferences: { ZynSignPreferences.shippedDefault }
    ))
}
