import SwiftUI

/// The sideloading area: what this build can do, what it still needs, and the
/// edits the next signing run may apply.
///
/// The screen is deliberately a report before it is a control. Every row about
/// a capability names the requirement it is missing — a pairing record, the
/// local-tunnel entitlement, a bundled loader — because "unavailable" without
/// a reason is the one thing a sideloading tool must never show.
struct SideloadingView: View {
    /// Settings and other hosts push this screen; the shell owns the stack.
    var embedsNavigationStack: Bool = true

    @State private var options = SideloadSigningOptions.none
    @State private var injectedPath = "@executable_path/Frameworks/Tweak.dylib"

    /// The build's own signature, read once at composition. This screen used to
    /// write `buildCarriesLocalTunnelEntitlement: false` here, which is a fact
    /// about the App Store build and a guess about every other one.
    @Environment(\.applicationEnvironment) private var environment

    private var processEntitlements: ProcessEntitlements {
        environment.processEntitlements
    }

    private var evidence: SideloadingCapability.Evidence {
        let hasPairing = environment.deviceBridgeController?.hasPairingRecord ?? false
        let transportComposed = environment.deviceBridgeController?.isTransportComposed ?? false
        let loaderBundled = environment.guestContainerHost?.isBundledLoaderAvailable ?? false
        return processEntitlements.sideloadingEvidence(
            hasPairingRecord: hasPairing,
            transportComposed: transportComposed,
            loaderBundled: loaderBundled
        )
    }

    private var assessments: [SideloadingCapability.Assessment] {
        SideloadingCapability.all(evidence: evidence)
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
            Section {
                NavigationLink {
                    UnifiedSigningHubView()
                } label: {
                    Label("Open Unified Signing & Container Hub", systemImage: "cpu")
                }
            } footer: {
                Text("Stage zero-slot Host Container apps, provision Free 7-day or Paid 365-day Apple Developer certificates, and install or refresh over the wire-free device bridge.")
            }
            capabilitySection
            connectionSection
            optionsSection
            containerSection
            truthSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sideloading")
    }

    // MARK: - Capabilities

    private var capabilitySection: some View {
        Section {
            ForEach(assessments, id: \.capability) { assessment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: assessment.capability))
                            .foregroundStyle(assessment.isSupported ? Color.green : Color.secondary)
                            .frame(width: 24)
                        Text(assessment.capability.title)
                            .font(.body.weight(.medium))
                        Spacer(minLength: 8)
                        ZStatusBadge(
                            assessment.label,
                            kind: assessment.isSupported ? .success : .unsupported
                        )
                    }
                    Text(assessment.capability.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(assessment.unmetRequirements, id: \.self) { requirement in
                        Label(requirement.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Missing requirement: \(requirement.message)")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Capabilities")
        } footer: {
            Text("A requirement is a fact about this build or this device, not a setting. "
                 + "Importing a pairing record satisfies the first one; the entitlement "
                 + "requirements are read from the signature that signed this copy of "
                 + "ZynSign, so an entitled build lights these rows up on its own.")
        }
    }

