import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Signing screen — local diagnostics, authenticated claims and Live Activities.
struct SigningView: View {
    let entry: LibraryEntry
    @Environment(\.applicationEnvironment) private var env
    @State private var identities: [SigningIdentity] = []
    @State private var selectedIdentityID: SigningIdentityIdentifier?
    @State private var isLoadingIdentities = true
    @State private var identitiesError: String?
    @State private var profileData: Data?
    @State private var profileFileName: String?
    @State private var profileError: String?
    @State private var savedProfiles: [ProvisioningProfileSummary] = []
    @State private var savedProfilesError: String?
    @State private var isLoadingSavedProfiles = true
    @State private var selectedSavedProfileID: ProvisioningProfileIdentifier?
    @State private var isLoadingProfile = false
    @State private var profileSelectionGeneration = 0
    @State private var savedProfileListGeneration = 0
    @State private var showProfileImporter = false
    @State private var isSigning = false
    @State private var signingResult: SignApplicationResult?
    @State private var signingError: String?
    @State private var outputURL: URL?
    @State private var showShare = false
    @State private var shareItem: ShareURL?
    @State private var showSigningOptions = false
    @State private var showSuccessToast = false
    @State private var showErrorToast = false
    @State private var emitDEREntitlements = false
    @State private var health: SigningDiagnosticsAnalysis?
    @State private var analyzedFor: SigningScanKey?
    @State private var isAnalyzing = true
    @State private var analysisError: String?
    @State private var profileRevision = 0
    @State private var identityRevision = 0
    @State private var scanRevision = 0
    @StateObject private var liveActivity = LiveActivityService()
    @Environment(\.scenePhase) private var scenePhase

    /// Changing a picker or the actual per-run option cancels the old SwiftUI
    /// task; an old result can never enable signing for a new configuration.
    private struct SigningScanKey: Hashable {
        let recordID: ApplicationRecordIdentifier
        let identityID: SigningIdentityIdentifier?
        let profileRevision: Int
        let storedProfileID: ProvisioningProfileIdentifier?
        let identityRevision: Int
        let scanRevision: Int
        let isLoading: Bool
        let emitDER: Bool
    }

    private var scanKey: SigningScanKey {
        SigningScanKey(recordID: entry.record.id, identityID: selectedIdentityID,
                       profileRevision: profileRevision, storedProfileID: selectedSavedProfileID,
                       identityRevision: identityRevision, scanRevision: scanRevision,
                       isLoading: isLoadingIdentities || isLoadingProfile,
                       emitDER: emitDEREntitlements)
    }

    private var selectedIdentity: SigningIdentity? {
        guard let id = selectedIdentityID else { return nil }
        return identities.first { $0.id == id }
    }
    private var canSign: Bool {
        !isSigning && !isAnalyzing && !scanKey.isLoading && analyzedFor == scanKey &&
        selectedIdentityID != nil && profileData != nil && entry.isArtifactAvailable &&
        health?.entitlements != nil && health?.report.status != .blocked
    }

