import SwiftUI
import UniformTypeIdentifiers

/// All-in-one Dual-Mode Signing, Host Container & Wire-Free Device Hub.
///
/// Unifies ZynSign's three execution tracks in one native workshop:
/// 1. **Host Container (Zero-Slot)** — `MH_DYLIB` + `CS_ADHOC` multi-app runtime
///    with isolated per-profile data sandboxes, WebClip `.mobileconfig` export,
///    and reversible standalone `.ipa` conversion.
/// 2. **Apple ID Provisioner (Free & Paid)** — Personal Team (7-day) and Paid
///    Developer Program (365-day) certificate, UDID, App ID, and profile minting
///    directly into ZynSign's Keychain & Profile Library.
/// 3. **Wire-Free Device Bridge** — Keychain `.mobiledevicepairing` management,
///    local loopback `lockdownd` UDID probe, and `AFC` + `installation_proxy`
///    direct install / 7-day lease refresh.
struct UnifiedSigningHubView: View {

    enum HubTab: String, CaseIterable, Identifiable, Sendable {
        case container = "Container"
        case appleID = "Apple ID"
        case deviceBridge = "Bridge"

        var id: Self { self }
    }

    @Environment(\.applicationEnvironment) private var environment
    @State private var selectedTab: HubTab
    @State private var hasPaidIdentity = false
    @State private var activeFreeCount = 0