    private func symbol(for capability: SideloadingCapability) -> String {
        switch capability {
        case .devicePairing: return "link.badge.plus"
        case .deviceSession: return "lock.open.laptopcomputer"
        case .packageInstallation: return "arrow.down.app"
        case .guestContainer: return "square.stack.3d.up"
        case .libraryInjection: return "syringe"
        case .adHocSigning: return "signature"
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        let recordCount = environment.deviceBridgeController?.pairingRecords.count ?? 0
        let transportLabel = (environment.deviceBridgeController?.isTransportComposed == true)
            ? "Composed (usbmuxd over NWConnection)"
            : "Not composed"
        let pairingLabel = recordCount == 0 ? "None" : "\(recordCount) stored in Keychain"
        return Section {
            LabeledContent("This build's signature", value: measurementLabel)
            LabeledContent("Local-tunnel entitlement", value: localTunnelLabel)
            LabeledContent("Device transport", value: transportLabel)
            LabeledContent("Pairing records", value: pairingLabel)
            Text(processEntitlements.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Device")
        } footer: {
            Text(SideloadingTruth.installationEvidenceRule)
        }
    }

    /// What was measured, in the plainest words available: a read signature, a
    /// signature with nothing readable in it, or no read at all.
    private var measurementLabel: String {
        guard processEntitlements.isMeasured else { return "Not established" }
        return processEntitlements.teamIdentifier.map { "Measured · team \($0)" } ?? "Measured"
    }

    private var localTunnelLabel: String {
        switch processEntitlements.carriesLocalTunnelEntitlement {
        case true: return "Granted"
        case false: return "Absent"
        case .none: return "Not established"
        }
    }

    // MARK: - Signing options

    private var optionsSection: some View {
        Section {
            TextField("Bundle identifier", text: Binding(
                get: { options.bundleIdentifier ?? "" },
                set: { options.bundleIdentifier = $0.isEmpty ? nil : $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Display name", text: Binding(
                get: { options.displayName ?? "" },
                set: { options.displayName = $0.isEmpty ? nil : $0 }))
            TextField("Version", text: Binding(
                get: { options.shortVersion ?? "" },
                set: { options.shortVersion = $0.isEmpty ? nil : $0 }))
                .keyboardType(.numbersAndPunctuation)

            Toggle("Remove app extensions and plug-ins", isOn: $options.removesPlugIns)
            Toggle("Remove watchOS apps", isOn: $options.removesWatchApps)
            Toggle("Remove URL schemes", isOn: $options.removesURLSchemes)
            Toggle("Ad-hoc signature (no certificate)", isOn: $options.adHoc)

            TextField("Install name to inject", text: $injectedPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                toggleInjection()
            } label: {
                Label(options.injectedLibraries.isEmpty ? "Add library" : "Remove library",
                      systemImage: options.injectedLibraries.isEmpty ? "plus.circle" : "minus.circle")
            }
            .disabled(options.injectedLibraries.isEmpty
                      && !SideloadSigningOptions.isInstallName(injectedPath))

            if let error = validationError {
                Label(error.message, systemImage: "exclamationmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Label(planSummary, systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Package edits")
        } footer: {
            Text("These edits are applied inside the signing working copy, before any binary "
                 + "is signed, so the CodeDirectory covers them. An image without header "
                 + "padding is refused rather than half-edited. To apply them, open an app in "
                 + "the library and use Signing → Package Edits; that screen carries the same "
                 + "form into the run that signs.")
        }
    }

    private var validationError: SideloadOptionError? {
        do {
            try options.validate(hasCertificate: !options.adHoc)
            return nil
        } catch let error as SideloadOptionError {
            return error
        } catch {
            return nil
        }
    }

    private var planSummary: String {
        let plan = InfoPlistOverrides.mainApplicationPlan(options)
        var parts: [String] = []
        if !plan.values.isEmpty { parts.append("\(plan.values.count) plist value(s)") }
        if !plan.keysToRemove.isEmpty { parts.append("removes \(plan.keysToRemove.count) key(s)") }
        if !options.injectedLibraries.isEmpty {
            parts.append("injects \(options.injectedLibraries.count)")
        }
        if options.adHoc { parts.append("ad-hoc") }
        return parts.isEmpty ? "No edits; the package signs as it is." : parts.joined(separator: " · ")
    }

    private func toggleInjection() {
        if options.injectedLibraries.isEmpty {
            options.injectedLibraries = [InjectedLibrary(installName: injectedPath)]
        } else {
            options.injectedLibraries = []
        }
    }

    // MARK: - Containers

    private var containerSection: some View {
        let firstHosted = environment.guestContainerHost?.hostedGuests.first
        let assessment = firstHosted.flatMap { environment.guestContainerHost?.assessGuest($0.bundleIdentifier) }
            ?? GuestContainer.assess(.init(
                bundleIdentifier: "io.zynsign.guest.preview",
                name: "Unstaged guest template",
                version: "1.0",
                executableName: "Guest",
                loaderBundled: environment.guestContainerHost?.isBundledLoaderAvailable ?? false
            ))
        return Section {
            if let host = environment.guestContainerHost {
                LabeledContent("Hosted container apps", value: "\(host.hostedGuests.count)")
            }
            Text(assessment.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(assessment.spokenSummary)
            ForEach(GuestContainer.launchPlan(for: assessment), id: \.title) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.subheadline.weight(.medium))
                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    Text("Needs: \(step.requirement.message)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Guest container")
        } footer: {
            Text(SideloadingTruth.containerEvidenceRule)
        }
    }

    // MARK: - Truth

    private var truthSection: some View {
        Section("What stays true") {
            ForEach(SideloadingTruth.statements, id: \.self) { statement in
                Text(statement)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SideloadingView(embedsNavigationStack: false)
    }
}
