import SwiftUI
import UIKit

/// The certificate inspector: everything ZynSign knows about one signing
/// identity, with the actions the center offers.
///
/// The inspector reads the identity live from the model's snapshot by
/// fingerprint, so a removal made elsewhere takes the screen to its "no
/// longer available" state rather than showing a ghost. It shows only
/// metadata the certificate itself declares — name, team, issuer,
/// validity, algorithm, key size, purpose, fingerprint — and the health
/// checks computed from those facts. It never displays, and never could
/// display, private key material: none of the stores it reads carry it.
struct IdentityCertificateInspectorView: View {

    @ObservedObject var model: IdentityCenterModel
    let fingerprint: String

    @Environment(\.appLock) private var appLock
    @State private var showRemoveConfirmation = false

    private var certificate: IdentityCenterCertificate? {
        model.loadedSnapshot?.certificate(fingerprintHex: fingerprint)
    }

    var body: some View {
        Group {
            if let certificate {
                details(certificate)
            } else {
                ContentUnavailableView {
                    Label("No Longer Available", systemImage: "questionmark.circle")
                } description: {
                    Text("This identity is no longer registered. Go back to see your identities.")
                }
            }
        }
        .navigationTitle(certificate?.displayName ?? "Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if let certificate { actions(certificate) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Certificate actions")
            }
        }
        .confirmationDialog(
            "Remove this registration?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Registration", role: .destructive) {
                Task { await remove() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ZynSign forgets the registration. The certificate and its key are not deleted, and nothing leaves the Keychain.")
        }
    }

    @ViewBuilder
    private func actions(_ certificate: IdentityCenterCertificate) -> some View {
        Button {
            Task { await model.setDefault(certificate) }
        } label: {
            Label("Set Default", systemImage: "star")
        }
        Button {
            Task { await model.refreshValidation() }
        } label: {
            Label("Refresh Validation", systemImage: "arrow.clockwise")
        }
        if let teamID = certificate.facts.teamID {
            Button {
                UIPasteboard.general.string = teamID
            } label: {
                Label("Copy Team ID", systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func remove() async {
        guard let certificate else { return }
        let outcome = await appLock.authorize(.removeIdentity)
        guard outcome.isAuthenticated else { return }
        await model.remove(certificate)
    }

    @ViewBuilder
    private func details(_ certificate: IdentityCenterCertificate) -> some View {
        List {
            Section("Identity") {
                LabeledContent("Name", value: certificate.displayName)
                LabeledContent("Common Name", value: certificate.facts.displayName)
                if let organization = certificate.identity.certificate.subject.organization {
                    LabeledContent("Organization", value: organization)
                }
                LabeledContent("Team ID", value: certificate.facts.teamID ?? "Not declared")
                if let teamName = certificate.facts.teamName {
                    LabeledContent("Team Name", value: teamName)
                }
                LabeledContent("Purpose", value: certificate.facts.kind.displayName)
                LabeledContent(
                    "Key",
                    value: keyDescription(certificate)
                )
            }

            Section("Validity") {
                LabeledContent(
                    "Valid From",
                    value: certificate.identity.certificate.notValidBefore.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent(
                    "Expires",
                    value: certificate.identity.certificate.notValidAfter.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent("Issuer", value: certificate.identity.certificate.issuer.displayName)
                LabeledContent(
                    "Algorithm",
                    value: certificate.identity.certificate.signatureAlgorithm.displayName
                )
                if let keySize = certificate.identity.certificate.publicKeyInfo.keySizeInBits {
                    LabeledContent("Key Size", value: "\(keySize) bits")
                }
                if let curve = certificate.identity.certificate.publicKeyInfo.curveName {
                    LabeledContent("Curve", value: curve)
                }
                LabeledContent("Fingerprint (SHA-256)", value: certificate.facts.fingerprintHex)
                    .textSelection(.enabled)
            }

            Section {
                ForEach(certificate.health.checks) { check in
                    IdentityCheckRow(check: check)
                }
            } header: {
                HStack(spacing: ZSpacing.xs) {
                    IdentityHealthDot(status: certificate.health.status)
                    Text("Health — \(certificate.health.status.displayName)")
                }
            } footer: {
                Text(certificate.health.spokenSummary)
            }

            Section("Signing Relationships") {
                LabeledContent(
                    "Linked Profiles",
                    value: certificate.linkedProfileIDs.isEmpty
                        ? "None"
                        : "\(certificate.linkedProfileIDs.count)"
                )
                LabeledContent(
                    "Compatible Apps",
                    value: certificate.compatibleApps.isEmpty
                        ? "None"
                        : "\(certificate.compatibleApps.count)"
                )
                LabeledContent("Default Identity", value: isDefault ? "Yes" : "No")
                LabeledContent(
                    "Imported",
                    value: certificate.facts.importedAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Before records began"
                )
            }
        }
    }

    private var isDefault: Bool {
        certificate?.facts.isDefault == true
    }

    private func keyDescription(_ certificate: IdentityCenterCertificate) -> String {
        switch certificate.identity.keyAvailability {
        case .available: return "Available (Keychain)"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }
}

/// The profile inspector: the profile's declarations, its status badge,
/// its health checks, and the actions the center offers.
struct IdentityProfileInspectorView: View {

    @ObservedObject var model: IdentityCenterModel
    let profileID: ProvisioningProfileIdentifier

    @Environment(\.appLock) private var appLock
    @State private var showRemoveConfirmation = false

    private var profile: IdentityCenterProfile? {
        model.loadedSnapshot?.profile(id: profileID)
    }

    var body: some View {
        Group {
            if let profile {
                details(profile)
            } else {
                ContentUnavailableView {
                    Label("No Longer Available", systemImage: "questionmark.circle")
                } description: {
                    Text("This profile is no longer stored. Go back to see your identities.")
                }
            }
        }
        .navigationTitle(profile?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if let profile { actions(profile) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Profile actions")
            }
        }
        .confirmationDialog(
            "Remove this profile?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Profile", role: .destructive) {
                Task { await remove() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ZynSign removes the profile from its library. The original file outside ZynSign is not touched.")
        }
    }

    @ViewBuilder
    private func actions(_ profile: IdentityCenterProfile) -> some View {
        Button {
            Task { await model.refreshValidation() }
        } label: {
            Label("Refresh Validation", systemImage: "arrow.clockwise")
        }
        if let teamID = profile.facts.teamID {
            Button {
                UIPasteboard.general.string = teamID
            } label: {
                Label("Copy Team ID", systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func remove() async {
        guard let profile else { return }
        let outcome = await appLock.authorize(.removeIdentity)
        guard outcome.isAuthenticated else { return }
        await model.removeProfile(profile)
    }

    @ViewBuilder
    private func details(_ profile: IdentityCenterProfile) -> some View {
        List {
            Section("Profile") {
                LabeledContent("Name", value: profile.displayName)
                LabeledContent("Type", value: profile.summary.resolvedProfileType.displayName)
                LabeledContent("Team", value: profile.facts.teamID ?? "Not declared")
                if let teamName = profile.facts.teamName {
                    LabeledContent("Team Name", value: teamName)
                }
                LabeledContent(
                    "Bundle Identifier",
                    value: profile.facts.bundleIdentifier
                        ?? profile.summary.bundleIdentifierPatterns.joined(separator: ", ")
                )
                LabeledContent(
                    "Expires",
                    value: profile.facts.expirationDate.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent("Status", value: profile.status.displayName)
            }

            Section("Facts") {
                LabeledContent(
                    "Created",
                    value: profile.summary.creationDate.map {
                        $0.formatted(date: .abbreviated, time: .omitted)
                    } ?? "Not declared"
                )
                LabeledContent(
                    "Imported",
                    value: profile.facts.importedAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Unknown"
                )
                LabeledContent(
                    "Devices",
                    value: profile.summary.deviceCountDescription ?? "Not declared"
                )
                LabeledContent("Debug Allowed", value: profile.facts.allowsDebug ? "Yes" : "No")
                LabeledContent(
                    "Entitlement Keys",
                    value: profile.summary.entitlementsKeys.isEmpty
                        ? "None"
                        : "\(profile.summary.entitlementsKeys.count)"
                )
                LabeledContent(
                    "Linked Certificates",
                    value: profile.linkedCertificateFingerprints.isEmpty
                        ? "None on this device"
                        : "\(profile.linkedCertificateFingerprints.count)"
                )
            }

            Section {
                ForEach(profile.health.checks) { check in
                    IdentityCheckRow(check: check)
                }
            } header: {
                HStack(spacing: ZSpacing.xs) {
                    IdentityHealthDot(status: profile.health.status)
                    Text("Health — \(profile.health.status.displayName)")
                }
            } footer: {
                Text(profile.health.spokenSummary)
            }

            Section("Compatible Apps") {
                if profile.compatibleApps.isEmpty {
                    Text("No application in the library matches this profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profile.compatibleApps, id: \.bundleIdentifier) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                                .font(.subheadline)
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// The sheet listing one certificate's linked profiles.
struct LinkedProfilesSheet: View {

    let certificate: IdentityCenterCertificate
    let snapshot: IdentityCenterSnapshot?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let snapshot {
                    let profiles = snapshot.profiles.filter {
                        certificate.linkedProfileIDs.contains($0.facts.id)
                    }
                    if profiles.isEmpty {
                        ContentUnavailableView(
                            "No Linked Profiles",
                            systemImage: "link.badge.plus",
                            description: Text("No stored profile embeds this certificate or declares its team.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(profiles) { profile in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text("\(profile.summary.resolvedProfileType.displayName) · expires \(profile.facts.expirationDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Linked Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The sheet listing the library applications an identity can sign.
struct CompatibleAppsSheet: View {

    let title: String
    let apps: [CompatibleApp]
    let subjectName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if apps.isEmpty {
                    ContentUnavailableView(
                        "No Compatible Apps",
                        systemImage: "apps.iphone",
                        description: Text("No application in the library matches \(subjectName).")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(apps, id: \.bundleIdentifier) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                                .font(.subheadline)
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