    init(initialTab: HubTab = .container) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        List {
            strategyOverviewSection
            modePickerSection
            switch selectedTab {
            case .container:
                if let host = environment.guestContainerHost {
                    HostContainerWorkshopSections(host: host)
                } else {
                    unavailableRow("Host Container service is not composed in this environment.")
                }
            case .appleID:
                if let provisioner = environment.appleAccountProvisioner {
                    AppleAccountProvisioningSections(
                        provisioner: provisioner,
                        detectedUDID: environment.deviceBridgeController?.lastConnectedDevice?.uniqueDeviceID
                    )
                } else {
                    unavailableRow("Apple Account Provisioner is not composed in this environment.")
                }
            case .deviceBridge:
                if let bridge = environment.deviceBridgeController {
                    DeviceBridgeWorkshopSections(bridge: bridge)
                } else {
                    unavailableRow("Device Bridge Controller is not composed in this environment.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Unified Signing Hub")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshOverviewFacts() }
    }

    private var strategyOverviewSection: some View {
        let hasFreeTeam = environment.appleAccountProvisioner?.selectedTeam?.isFreePersonalTeam == true
        let rec = ZynSigningStrategyAdvisor.recommend(
            hasPaidCertificate: hasPaidIdentity,
            hasFreePersonalTeam: hasFreeTeam,
            activeFreeAppCount: activeFreeCount,
            hasAppExtensions: false,
            requiresPushOrBackground: false,
            prefersUnlimitedContainerApps: selectedTab == .container && !hasPaidIdentity
        )
        return Section {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                HStack {
                    Label(rec.track.rawValue, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ZStatusBadge(rec.track.badgeLabel, kind: .info)
                }
                Text(rec.headline)
                    .font(.body.weight(.semibold))
                Text(rec.rationale)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, ZSpacing.xxs)
        } header: {
            Text("Dual-Mode Strategy Advisor")
        }
    }

    private var modePickerSection: some View {
        Section {
            Picker("Engine Mode", selection: $selectedTab) {
                ForEach(HubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func unavailableRow(_ text: String) -> some View {
        Section {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshOverviewFacts() async {
        let identities = (try? environment.identityStore.listIdentities()) ?? []
        hasPaidIdentity = !identities.isEmpty
        let records = (try? await environment.signingHistory?.allRecords()) ?? []
        let profiles = (try? await environment.provisioningProfiles?.allProfiles()) ?? []
        let leases = SideloadLedger.leases(from: records, profiles: profiles)
        let usage = SideloadLedger.usage(leases, at: Date())
        activeFreeCount = usage.first { $0.account == .personalTeam }?.installed ?? 0
    }
}

// MARK: - 1. Host Container Sections

private struct HostContainerWorkshopSections: View {
    @ObservedObject var host: GuestContainerHostService
    @State private var isImportingIPA = false
    @State private var customGuestName = ""
    @State private var newSlotName = ""
    @State private var slotTargetBundleID: String?
    @State private var exportedShareURL: URL?
    @State private var errorAlert: String?
    @State private var isStaging = false

    var body: some View {
        Section {
            TextField("Optional custom display name", text: $customGuestName)
            Button {
                isImportingIPA = true
            } label: {
                HStack {
                    Label(isStaging ? "Staging Guest Bundle…" : "Stage Decrypted .ipa into Host Container…", systemImage: "plus.square.on.square")
                    Spacer()
                    if isStaging { ProgressView() }
                }
                .frame(minHeight: 44)
            }
            .disabled(isStaging)

            if let banner = host.statusBanner {
                Label(banner, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Stage Unlimited Apps (0 Apple ID Slots)")
        } footer: {
            Text("Extracts the arm64 binary, converts MH_EXECUTE to MH_DYLIB, neutralizes __PAGEZERO, signs with CS_ADHOC, and isolates guest data under Documents/Applications/.")
        }

        Section("Hosted Container Apps (\(host.hostedGuests.count))") {
            if host.hostedGuests.isEmpty {
                Text("No apps staged yet. Stage any decrypted .ipa above to run it inside ZynSign without consuming a 3-app Free Apple ID slot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(host.hostedGuests) { guest in
                    guestCard(for: guest)
                }
            }
        }
        .sheet(isPresented: $isImportingIPA) {
            ZDocumentPicker(
                contentTypes: ImportablePackage.contentTypes,
                allowsMultipleSelection: false,
                onPick: { urls in
                    isImportingIPA = false
                    handleStageImport(.success(urls))
                },
                onCancel: { isImportingIPA = false }
            )
        }
        .sheet(item: Binding(
            get: { exportedShareURL.map { IdentifiableURL(url: $0) } },
            set: { if $0 == nil { exportedShareURL = nil } }
        )) { item in
            ShareLink(item: item.url) {
                Label("Share \(item.url.lastPathComponent)", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .padding(ZSpacing.lg)
            }
            .presentationDetents([.medium])
        }
        .alert("Container Action Failed", isPresented: Binding(
            get: { errorAlert != nil },
            set: { if !$0 { errorAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorAlert ?? "")
        }
    }

    @ViewBuilder
    private func guestCard(for guest: HostedGuestDescriptor) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(guest.displayName).font(.body.weight(.semibold))
                    Text("\(guest.bundleIdentifier) · v\(guest.shortVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZStatusBadge(
                    guest.jitlessCompatible ? "JIT-Less Ready" : "Needs JIT",
                    kind: guest.jitlessCompatible ? .success : .warning
                )
            }

            Picker("Active Data Sandbox", selection: Binding(
                get: { guest.activeSlotID },
                set: { newSlot in try? host.switchActiveSlot(for: guest.bundleIdentifier, to: newSlot) }
            )) {
                ForEach(guest.slots) { slot in
                    Text(slot.label).tag(slot.id)
                }
            }
            .pickerStyle(.menu)
            .font(.footnote)

            HStack(spacing: ZSpacing.sm) {
                Button {
                    host.requestLaunch(bundleIdentifier: guest.bundleIdentifier)
                    ZHaptics.tap()
                } label: {
                    Label("Launch", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                guestManageMenu(for: guest)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    @ViewBuilder
    private func guestManageMenu(for guest: HostedGuestDescriptor) -> some View {
        Menu {
            Button { addProfileSlot(for: guest) } label: {
                Label("New Multi-Account Data Slot", systemImage: "person.crop.circle.badge.plus")
            }
            Button { exportWebClip(for: guest) } label: {
                Label("Export Home Screen WebClip (.mobileconfig)", systemImage: "iphone.homebutton")
            }
            Button { exportDataBackup(for: guest) } label: {
                Label("Backup Active Data Slot (.zip)", systemImage: "externaldrive.badge.checkmark")
            }
            Button { convertToStandalone(for: guest) } label: {
                Label("Convert to Standalone .ipa", systemImage: "arrow.up.doc")
            }
            if guest.activeSlotID != "primary" {
                Button(role: .destructive) {
                    try? host.deleteDataSlot(for: guest.bundleIdentifier, slotID: guest.activeSlotID)
                } label: {
                    Label("Delete Active Data Slot", systemImage: "trash")
                }
            }
            Button(role: .destructive) {
                try? host.removeHostedGuest(guest.bundleIdentifier)
            } label: {
                Label("Remove Hosted App", systemImage: "xmark.bin")
            }
        } label: {
            Label("Manage", systemImage: "ellipsis.circle")
                .font(.footnote)
        }
        .buttonStyle(.bordered)
    }

    private func handleStageImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isStaging = true
        let nameOverride = customGuestName
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isStaging = false
            }
            do {
                _ = try await host.stagePackage(from: url, customDisplayName: nameOverride)
                customGuestName = ""
                ZHaptics.success()
            } catch {
                errorAlert = error.localizedDescription
            }
        }
    }

    private func addProfileSlot(for guest: HostedGuestDescriptor) {
        do {
            _ = try host.createDataSlot(
                for: guest.bundleIdentifier,
                label: "Account \(guest.slots.count + 1)"
            )
            ZHaptics.success()
        } catch {
            errorAlert = error.localizedDescription
        }
    }

    private func exportWebClip(for guest: HostedGuestDescriptor) {
        do {
            let data = try host.generateWebClipProfile(for: guest.bundleIdentifier)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(guest.bundleIdentifier)-WebClip.mobileconfig")
            try data.write(to: url, options: .atomic)
            exportedShareURL = url
        } catch {
            errorAlert = error.localizedDescription
        }
    }

    private func exportDataBackup(for guest: HostedGuestDescriptor) {
        Task {
            do {
                exportedShareURL = try await host.exportSlotDataArchive(for: guest.bundleIdentifier)
            } catch {
                errorAlert = error.localizedDescription
            }
        }
    }

    private func convertToStandalone(for guest: HostedGuestDescriptor) {
        Task {
            do {
                exportedShareURL = try await host.exportStandaloneIPA(for: guest.bundleIdentifier)
            } catch {
                errorAlert = error.localizedDescription
            }
        }
    }
}

// MARK: - 2. Apple ID (Free & Paid) Provisioning Sections

private struct AppleAccountProvisioningSections: View {
    @ObservedObject var provisioner: AppleAccountProvisioningService
    let detectedUDID: String?

    @State private var appleID = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var targetBundleID = "io.zynsign.app"
    @State private var targetAppName = "ZynSign Hosted App"
    @State private var manualUDID = ""
    @State private var assignAppGroup = false

    var body: some View {
        Section {
            TextField("HTTPS Anisette v3 Server URL", text: $provisioner.anisetteServerURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if let session = provisioner.activeSession {
                LabeledContent("Signed In", value: session.appleIDEmail)
                Button("Sign Out", role: .destructive) {
                    provisioner.signOut()
                }
            } else {
                TextField("Apple ID Email", text: $appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
                TextField("2FA Verification Code (if prompted)", text: $twoFactorCode)
                    .keyboardType(.numberPad)
                Button {
                    Task {
                        try? await provisioner.signIn(
                            appleID: appleID,
                            password: password,
                            twoFactorCode: twoFactorCode.isEmpty ? nil : twoFactorCode
                        )
                        password = ""
                    }
                } label: {
                    HStack {
                        Label(provisioner.isBusy ? "Authenticating…" : "Sign In (Free or Paid Apple ID)", systemImage: "person.badge.key")
                        Spacer()
                        if provisioner.isBusy { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(provisioner.isBusy || appleID.isEmpty || password.isEmpty)
            }
        } header: {
            Text("Apple Developer Account (Free 7-Day or Paid 365-Day)")
        } footer: {
            Text("Credentials are sent directly to Apple over HTTPS and never persisted to disk. Generated RSA-2048 keys stay non-exportable inside the iOS Keychain.")
        }

        if !provisioner.teams.isEmpty {
            teamAndProvisioningSection
        }

        if let status = provisioner.statusMessage {
            Section { Label(status, systemImage: "checkmark.seal").font(.footnote) }
        }
        if let err = provisioner.lastErrorMessage {
            Section { Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var teamAndProvisioningSection: some View {
        Section("Team & Automatic Provisioning") {
            Picker("Developer Team", selection: Binding(
                get: { provisioner.selectedTeamID ?? provisioner.teams.first?.teamID ?? "" },
                set: { provisioner.selectedTeamID = $0 }
            )) {
                ForEach(provisioner.teams) { team in
                    Text("\(team.name) (\(team.accountKind.shortLabel))").tag(team.teamID)
                }
            }
            if let team = provisioner.selectedTeam {
                LabeledContent("Account Tier", value: team.accountKind.displayName)
                LabeledContent("Portal Certs / App IDs", value: "\(provisioner.portalCertificates.count) / \(provisioner.portalAppIDs.count)")
            }
            TextField("Target Bundle Identifier", text: $targetBundleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("App Display Name", text: $targetAppName)
            TextField("Device UDID (auto-filled when paired)", text: Binding(
                get: { manualUDID.isEmpty ? (detectedUDID ?? "") : manualUDID },
                set: { manualUDID = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Toggle("Assign Shared App Group", isOn: $assignAppGroup)

            Button {
                let chosenUDID = manualUDID.isEmpty ? detectedUDID : manualUDID
                Task {
                    if (try? await provisioner.provisionSigningMaterials(
                        originalBundleID: targetBundleID,
                        appDisplayName: targetAppName,
                        deviceUDID: chosenUDID,
                        assignSharedAppGroup: assignAppGroup
                    )) != nil {
                        ZHaptics.success()
                    }
                }
            } label: {
                Label("Mint Certificate & Download Profile into ZynSign", systemImage: "wand.and.stars")
                    .frame(minHeight: 44)
            }
            .disabled(provisioner.isBusy || targetBundleID.isEmpty)
        }
    }
}

// MARK: - 3. Wire-Free Device Bridge Sections

private struct DeviceBridgeWorkshopSections: View {
    @ObservedObject var bridge: DeviceBridgeController
    @State private var isImportingPairing = false
    @State private var isPickingSignedIPA = false
    @State private var installBundleID = ""

    var body: some View {
        Section {
            TextField("Loopback / Tunnel Host", text: $bridge.tunnelHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("usbmuxd Port", text: $bridge.muxPortText)
                .keyboardType(.numberPad)
            Button {
                isImportingPairing = true
            } label: {
                Label("Import .mobiledevicepairing File…", systemImage: "lock.doc")
                    .frame(minHeight: 44)
            }
            ForEach(bridge.pairingRecords, id: \.hostIdentifier) { record in
                HStack {
                    Text(record.redactedSummary)
                        .font(ZTypography.codeCaption)
                    Spacer()
                    Button(role: .destructive) {
                        try? bridge.removePairingRecord(hostIdentifier: record.hostIdentifier)
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Delete pairing record")
                }
            }
        } header: {
            Text("Pairing Credential & Local Tunnel")
        } footer: {
            Text("Pairing records are stored exclusively in the iOS Keychain (WhenUnlockedThisDeviceOnly).")
        }

        Section("Wire-Free Session & Direct Install") {
            if let device = bridge.lastConnectedDevice {
                LabeledContent("Connected Device", value: "\(device.name) (iOS \(device.productVersion))")
                LabeledContent("UDID", value: device.uniqueDeviceID)
                    .font(ZTypography.codeCaption)
            }
            Button {
                Task { _ = try? await bridge.probeDeviceConnection() }
            } label: {
                HStack {
                    Label("Connect & Read Device UDID", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if bridge.isBusy { ProgressView() }
                }
                .frame(minHeight: 44)
            }
            .disabled(!bridge.hasPairingRecord || bridge.isBusy)

            TextField("Signed IPA Bundle Identifier", text: $installBundleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                isPickingSignedIPA = true
            } label: {
                Label("Install / Refresh Signed .ipa via installation_proxy…", systemImage: "arrow.down.app")
                    .frame(minHeight: 44)
            }
            .disabled(!bridge.hasPairingRecord || bridge.isBusy || installBundleID.isEmpty)

            if let msg = bridge.statusMessage {
                Label(msg, systemImage: "checkmark.circle").font(.footnote)
            }
            if let err = bridge.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isImportingPairing) {
            ZDocumentPicker(
                contentTypes: [
                    UTType(filenameExtension: "mobiledevicepairing") ?? .propertyList,
                    .propertyList,
                    .data,
                    .item
                ],
                allowsMultipleSelection: false,
                onPick: { urls in
                    isImportingPairing = false
                    guard let url = urls.first else { return }
                    if let data = try? Data(contentsOf: url) {
                        _ = try? bridge.importPairingFile(data: data)
                        ZHaptics.success()
                    }
                },
                onCancel: { isImportingPairing = false }
            )
        }
        .sheet(isPresented: $isPickingSignedIPA) {
            ZDocumentPicker(
                contentTypes: ImportablePackage.contentTypes,
                allowsMultipleSelection: false,
                onPick: { urls in
                    isPickingSignedIPA = false
                    guard let url = urls.first else { return }
                    let targetID = installBundleID
                    Task {
                        if let outcome = try? await bridge.installSignedPackage(at: url, bundleIdentifier: targetID),
                           outcome.isInstalled {
                            ZHaptics.success()
                        }
                    }
                },
                onCancel: { isPickingSignedIPA = false }
            )
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let id: String
    let url: URL

    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
    }
}