    var body: some View {
        List {
            appSection
            diagnosticsSection
            identitySection
            profileSection
            entitlementsSection
            actionSection
            signingStatusSection
            if let result = signingResult { resultSection(result) }
            if let error = signingError, signingResult == nil {
                Section { HStack(spacing: ZSpacing.xs) { ZStatusBadge(error, systemImage: "exclamationmark.triangle", kind: .error) } } header: { Text("Signing Result") }
            }
            helpSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sign \(entry.record.displayName ?? "Application")")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIdentities() }
        .task { await loadSavedProfiles() }
        .task(id: scanKey) {
            guard !scanKey.isLoading else { return }
            await analyzeHealth()
        }
        .task {
            // Re-evaluate dates and short-lived archive evidence while the
            // screen is visible; an unchanged picker is not a perpetual pass.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                guard !Task.isCancelled else { break }
                scanRevision += 1
            }
        }
        .refreshable { await loadIdentities(); await loadSavedProfiles(); scanRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .zynsignSigningIdentityChanged)) { _ in
            Task { await loadIdentities() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zynsignProvisioningProfilesChanged)) { _ in
            Task { await loadSavedProfiles() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadIdentities(); await loadSavedProfiles(); scanRevision += 1 }
            }
        }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in handleProfilePicker(result) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .alert("Signing Failed", isPresented: Binding(get: { signingError != nil }, set: { if !$0 { signingError = nil } })) { Button("OK", role: .cancel) { signingError = nil } } message: { Text(signingError ?? "") }
        .zToast(isPresented: $showSuccessToast, message: "Signed — ready in Documents/Signed", style: .success)
        .zToast(isPresented: $showErrorToast, message: signingError ?? "Refused — working copy discarded", style: .error, duration: .seconds(4))
        .zBottomSheet(isPresented: $showSigningOptions) {
            NavigationStack { SigningOptionsView(emitDEREntitlements: $emitDEREntitlements).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSigningOptions = false } } } }
        }
        .onChange(of: signingResult) { _, new in
            if new?.status == .signed { ZHaptics.success(); withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showSuccessToast = true } }
            else if new?.failure != nil { ZHaptics.warning(); withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showErrorToast = true } }
        }
    }

    private var appSection: some View {
        Section("Application") {
            LabeledContent("Name", value: entry.record.displayName ?? "Unnamed Application")
            LabeledContent("Identifier", value: entry.record.bundleIdentifier.rawValue)
            LabeledContent("Version", value: entry.record.identity.shortVersionString ?? "—")
            LabeledContent("Build", value: entry.record.identity.buildVersion ?? "—")
            LabeledContent("Package", value: entry.artifactAvailability.displayName).foregroundStyle(entry.isArtifactAvailable ? .primary : .orange)
            if !entry.isArtifactAvailable { Label("The package file is not available. Re-import the application before signing.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            NavigationLink { BundleExplorerView(inspection: env.bundleInspection, entry: entry) } label: { Label("Explore Bundle", systemImage: "folder") }.disabled(!entry.isArtifactAvailable)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            SigningHealthCard(report: analyzedFor == scanKey ? health?.report : nil,
                              isAnalyzing: isAnalyzing || scanKey.isLoading, error: analysisError)
                .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md,
                                          bottom: ZSpacing.sm, trailing: ZSpacing.md))
                .listRowBackground(Color.clear)
            if let health, analyzedFor == scanKey {
                NavigationLink {
                    SigningDiagnosticsView(report: health.report, history: health.history,
                                           changes: health.changes,
                                           historyUnavailable: health.historyUnavailable)
                } label: { Label("View issues, recommendations & history", systemImage: "doc.text.magnifyingglass") }
            }
            if analysisError != nil {
                Button("Try analysis again") { scanRevision += 1 }
            }
        } header: { Text("Pre-Sign Diagnostics") } footer: {
            Text("The compatibility summary updates as you choose an identity, profile or signing option. These checks never change the IPA; the pipeline checks again when signing begins.")
        }
    }

    private var identitySection: some View {
        Section {
            if isLoadingIdentities { ZSkeleton(rows: 2) }
            else if let err = identitiesError { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Button("Retry") { Task { await loadIdentities() } } }
            else if identities.isEmpty {
                ContentUnavailableView { Label("No Certificates", systemImage: "signature") } description: { Text("Import a .p12 identity in the Certificates tab to sign.") } actions: { NavigationLink { CertificatesView() } label: { Label("Open Certificates", systemImage: "key.fill") }.buttonStyle(.bordered) }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } else {
                Picker("Signing Identity", selection: $selectedIdentityID) {
                    Text("Select Identity").tag(nil as SigningIdentityIdentifier?)
                    ForEach(identities, id: \.id) { idt in VStack(alignment: .leading) { Text(idt.displayName); Text(idt.certificate.subject.displayName).font(.caption).foregroundStyle(.secondary) }.tag(Optional(idt.id)) }
                }.pickerStyle(.navigationLink).disabled(isSigning)
                if let idt = selectedIdentity {
                    LabeledContent("Key", value: idt.keyAvailability.rawValue)
                    LabeledContent("Association", value: String(describing: idt.association))
                    LabeledContent("Capability", value: String(describing: idt.capabilityState))
                    HStack { if idt.isUsableForSigning { ZStatusBadge("Key metadata ready", systemImage: "key.fill", kind: .success) } else { ZStatusBadge.needsAttention("Not usable") }; Spacer() }
                    if idt.isUsableForSigning { Text("The last Keychain observation found a matching capability; availability and the full configuration are checked again before signing.").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Usable only when key is available, certificate ↔ key match, and capability is ready. Re-import the correct .p12 or check validity.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: { Text("Signing Identity") } footer: { Text("Private keys never leave the Keychain and are never displayed. The pipeline verifies key association and protection on every operation.") }
    }

    private var profileSection: some View {
        Section {
            if isLoadingProfile {
                ProgressView("Reading saved profile…")
                    .accessibilityLabel("Reading saved provisioning profile")
            }
            if let name = profileFileName, let data = profileData {
                LabeledContent("Profile", value: name)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                Button("Remove Profile", role: .destructive) { clearProfileSelection() }
                    .disabled(isSigning)
            } else if !isLoadingProfile {
                Text("Choose a profile that authorizes this app and the selected certificate. ZynSign verifies the exact bytes; saved-profile summaries are not signing evidence.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = profileError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.footnote)
            }
            if !savedProfiles.isEmpty {
                Menu {
                    ForEach(savedProfiles) { summary in
                        Button {
                            chooseSavedProfile(summary)
                        } label: {
                            Label(summary.name, systemImage: selectedSavedProfileID == summary.id ? "checkmark.circle.fill" : "doc.text")
                        }
                    }
                } label: { Label("Choose Saved Profile…", systemImage: "tray.full") }
                    .disabled(isSigning)
                Text("The saved file is read within the CMS size limit and reverified for this app, identity and signing option. A saved summary alone never enables signing.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isLoadingSavedProfiles {
                ProgressView("Loading saved profiles…")
            } else if let error = savedProfilesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                Button("Retry saved profiles") { Task { await loadSavedProfiles() } }
                    .disabled(isSigning)
            }
            Button { showProfileImporter = true } label: {
                Label("Choose from Files…", systemImage: "doc.badge.ellipsis")
            }.disabled(isSigning)
        } header: { Text("Provisioning Profile") }
    }

    private var entitlementsSection: some View {
        Section {
            if profileData == nil {
                LabeledContent("Entitlements", value: "Choose a profile first")
                Text("Only claims from an authenticated profile will be prepared for signing.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let claims = health?.entitlements, analyzedFor == scanKey {
                LabeledContent("Verified profile claims", value: "\(claims.count) keys")
                if !claims.isEmpty {
                    ForEach(claims.keys.prefix(8), id: \.self) { key in
                        Text(key).font(.caption.monospaced()).lineLimit(2)
                    }
                    if claims.count > 8 {
                        Text("+ \(claims.count - 8) more claims are checked and used; none are dropped.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("These exact claims are compared with the authenticated profile and passed to the signing pipeline. iOS authorization is not established by this check.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Entitlements", value: isAnalyzing ? "Analyzing…" : "Not verified")
                Text("If the profile cannot be authenticated or its claims cannot be represented, signing will not substitute an empty set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $emitDEREntitlements) {
                Label("Request DER entitlements (unsupported)", systemImage: "doc.text.image")
            }.tint(.blue).disabled(isSigning)
            ZStatusBadge(emitDEREntitlements ? "DER not available" : "XML only",
                         systemImage: "cpu", kind: emitDEREntitlements ? .neutral : .warning)
            Text(emitDEREntitlements
                 ? "The current signer does not emit DER. Diagnostics blocks this option rather than producing an XML-only signature labeled as DER."
                 : "Only XML entitlements are emitted. If iOS 15+ requires DER for your target, use a signer with verified DER support.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if liveActivity.isActive, let state = liveActivity.currentState {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge(state.stage, systemImage: "livephoto", kind: .info)
                    ZStatusBadge("\(Int(state.progress * 100))%", systemImage: "percent", kind: .neutral)
                }
                Text(state.detail).font(.caption2).foregroundStyle(.secondary)
            }
            NavigationLink { SigningOptionsView(emitDEREntitlements: $emitDEREntitlements) } label: {
                Label("Signing Options", systemImage: "slider.horizontal.3")
            }.disabled(isSigning)
            Button { ZHaptics.tap(); showSigningOptions = true } label: {
                Label("Quick Options (Sheet)", systemImage: "rectangle.bottomthird.inset.filled")
            }.foregroundStyle(.secondary).disabled(isSigning)
        } header: { Text("Entitlements & Options") }
    }

    private var actionSection: some View {
        Section {
            Button { Task { await sign() } } label: {
                HStack { Spacer(); if isSigning { ProgressView().tint(.white); Text("Signing…").foregroundStyle(.white) } else { Text("Sign Application").fontWeight(.semibold) }; Spacer() }
            }
            .listRowBackground(canSign ? Color.accentColor : Color.gray.opacity(0.3)).foregroundStyle(canSign ? .white : .secondary).disabled(!canSign)
            if !canSign && entry.isArtifactAvailable { Text(whyDisabled).font(.caption).foregroundStyle(.secondary) }
        } footer: { Text("The nine-stage pipeline runs: integrity, profile, discovery, extraction, nested signing, resource sealing, main-executable signing, packaging, verification. Any refusal ends the run and delivers nothing.") }
    }

    private var signingStatusSection: some View {
        Group {
            if isSigning {
                Section {
                    ZCard(variant: .material, cornerRadius: ZRadius.lg) {
                        VStack(spacing: ZSpacing.sm) {
                            HStack(spacing: ZSpacing.md) {
                                ZProgressRing(status: "Signing")
                                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                    Text("Smart Sign in progress").font(.headline)
                                    Text("Running integrity → profile → discovery → extraction → sealing → signing → packaging → verification").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: ZSpacing.xs) { ZStatusBadge("Signing", systemImage: "hammer.fill", kind: .info); ZStatusBadge("9 stages", systemImage: "list.number", kind: .neutral); }
                                    if liveActivity.isActive { ZStatusBadge("Live Activity", systemImage: "livephoto", kind: .success) }
                                }
                                Spacer()
                            }
                            ZSigningStatusMachine(current: .signing)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md)).listRowBackground(Color.clear)
                } header: { Text("Signing Status") }
            } else if let result = signingResult {
                Section {
                    ZCard(variant: result.status == .signed ? .filled : .outlined, cornerRadius: ZRadius.lg) {
                        VStack(spacing: ZSpacing.sm) {
                            HStack(spacing: ZSpacing.md) {
                                ZProgressRing(progress: result.status == .signed ? 1.0 : 0, status: result.status == .signed ? "Completed" : "Refused", tint: result.status == .signed ? .green : .red)
                                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                    Text(result.status == .signed ? "Completed" : "Refused at \(result.failure?.stage.rawValue ?? "—")").font(.headline).foregroundStyle(result.status == .signed ? .green : .red)
                                    Text(result.status == .signed ? "Signed container verified and ready in Documents/Signed." : result.failure?.detail ?? "No container delivered — working copy discarded.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: ZSpacing.xs) {
                                        if result.status == .signed { ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success); if let c = result.stages?.discovery.nestedItemCount { ZStatusBadge("\(c) nested", systemImage: "internaldrive", kind: .neutral) }; }
                                        else { ZStatusBadge("Refused", systemImage: "xmark.shield.fill", kind: .error); if let cat = result.failure?.category { ZStatusBadge(String(describing: cat), kind: .neutral) } }
                                    }
                                }
                                Spacer()
                            }
                            ZSigningStatusMachine(current: ZSigningStatusMachine.Step.from(result: result), failed: result.status != .signed)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md)).listRowBackground(Color.clear)
                } header: { Text("Signing Status") }
            }
        }
    }

    private var whyDisabled: String {
        if isSigning { return "A signing run is already in progress." }
        if selectedIdentityID == nil { return "Select a signing identity." }
        if profileData == nil { return "Choose a provisioning profile." }
        if isAnalyzing || analyzedFor != scanKey { return "Checking this configuration before signing…" }
        if health?.report.status == .blocked { return "Resolve the blocked checks in Signing Diagnostics before signing." }
        if health?.entitlements == nil { return "The profile's authenticated entitlements are not available." }
        return analysisError ?? "Resolve the requirements above to sign."
    }

    private func resultSection(_ result: SignApplicationResult) -> some View {
        Group {
            if result.status == .signed, let url = result.outputURL ?? outputURL {
                Section("Signed Application") {
                    HStack(spacing: ZSpacing.xs) { ZStatusBadge("Signed successfully", systemImage: "checkmark.seal.fill", kind: .success); Spacer() }
                    LabeledContent("Output", value: url.lastPathComponent)
                    if let stages = result.stages {
                        LabeledContent("Nested Targets", value: "\(stages.discovery.nestedItemCount)")
                        LabeledContent("Sealed Files", value: "\(stages.sealing.sealedFileCount)")
                        LabeledContent("Signature", value: ByteCountFormatter.string(fromByteCount: Int64(stages.mainExecutable.signatureByteCount), countStyle: .file))
                    }
                    Button { shareItem = ShareURL(url: url) } label: { Label("Share Signed IPA…", systemImage: "square.and.arrow.up") }
                    Button { shareItem = ShareURL(url: url) } label: { Label("Open in Files", systemImage: "folder") }
                    if ReleaseTrain.isAvailable(.deliveryHandoff) {
                        NavigationLink {
                            InstallationDeliveryView(package: InstallationDeliveryPackage(signedIPA: url, record: entry.record))
                        } label: {
                            Label("Deliver…", systemImage: "tray.and.arrow.up")
                        }
                    }
                    Text("The signed container is in Documents/Signed. It is the exact artifact the pipeline produced and independently verified — not a trust or installability claim.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let failure = result.failure {
                Section("Signing Refused") {
                    HStack(spacing: ZSpacing.xs) { ZStatusBadge("Refused at \(failure.stage.rawValue)", systemImage: "xmark.shield.fill", kind: .error); Spacer() }
                    Text(failure.detail).font(.footnote).foregroundStyle(.secondary)
                    ZStatusBadge(String(describing: failure.category), kind: .neutral)
                    Text("Nothing was delivered; the working copy was discarded.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var helpSection: some View {
        Section("About Signing") {
            Text("Signing appends a code signature and does not replace existing signatures — inputs must be unsigned. Nested frameworks are signed without their own resource seals; the main seal references them by cdhash. Symbolic links are recorded as seal omissions.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @MainActor private func loadIdentities() async {
        isLoadingIdentities = true
        defer {
            isLoadingIdentities = false
            identityRevision += 1
        }
        do {
            identities = try env.identityStore.listIdentities()
            identitiesError = nil
            if let selectedIdentityID, !identities.contains(where: { $0.id == selectedIdentityID }) {
                self.selectedIdentityID = nil
            }
            if selectedIdentityID == nil,
               let first = identities.first(where: { $0.isUsableForSigning }) ?? identities.first {
                selectedIdentityID = first.id
            }
        } catch let error as ZynSignError {
            identitiesError = error.userMessage
            identities = []
            selectedIdentityID = nil
        } catch {
            identitiesError = "Secure identity storage could not be accessed."
            identities = []
            selectedIdentityID = nil
        }
    }

    @MainActor private func clearProfileSelection() {
        profileSelectionGeneration += 1 // invalidate any in-flight saved-file read
        selectedSavedProfileID = nil
        profileData = nil
        profileFileName = nil
        profileError = nil
        isLoadingProfile = false
        profileRevision += 1
    }

    @MainActor private func chooseSavedProfile(_ summary: ProvisioningProfileSummary) {
        guard !isSigning else { return }
        profileSelectionGeneration += 1
        let generation = profileSelectionGeneration
        selectedSavedProfileID = summary.id
        profileData = nil // the summary itself grants no signing authority
        profileFileName = summary.name
        profileError = nil
        isLoadingProfile = true
        profileRevision += 1
        Task { await readSavedProfile(summary, generation: generation) }
    }

    @MainActor private func readSavedProfile(
        _ summary: ProvisioningProfileSummary, generation: Int
    ) async {
        do {
            let data = try await env.provisioningProfiles?.profileBytes(withID: summary.id)
            guard generation == profileSelectionGeneration,
                  selectedSavedProfileID == summary.id else { return }
            if let data {
                profileData = data
                profileFileName = summary.name
                profileError = nil
            } else {
                profileData = nil
                profileFileName = nil
                profileError = "The saved file is no longer available. Re-import it or choose another profile."
            }
        } catch {
            guard generation == profileSelectionGeneration,
                  selectedSavedProfileID == summary.id else { return }
            profileData = nil
            profileFileName = nil
            profileError = "The saved profile could not be read within the inspection limit. Re-import it or choose another profile."
        }
        isLoadingProfile = false
        profileRevision += 1
    }

    @MainActor private func loadSavedProfiles() async {
        savedProfileListGeneration += 1
        let generation = savedProfileListGeneration
        guard let library = env.provisioningProfiles else {
            savedProfiles = []
            savedProfilesError = "Saved profiles are not available in this build."
            isLoadingSavedProfiles = false
            if selectedSavedProfileID != nil { clearProfileSelection() }
            return
        }
        isLoadingSavedProfiles = true
        defer {
            if generation == savedProfileListGeneration { isLoadingSavedProfiles = false }
        }
        do {
            let summaries = try await library.allProfiles()
            guard !Task.isCancelled, generation == savedProfileListGeneration else { return }
            savedProfiles = summaries
            savedProfilesError = nil
            if let id = selectedSavedProfileID, !isSigning {
                if let selected = summaries.first(where: { $0.id == id }) {
                    // Refresh exact bytes when the app becomes active, a
                    // profile changes, or the list is pulled to refresh.
                    chooseSavedProfile(selected)
                } else {
                    clearProfileSelection()
                    profileError = "That saved profile was removed. Choose another profile."
                }
            }
        } catch {
            guard !Task.isCancelled, generation == savedProfileListGeneration else { return }
            savedProfiles = []
            savedProfilesError = "Saved profiles could not be loaded."
            if selectedSavedProfileID != nil {
                clearProfileSelection()
                profileError = "The saved profile library is unavailable. Re-open it and try again."
            }
        }
    }

    @MainActor private func analyzeHealth() async {
        guard let diagnostics = env.signingDiagnostics else {
            isAnalyzing = false
            analysisError = "Signing diagnostics are unavailable in this build."
            return
        }
        let requestedKey = scanKey
        let profile = profileData
        let identity = selectedIdentityID
        isAnalyzing = true
        health = nil
        analyzedFor = nil
        analysisError = nil
        do {
            let result = try await diagnostics.analyze(
                recordWithID: entry.record.id, identityID: identity,
                profileData: profile, emitDEREntitlements: requestedKey.emitDER
            )
            guard !Task.isCancelled, requestedKey == scanKey else { return }
            health = result
            analyzedFor = requestedKey
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requestedKey == scanKey else { return }
            analysisError = (error as? SigningDiagnosticsError)?.userMessage
                ?? "This configuration could not be analyzed. Please try again."
        }
        isAnalyzing = false
    }

    @MainActor private func handleProfilePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Clear the old choice before reading a new one. A failed pick
            // must never leave a previous profile's green checks enabled.
            clearProfileSelection()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "mobileprovision" || ext == "provisionprofile" else {
                profileError = "Choose a .mobileprovision file."
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                // Bound the read BEFORE allocating profile data, at the same
                // limit the CMS pipeline enforces. No full-file fallback.
                let bytes = try handle.read(upToCount: ProvisioningProfileInput.maximumByteCount + 1) ?? Data()
                guard !bytes.isEmpty, bytes.count <= ProvisioningProfileInput.maximumByteCount else {
                    profileError = "The profile is empty or exceeds the inspection limit."
                    return
                }
                profileData = bytes
                profileFileName = url.lastPathComponent
                profileError = nil
                profileRevision += 1
            } catch {
                profileError = "The selected profile could not be read."
            }
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            profileError = "The file picker could not provide the selected profile."
        }
    }

    @MainActor private func sign() async {
        guard canSign, let identityID = selectedIdentityID,
              let profile = profileData, let diagnostics = env.signingDiagnostics else {
            signingError = "Resolve the current signing diagnostics before signing."
            return
        }
        let requestedKey = scanKey
        let savedID = selectedSavedProfileID
        isSigning = true
        signingResult = nil; signingError = nil; outputURL = nil
        if let savedID {
            // A stored file can change or disappear after a screen scan.
            // Re-read the bounded file before preflight and require the
            // displayed, authenticated byte snapshot to still be current.
            do {
                guard let current = try await env.provisioningProfiles?.profileBytes(withID: savedID) else {
                    clearProfileSelection()
                    profileError = "That saved profile is no longer available."
                    signingError = "Choose a current profile and review its diagnostics."
                    isSigning = false
                    return
                }
                guard requestedKey == scanKey else {
                    signingError = "Signing inputs changed. Review the updated diagnostics."
                    isSigning = false
                    return
                }
                guard current == profile else {
                    profileData = current
                    profileRevision += 1
                    signingError = "The saved profile changed. Review the new diagnostics before signing."
                    isSigning = false
                    return
                }
            } catch {
                profileData = nil
                profileRevision += 1
                profileError = "The saved profile could not be read. Re-import it or choose another."
                signingError = "The saved profile is unavailable. Review the new diagnostics."
                isSigning = false
                return
            }
        }
        // Bypass the short-lived archive cache just before a mutation. Do
        // not rely on a previously displayed score or an old profile claim.
        let preflight: SigningDiagnosticsAnalysis
        do {
            preflight = try await diagnostics.analyze(
                recordWithID: entry.record.id, identityID: identityID,
                profileData: profile, emitDEREntitlements: requestedKey.emitDER,
                force: true
            )
        } catch {
            signingError = "The pre-sign verification could not complete. Re-run diagnostics."
            isSigning = false
            return
        }
        guard requestedKey == scanKey, preflight.report.status != .blocked,
              let entitlements = preflight.entitlements else {
            health = preflight
            analyzedFor = requestedKey == scanKey ? requestedKey : nil
            signingError = "Signing is blocked by the updated diagnostics. Review the issues before trying again."
            isSigning = false
            return
        }
        health = preflight
        analyzedFor = requestedKey
        guard entry.isArtifactAvailable else {
            signingError = "The package file is not available."
            isSigning = false
            return
        }
        let sourceURL = env.artifactFileURL(for: entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            signingError = "The package file could not be found in ZynSign's storage."
            isSigning = false
            return
        }
        await liveActivity.start(stage: "Signing", detail: "Integrity → Profile → Discovery…")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let signedDir = docs.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: signedDir, withIntermediateDirectories: true)
        // A package's display name is untrusted metadata; it must never
        // choose an output path or overwrite another signed container.
        let output = signedDir.appendingPathComponent("\(entry.record.id.rawValue)-\(UUID().uuidString).ipa")
        let options = SignApplicationOptions(emitDEREntitlements: requestedKey.emitDER)
        let request = SignApplicationRequest(sourceURL: sourceURL, profile: profile, identityID: identityID, entitlements: entitlements, outputURL: output, options: options)
        do {
            await liveActivity.update(progress: 0.2, detail: "Discovery → Extraction…")
            let result = try await env.signingPipeline.sign(request)
            await liveActivity.update(progress: 0.9, detail: result.status == .signed ? "Verified" : "Refused")
            signingResult = result
            if result.status == .signed {
                outputURL = result.outputURL ?? output
                await liveActivity.end(success: true)
                env.recordAnalyticsEvent(category: .signing, name: "sign.succeeded", succeeded: true)
            } else if let failure = result.failure {
                signingError = "\(failure.stage.rawValue): \(failure.detail)"
                await liveActivity.end(success: false)
                env.recordAnalyticsEvent(category: .signing, name: "sign.refused", succeeded: false)
            } else {
                signingError = "Signing failed without a typed refusal."
                await liveActivity.end(success: false)
                env.recordAnalyticsEvent(category: .signing, name: "sign.refused", succeeded: false)
            }
        } catch is CancellationError { signingError = "Signing was cancelled."; try? FileManager.default.removeItem(at: output); await liveActivity.end(success: false); env.recordAnalyticsEvent(category: .signing, name: "sign.cancelled", succeeded: false) }
        catch let e as ZynSignError { signingError = e.userMessage; try? FileManager.default.removeItem(at: output); await liveActivity.end(success: false); env.recordAnalyticsEvent(category: .signing, name: "sign.failed", succeeded: false) }
        catch { signingError = "Signing failed unexpectedly."; try? FileManager.default.removeItem(at: output); await liveActivity.end(success: false); env.recordAnalyticsEvent(category: .signing, name: "sign.failed", succeeded: false) }
        isSigning = false
    }
}

private struct ShareURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ ui: UIActivityViewController, context: Context) {}
}
