import SwiftUI
import UniformTypeIdentifiers

/// Hub for experimental guest staging, account provisioning and pairing
/// record management. Device transport is blocked until authenticated and
/// verified; guest loading is not evidence of complete app execution.
struct UnifiedSigningHubView: View {

    enum HubTab: String, CaseIterable, Identifiable, Sendable {
        case container = "Container"
        case appleID = "Apple ID"
        case deviceBridge = "Bridge"

        var id: Self { self }
    }

    @Environment(\.applicationEnvironment) private var environment
    @State private var selectedTab: HubTab

    init(initialTab: HubTab = .container) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        List {
            Section("Capability status") {
                Text("Guest execution is experimental. Device installation is blocked until authenticated transport is verified. Account and profile restrictions vary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
}

// MARK: - 1. Host Container Sections

private struct HostContainerWorkshopSections: View {
    private enum PendingDeletion {
        case guest(bundleID: String, name: String)
        case slot(bundleID: String, slotID: String, name: String)
    }

    @ObservedObject var host: GuestContainerHostService
    @State private var pendingDeletion: PendingDeletion?
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
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Experimental Guest Staging")
        } footer: {
            Text("Stages and modifies a guest bundle for inspection. Data directories do not establish sandbox isolation. Probing loads code into this process and may execute initializers; it does not prove an app can run.")
        }

        Section("Hosted Container Apps (\(host.hostedGuests.count))") {
            if host.hostedGuests.isEmpty {
                Text("No guests staged yet. Compatibility, execution and isolation are not guaranteed.")
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
        .confirmationDialog("Permanently delete data?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { deletion in
            Button("Delete", role: .destructive) { performDeletion(deletion) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { deletion in
            switch deletion {
            case .guest(_, let name):
                Text("Remove \(name) and all of its stored profiles? This cannot be undone.")
            case .slot(_, _, let name):
                Text("Delete the data in profile \(name)? This cannot be undone.")
            }
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
                    guest.requiresJIT ? "JIT requested" : "Compatibility unverified",
                    kind: .warning
                )
            }

            Picker("Active Data Sandbox", selection: Binding(
                get: { guest.activeSlotID },
                set: { newSlot in
                    do { try host.switchActiveSlot(for: guest.bundleIdentifier, to: newSlot) }
                    catch { errorAlert = error.localizedDescription }
                }
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
                    Label("Probe Executable", systemImage: "play.fill")
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
                    pendingDeletion = .slot(bundleID: guest.bundleIdentifier, slotID: guest.activeSlotID, name: guest.activeSlot.label)
                } label: {
                    Label("Delete Active Data Slot", systemImage: "trash")
                }
            }
            Button(role: .destructive) {
                pendingDeletion = .guest(bundleID: guest.bundleIdentifier, name: guest.displayName)
            } label: {
                Label("Remove Hosted App", systemImage: "xmark.bin")
            }
        } label: {
            Label("Manage", systemImage: "ellipsis.circle")
                .font(.footnote)
        }
        .buttonStyle(.bordered)
    }

    private func performDeletion(_ deletion: PendingDeletion) {
        pendingDeletion = nil
        do {
            switch deletion {
            case .guest(let bundleID, _):
                try host.removeHostedGuest(bundleID)
            case .slot(let bundleID, let slotID, _):
                try host.deleteDataSlot(for: bundleID, slotID: slotID)
            }
        } catch {
            errorAlert = error.localizedDescription
        }
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

        Section("Device Session & Direct Install") {
            if !bridge.isTransportComposed {
                Text("Unavailable: authenticated device transport and framed reads require implementation and device verification.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
            .disabled(!bridge.isTransportComposed || !bridge.hasPairingRecord || bridge.isBusy)

            TextField("Signed IPA Bundle Identifier", text: $installBundleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                isPickingSignedIPA = true
            } label: {
                Label("Install / Refresh Signed .ipa via installation_proxy…", systemImage: "arrow.down.app")
                    .frame(minHeight: 44)
            }
            .disabled(!bridge.isTransportComposed || !bridge.hasPairingRecord || bridge.isBusy || installBundleID.isEmpty)

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
