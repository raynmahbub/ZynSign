import SwiftUI

/// Signing — the defaults a signing session starts from.
///
/// Every value here is a starting point, not a rule: the signing screen
/// presents it, and the user may choose something else for that session. The
/// section names signing material by reference only — a certificate by its
/// public SHA-256 fingerprint, a profile by the name the profile declares
/// about itself — so nothing here holds, reads, or can produce a private key.
struct SigningPreferencesSection: View {

    @Environment(\.settingsCenter) private var settings
    @Environment(\.applicationEnvironment) private var environment
    @State private var identities: [SigningIdentity] = []
    @State private var profiles: [ProvisioningProfileSummary] = []
    @State private var isLoading = true

    static let descriptor = SettingsSectionDescriptor(
        identifier: .signing,
        title: "Signing",
        symbolName: "signature",
        summary: "Default identity, profile, and compatibility analysis.",
        footer: "These are the starting points for your next signing session. The signing screen always lets you choose something else for that session. Signed packages are written inside ZynSign's own container and delivered from the signing screen itself."
    )

    var body: some View {
        List {
            identitySection
            profileSection
            sessionSection
            analysisSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            if isLoading {
                ZSkeleton(rows: 1)
            } else if identities.isEmpty {
                ZSettingsValueRow(
                    title: "Preferred Signing Identity",
                    symbol: "signature",
                    subtitle: "No identities are available yet."
                ) {
                    Text("None").foregroundStyle(.secondary)
                }
            } else {
                ZSettingsPickerRow(
                    title: "Preferred Signing Identity",
                    symbol: "signature",
                    subtitle: "The identity a signing session starts with.",
                    selection: settings.binding(\.signing.preferredIdentityFingerprint)
                ) {
                    Text("Ask each time").tag(nil as String?)
                    ForEach(identities, id: \.id) { identity in
                        Text(identity.displayName).tag(Optional(identity.fingerprint.hexDigest))
                    }
                }
            }
            if let missing = unavailableIdentityNote {
                Label(missing, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("An identity is its certificate paired with the private key in the Keychain. ZynSign records the certificate's public fingerprint so it can recognise the identity again — the private key itself is never read, exported, or shown.")
        }
    }

    /// Whether the recorded identity is no longer among the available ones —
    /// a removed or replaced certificate — and should be offered for clearing.
    private var unavailableIdentityNote: String? {
        guard let fingerprint = settings.preferences.signing.preferredIdentityFingerprint else { return nil }
        guard !identities.contains(where: { $0.fingerprint.hexDigest == fingerprint }) else { return nil }
        return "The identity you chose is no longer available. Choose another, or leave it as \"Ask each time\"."
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            if isLoading {
                ZSkeleton(rows: 1)
            } else if profiles.isEmpty {
                ZSettingsValueRow(
                    title: "Preferred Provisioning Profile",
                    symbol: "person.text.rectangle",
                    subtitle: "No profiles have been imported yet."
                ) {
                    Text("None").foregroundStyle(.secondary)
                }
            } else {
                ZSettingsPickerRow(
                    title: "Preferred Provisioning Profile",
                    symbol: "person.text.rectangle",
                    subtitle: "The profile a signing session starts with.",
                    selection: settings.binding(\.signing.preferredProfileName)
                ) {
                    Text("Ask each time").tag(nil as String?)
                    ForEach(profiles, id: \.name) { profile in
                        Text(profile.name).tag(Optional(profile.name))
                    }
                }
            }
        } header: {
            Text("Provisioning Profile")
        } footer: {
            Text("Profiles are named by the name the profile declares about itself. Import and remove them in Certificates & Profiles → Profiles.")
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Remember Previous Selections",
                subtitle: "Keep the identity and profile you last signed with as the next starting point.",
                symbol: "clock.arrow.circlepath",
                isOn: settings.binding(\.signing.rememberSelections)
            )
        } header: {
            Text("Sessions")
        } footer: {
            Text("With this on, signing with an identity and profile makes them the starting point for next time. With it off, the choices above are used every time.")
        }
    }

    // MARK: - Compatibility analysis

    private var analysisSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Automatic Compatibility Analysis",
                subtitle: "Assess an identity, profile, and application before signing.",
                symbol: "stethoscope",
                isOn: settings.binding(\.signing.automaticCompatibilityAnalysis)
            )
        } header: {
            Text("Compatibility")
        } footer: {
            Text("The assessment predicts whether a combination is likely to succeed and explains why, without running the pipeline. It never blocks signing: it is advice, not a gate.")
        }
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        identities = (try? environment.identityStore.listIdentities()) ?? []
        profiles = (try? await environment.provisioningProfiles?.allProfiles()) ?? []
    }
}

#Preview {
    NavigationStack {
        SigningPreferencesSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.fallbackEnvironment
    ))
}
