import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Signing screen — Smart Sign, executed by the Signing Engine.
///
/// The screen collects the three things a run needs — an identity, a
/// provisioning profile, and the entitlement set the profile authorizes — and
/// hands them to the engine, which owns the order of the run, its safety
/// properties, and its progress. What the screen shows is the engine's own
/// state: the ten stages with their live detail, an estimate once one is
/// meaningful, the delivered container on success, and — on a refusal — the
/// refusing stage, its reason, and the recovery facts.
///
/// Every value rendered here is text the engine produced. Nothing on this
/// screen is a trust, authorization, or installability claim about the result.
/// Read-only Signing Health checks the selected inputs before the engine starts.
@MainActor
struct SigningView: View {
    let entry: LibraryEntry
    @StateObject private var studio: EntitlementsStudioModel

    init(entry: LibraryEntry, studio: EntitlementsStudioModel? = nil) {
        self.entry = entry
        _studio = StateObject(wrappedValue: studio ?? EntitlementsStudioModel())
    }
    @Environment(\.applicationEnvironment) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsCenter) private var settings
    @Environment(\.appLock) private var appLock
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @State private var showQueuedToast = false
    @State private var isQueueing = false
    @StateObject private var model = SigningEngineModel()
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
    @State private var shareItem: ShareURL?
    @State private var showSigningOptions = false
    @State private var showSuccessToast = false
    @State private var showErrorToast = false
    @State private var emitDEREntitlements = false
    @State private var health: SigningDiagnosticsAnalysis?
    @State private var analyzedFor: SigningScanKey?
    @State private var isAnalyzing = true
    @State private var analysisError: String?
    @State private var preflightError: String?
    @State private var isPreparingToSign = false
    /// Whether the strict-verification confirmation is showing.
    @State private var isConfirmingStrictSign = false
    /// Whether the user has already answered that confirmation for the
    /// current selection, so confirming signs rather than asking again.
    @State private var isSigningConfirmed = false
    @State private var preflightTask: Task<Void, Never>?
    @State private var profileRevision = 0
    @State private var identityRevision = 0
    @State private var scanRevision = 0
    @State private var successScale: CGFloat = 1
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

    private var isSigning: Bool { model.isRunning }
    private var selectedIdentity: SigningIdentity? {
        guard let id = selectedIdentityID else { return nil }
        return identities.first { $0.id == id }
    }
    private var canSign: Bool {
        guard !isSigning, !isPreparingToSign, !scanKey.isLoading else { return false }
        guard selectedIdentityID != nil, profileData != nil, entry.isArtifactAvailable else { return false }
        if settings.preferences.signing.automaticCompatibilityAnalysis {
            // The card is the gate: signing waits for a current assessment of
            // exactly this configuration, and refuses while one is blocked.
            guard !isAnalyzing, analyzedFor == scanKey, let health else { return false }
            guard health.report.status != .blocked, health.entitlements != nil else { return false }
        }
        // With automatic analysis off, the pre-sign analysis is the gate
        // instead — the same checks, run when the user asks to sign.
        return true
    }

    var body: some View {
        List {
            Section { ReleaseReadinessLink(recordID: entry.record.id) }
            appSection
            RecommendedPresetSection(entry: entry, origin: .signingScreen)
            diagnosticsSection
            if isSigning || model.progress != nil {
                progressSection
            }
            identitySection
            profileSection
            entitlementsSection
            actionSection
            resultSections
            helpSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sign \(entry.record.displayName ?? "Application")")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadIdentities()
            if ReleaseTrain.isAvailable(.entitlementsStudio) {
                await studio.load(entry: entry, inspection: env.bundleInspection)
            }
        }
        .task { await loadSavedProfiles() }
        .task(id: scanKey) {
            guard !scanKey.isLoading else { return }
            guard settings.preferences.signing.automaticCompatibilityAnalysis else {
                // The user asked not to be assessed automatically. Signing
                // still runs its own pre-sign analysis, so nothing is left
                // unchecked — it simply is not run until the user signs.
                isAnalyzing = false
                health = nil
                analyzedFor = nil
                return
            }
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
        .onDisappear { preflightTask?.cancel() }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in handleProfilePicker(result) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .sheet(isPresented: $model.isPresentingDetails) {
            NavigationStack {
                if let result = model.result {
                    SigningDetailsView(result: result, entry: entry)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.isPresentingDetails = false } } }
                }
            }
        }
        .alert("Sign anyway?", isPresented: $isConfirmingStrictSign) {
            Button("Cancel", role: .cancel) { isSigningConfirmed = false }
            Button("Sign") { startSigning() }
        } message: {
            Text("Verification strictness is set to Strict and the pre-sign diagnostics reported \(strictFindingCount) finding\(strictFindingCount == 1 ? "" : "s"). ZynSign will not refuse — it wants you to confirm.")
        }
        .zToast(isPresented: $showSuccessToast, message: "Signed, verified, and delivered to Documents/Signed", style: .success)
        .zToast(isPresented: $showQueuedToast, message: "Added to the signing queue", style: .info)
        .zToast(isPresented: $showErrorToast, message: model.result?.failure?.userMessage ?? "Refused — nothing was delivered", style: .error, duration: .seconds(4))
        .zBottomSheet(isPresented: $showSigningOptions) {
            NavigationStack { SigningOptionsView(emitDEREntitlements: $emitDEREntitlements).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSigningOptions = false } } } }
        }
        .onChange(of: model.result?.status) { _, new in
            guard let new else { return }
            if new == .signed {
                ZHaptics.success()
                rememberSelections()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { successScale = 1.08 }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9).delay(0.18)) { successScale = 1 }
                showSuccessToast = true
            } else {
                ZHaptics.warning()
                showErrorToast = true
            }
        }
    }

    // MARK: - Application

    private var appSection: some View {
        Section("Application") {
            LabeledContent("Name", value: entry.record.displayName ?? "Unnamed Application")
            LabeledContent("Identifier", value: entry.record.bundleIdentifier.rawValue)
            LabeledContent("Version", value: entry.record.identity.shortVersionString ?? "—")
            LabeledContent("Build", value: entry.record.identity.buildVersion ?? "—")
            if !entry.isArtifactAvailable {
                Label("The package file is not available. Re-import the application before signing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            NavigationLink { BundleExplorerView(inspection: env.bundleInspection, entry: entry) } label: {
                Label("Explore IPA", systemImage: "square.stack.3d.up")
            }
            .disabled(!entry.isArtifactAvailable)
            .accessibilityHint("Opens the read-only IPA explorer.")
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
            if let preflightError {
                Label(preflightError, systemImage: "exclamationmark.shield")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text("Pre-Sign Diagnostics") } footer: {
            Text("The compatibility summary updates as you choose an identity, profile or signing option. These checks never change the IPA; the pipeline checks again when signing begins.")
        }
    }

    // MARK: - Engine progress

    @ViewBuilder
    private var progressSection: some View {
        let snapshot = model.progress
        Section("Progress") {
            ZCard(variant: .material, cornerRadius: ZRadius.lg) {
                VStack(alignment: .leading, spacing: ZSpacing.md) {
                    HStack(alignment: .center, spacing: ZSpacing.md) {
                        ZProgressRing(
                            progress: snapshot?.fractionCompleted,
                            status: snapshot?.currentStage?.title ?? (model.result?.status == .signed ? "Signed" : "Signing")
                        )
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text(snapshot?.currentStage?.title ?? "Finishing")
                                .font(.headline)
                            Text(snapshot?.currentStage?.summary ?? snapshot?.detail ?? "Delivering the verified container")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: ZSpacing.xs) {
                                if let seconds = snapshot?.estimatedRemainingSeconds {
                                    Label("≈ \(seconds)s left", systemImage: "clock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let fraction = snapshot?.fractionCompleted {
                                    Text("\(Int((fraction * 100).rounded()))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if liveActivity.isActive {
                                    Label("Live Activity", systemImage: "livephoto")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    ZSigningStageList(records: model.stageRecords)
                }
            }
            .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md))
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(snapshot?.accessibilityDescription ?? "Signing progress")
            if isSigning {
                Button("Cancel Signing", role: .destructive) { model.cancel() }
                    .accessibilityHint("Stops the run, discards the working copy, and delivers nothing")
            }
        }
    }

    // MARK: - Identity, profile, entitlements

    private var identitySection: some View {
        Section {
            if isLoadingIdentities { ZSkeleton(rows: 2) }
            else if let err = identitiesError { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Button("Retry") { Task { await loadIdentities() } } }
            else if identities.isEmpty {
                ContentUnavailableView { Label("No Certificates", systemImage: "signature") } description: { Text("Import a .p12 identity in the Certificates tab to sign.") } actions: { NavigationLink { CertificateManagerView(store: env.identityStore, annotations: env.identityAnnotations, importer: env.pkcs12Importer) } label: { Label("Open Certificates", systemImage: "key.fill") }.buttonStyle(.bordered) }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } else {
                Picker("Signing Identity", selection: $selectedIdentityID) {
                    Text("Select Identity").tag(nil as SigningIdentityIdentifier?)
                    ForEach(identities, id: \.id) { identity in
                        VStack(alignment: .leading) {
                            Text(identity.displayName)
                            Text(identity.certificate.subject.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Optional(identity.id))
                    }
                }
                if let identity = selectedIdentity {
                    HStack { if identity.isUsableForSigning { ZStatusBadge.ready("Ready to sign") } else { ZStatusBadge.needsAttention("Not usable") }; Spacer() }
                    if identity.isUsableForSigning {
                        Text("The certificate is resolved again from secure storage when the signed bytes are verified.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("A usable identity has an available key, a certificate that matches it, and a ready signing capability.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Signing Identity")
        } footer: {
            Text("Private keys never leave the Keychain and are never displayed.")
        }
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
            if ReleaseTrain.isAvailable(.entitlementsStudio) {
                NavigationLink {
                    EntitlementsStudioView(entry: entry, studio: studio)
                } label: {
                    Label("Entitlements Studio", systemImage: "checklist")
                }
                .disabled(isSigning)
                Text("Inspect embedded app claims and compare with profile declarations. The current signing pipeline derives its output claims from the profile; these are not the same source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    // MARK: - Action

    private var actionSection: some View {
        Section {
            Button { startSigning() } label: {
                HStack {
                    Spacer()
                    if isSigning || isPreparingToSign {
                        ProgressView().tint(.white)
                        Text(isSigning ? "Signing…" : "Checking…").foregroundStyle(.white)
                    } else if model.result?.status == .signed {
                        Label("Sign Again", systemImage: "arrow.clockwise").fontWeight(.semibold)
                    } else {
                        Text("Sign Application").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .listRowBackground(canSign ? Color.accentColor : Color.gray.opacity(0.3))
            .foregroundStyle(canSign ? .white : .secondary)
            .disabled(!canSign)
            .accessibilityHint("Runs the complete on-device signing pipeline")
            if !canSign && !isSigning {
                Text(whyDisabled).font(.caption).foregroundStyle(.secondary)
            }
            if signingQueuePresentation.isAvailable {
                Button { Task { await addToQueue() } } label: {
                    Label("Add to Signing Queue Instead", systemImage: "tray.and.arrow.down")
                }
                .disabled(!canSign || isQueueing)
                .accessibilityHint("Queues this configuration and returns immediately; the queue signs in the background while you keep using ZynSign.")
                Button { signingQueuePresentation.present() } label: {
                    Label("Open Signing Queue", systemImage: "list.bullet.rectangle")
                }
                .foregroundStyle(.secondary)
            }
        } footer: {
            Text("The engine prepares an isolated working copy, validates the bundle, signs every nested binary inner-first, seals resources, signs the main executable, verifies the result independently, and only delivers a container that verified. Any refusal ends the run and leaves nothing behind.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hands the current configuration to the signing queue instead of
    /// running it here: the queue owns the work from this moment, and the
    /// screen is free to be left.
    ///
    /// Queueing is gated exactly like signing here: the button is enabled
    /// only when `canSign` holds — so a configuration the diagnostics block
    /// cannot be queued either — and ZynSign's lock is consulted before the
    /// job is accepted, because accepting it is the user's request to sign.
    private func addToQueue() async {
        guard canSign, !isQueueing else { return }
        guard let identityID = selectedIdentityID, let profile = profileData, entry.isArtifactAvailable else { return }
        isQueueing = true
        defer { isQueueing = false }
        let authorization = await appLock.authorize(.sign)
        guard authorization.isAuthenticated else {
            preflightError = authorization.message
            return
        }
        let summary = ProfileEntitlementDerivation.displaySummary(fromProvisioningProfile: profile)
        let submission = SigningJobSubmission(
            recordID: entry.record.id,
            artifactID: entry.record.artifact.artifactID,
            applicationName: entry.record.displayName ?? entry.record.bundleIdentifier.rawValue,
            bundleIdentifier: entry.record.bundleIdentifier.rawValue,
            versionText: ApplicationLibraryRowContent(entry: entry).versionText,
            identityID: identityID,
            identityDisplayName: selectedIdentity?.displayName,
            certificateFingerprint: selectedIdentity?.fingerprint,
            profile: profile,
            profileDisplayName: summary?.name ?? profileFileName,
            profileTeamIdentifier: summary?.teamIdentifier,
            emitDEREntitlements: emitDEREntitlements
        )
        env.signingQueue.enqueue(submission, priority: .normal, origin: .signingScreen)
        env.recordAnalyticsEvent(category: .signing, name: "queue.job.enqueued", succeeded: true)
        ZHaptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showQueuedToast = true }
    }

    private var whyDisabled: String {
        if isSigning { return "A signing run is already in progress." }
        if isPreparingToSign { return "Rechecking the inputs before signing…" }
        if !entry.isArtifactAvailable { return "The package file is not available." }
        if selectedIdentityID == nil { return "Select a signing identity." }
        if profileData == nil { return "Choose a provisioning profile." }
        if settings.preferences.signing.automaticCompatibilityAnalysis {
            if isAnalyzing || analyzedFor != scanKey { return "Checking this configuration before signing…" }
            if health?.report.status == .blocked {
                return "Resolve the blocked checks in Signing Diagnostics before signing."
            }
            if health?.entitlements == nil { return "The profile's authenticated entitlements are not available." }
            if let analysisError { return analysisError }
        } else if let analysisError {
            return analysisError
        }
        return "Resolve the requirements above to sign."
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSections: some View {
        if let result = model.result {
            switch result.status {
            case .signed:
                signedSection(result)
            case .failed:
                refusedSection(result)
            }
        }
    }

    @ViewBuilder
    private func signedSection(_ result: SigningEngineResult) -> some View {
        if let url = result.outputURL {
            Section("Signed Application") {
                ZCard(variant: .filled, cornerRadius: ZRadius.lg) {
                    HStack(spacing: ZSpacing.md) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                            .scaleEffect(successScale)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text("Signed and verified")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text(model.deliverySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: ZSpacing.xs) {
                                if let summary = result.summary {
                                    ZStatusBadge(
                                        "\(summary.verificationPassedCount)/\(summary.verificationCheckCount) checks",
                                        systemImage: "checkmark.shield.fill",
                                        kind: summary.verificationPassed ? .success : .warning
                                    )
                                    if summary.nestedTargetCount > 0 {
                                        ZStatusBadge("\(summary.nestedTargetCount) nested", systemImage: "square.stack.3d.up", kind: .neutral)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md))
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)

                ZSigningStageList(records: result.progress.records)

                LabeledContent("Output", value: url.lastPathComponent)
                if let workingCopy = result.workingCopy {
                    LabeledContent("Original", value: workingCopy.originalUnchanged ? "Unchanged (re-measured)" : "Not re-measured")
                    LabeledContent("Working copy", value: workingCopy.discarded ? "Discarded (\(workingCopy.reclaimedItemCount) items)" : "Kept")
                }

                Button { ZHaptics.tap(); shareItem = ShareURL(url: url) } label: { Label("Export IPA", systemImage: "square.and.arrow.up") }
                Button { model.isPresentingDetails = true } label: { Label("Open Details", systemImage: "list.bullet.rectangle") }
                Button {
                    ZHaptics.tap()
                    Task { await model.verifyAgain(environment: env) }
                } label: {
                    HStack {
                        Label("Verify Again", systemImage: "checkmark.shield")
                        Spacer()
                        if model.isReVerifying { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(model.isReVerifying)
                if let reVerification = model.reVerification {
                    HStack(spacing: ZSpacing.xs) {
                        ZStatusBadge(
                            reVerification.passed ? "Re-verified" : "No longer verifies",
                            systemImage: reVerification.passed ? "checkmark.shield.fill" : "xmark.octagon.fill",
                            kind: reVerification.passed ? .success : .error
                        )
                        Text("\(reVerification.checks.filter(\.passed).count)/\(reVerification.checks.count) checks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                if let message = model.reVerificationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if ReleaseTrain.isAvailable(.deliveryHandoff) {
                    NavigationLink {
                        InstallationDeliveryView(package: InstallationDeliveryPackage(signedIPA: url, record: entry.record))
                    } label: {
                        Label("Deliver…", systemImage: "tray.and.arrow.up")
                    }
                }
                Button { dismiss() } label: { Label("Return to Library", systemImage: "chevron.backward") }
                Text("The container in Documents/Signed is the artifact the engine produced and verified. It carries no trust or installability claim.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func refusedSection(_ result: SigningEngineResult) -> some View {
        if let failure = result.failure {
            Section("Signing Refused") {
                ZCard(variant: .outlined, cornerRadius: ZRadius.lg) {
                    VStack(alignment: .leading, spacing: ZSpacing.sm) {
                        HStack(alignment: .top, spacing: ZSpacing.xs) {
                            Image(systemName: "xmark.octagon.fill").font(.title3).foregroundStyle(.red).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text("Refused at \(failure.stage.title)").font(.headline).foregroundStyle(.red)
                                Text(failure.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: ZSpacing.xs) {
                            ZStatusBadge(failure.originalUnchanged ? "Original unchanged" : "Original not re-measured",
                                         systemImage: failure.originalUnchanged ? "checkmark.shield" : "questionmark.circle",
                                         kind: failure.originalUnchanged ? .success : .warning)
                            ZStatusBadge(failure.workingCopyDiscarded ? "Working copy discarded" : "Working copy kept",
                                         systemImage: "trash",
                                         kind: failure.workingCopyDiscarded ? .neutral : .warning)
                            if failure.outputPreexisted {
                                ZStatusBadge("Existing artifact kept", systemImage: "doc", kind: .neutral)
                            }
                        }
                        Text(failure.userMessage).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md))
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)

                ZSigningStageList(records: result.progress.records)

                if failure.isRetryable {
                    Button { ZHaptics.tap(); startSigning() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    Text("The inputs were not what refused — the same setup may succeed on a retry.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("These inputs need to change before signing can succeed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { model.isPresentingDetails = true } label: { Label("Open Details", systemImage: "list.bullet.rectangle") }
                Button { dismiss() } label: { Label("Return to Library", systemImage: "chevron.backward") }
            }
        }
    }

    private var helpSection: some View {
        Section("About Signing") {
            Text("Signing appends a code signature and never replaces an existing one — inputs must be unsigned. Nested binaries are signed inner-first and the main executable last; the resource seal references each nested binary by its code-directory digest, and symbolic links are recorded as seal omissions.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

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
            // The preferred identity from Settings → Signing is the starting
            // point; anything the user picks here overrides it for this run.
            if selectedIdentityID == nil {
                selectedIdentityID = preferredIdentityID
                    ?? identities.first(where: { $0.isUsableForSigning })?.id
                    ?? identities.first?.id
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

    /// An old picker result or app-record score is never a signing input.
    /// A forced local scan must finish for precisely the current selection
    /// before the engine receives its authenticated profile claims.
    @MainActor private func startSigning() {
        guard canSign else { return }
        isPreparingToSign = true
        preflightError = nil
        preflightTask = Task { await preflightAndStart() }
    }

    @MainActor private func preflightAndStart() async {
        defer {
            isPreparingToSign = false
            preflightTask = nil
        }
        guard let diagnostics = env.signingDiagnostics,
              let identityID = selectedIdentityID, let profile = profileData else {
            preflightError = "Resolve the current signing diagnostics before signing."
            return
        }
        let requestedKey = scanKey
        if let savedID = selectedSavedProfileID {
            do {
                guard let current = try await env.provisioningProfiles?.profileBytes(withID: savedID) else {
                    clearProfileSelection()
                    profileError = "That saved profile is no longer available."
                    preflightError = "Choose a current profile and review its diagnostics."
                    return
                }
                guard !Task.isCancelled, requestedKey == scanKey else { return }
                guard current == profile else {
                    profileData = current
                    profileRevision += 1
                    preflightError = "The saved profile changed. Review its updated diagnostics before signing."
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                profileData = nil
                profileRevision += 1
                profileError = "The saved profile could not be read. Re-import it or choose another."
                preflightError = "The saved profile is unavailable. Review the new diagnostics."
                return
            }
        }
        let preflight: SigningDiagnosticsAnalysis
        do {
            preflight = try await diagnostics.analyze(
                recordWithID: entry.record.id, identityID: identityID,
                profileData: profile, emitDEREntitlements: requestedKey.emitDER,
                force: true
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requestedKey == scanKey else { return }
            preflightError = "Pre-sign verification could not complete. Re-run diagnostics."
            return
        }
        guard !Task.isCancelled, requestedKey == scanKey else { return }
        health = preflight
        analyzedFor = requestedKey
        guard preflight.report.status != .blocked,
              let entitlements = preflight.entitlements else {
            preflightError = "Signing is blocked by updated diagnostics. Review the issues."
            return
        }
        let sourceURL = env.artifactFileURL(for: entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            preflightError = "The stored package is no longer available. Re-import it."
            scanRevision += 1
            return
        }
        // Authentication is asked for only when the user asked for it; a
        // locked ZynSign is unlocked by this same attempt.
        let authorization = await appLock.authorize(.sign)
        guard authorization.isAuthenticated else {
            preflightError = authorization.message
            return
        }
        // Strict verification asks before acting on a result that carries any
        // finding. It never refuses: confirming signs exactly as usual.
        if settings.preferences.advanced.verificationStrictness == .strict,
           !isSigningConfirmed,
           !preflight.report.issues.isEmpty {
            isSigningConfirmed = true
            isConfirmingStrictSign = true
            return
        }
        isSigningConfirmed = false
        ZHaptics.tap()
        liveActivity.start(stage: "Preparing", detail: "Creating an isolated working copy…")
        // The engine keeps no history, so the screen journals each run it
        // starts: the signing history and the library's signed state read
        // it. A journal write that fails never changes the run's outcome.
        let journal = SigningEngineJournalDraft(
            entry: entry, identity: selectedIdentity, profile: profile, startedAt: Date()
        )
        let history = env.signingHistory
        model.run(
            SigningEngineModel.makeRequest(
                entry: entry, sourceURL: sourceURL, profile: profile,
                identityID: identityID, entitlements: entitlements,
                emitDEREntitlements: requestedKey.emitDER
            ),
            environment: env,
            onFinish: { result, wasCancelled in
                guard let history else { return }
                let record = journal.record(result: result, wasCancelled: wasCancelled, finishedAt: Date())
                Task { try? await history.append(record) }
            }
        )
        mirrorProgressToLiveActivity()
    }

    /// The identity the user's signing preferences name, when it is still
    /// available. Named by the certificate's public fingerprint — never by
    /// anything that could reach key material.
    private var preferredIdentityID: SigningIdentityIdentifier? {
        guard let fingerprint = settings.preferences.signing.preferredIdentityFingerprint else { return nil }
        return identities.first { $0.fingerprint.hexDigest == fingerprint }?.id
    }

    /// How many findings the strict-verification confirmation names.
    private var strictFindingCount: Int {
        health?.report.issues.count ?? 0
    }

    /// Records what was signed with as the starting point for next time.
    ///
    /// Only the references are stored — the certificate's public fingerprint
    /// and the name the profile declares — never key material, and only when
    /// the user asked for selections to be remembered.
    private func rememberSelections() {
        guard settings.preferences.signing.rememberSelections else { return }
        settings.update { preferences in
            if let identity = selectedIdentity {
                preferences.signing.preferredIdentityFingerprint = identity.fingerprint.hexDigest
            }
            if let savedID = selectedSavedProfileID,
               let profile = savedProfiles.first(where: { $0.id == savedID }) {
                preferences.signing.preferredProfileName = profile.name
            }
        }
    }

    /// Mirrors the engine's own progress into the Live Activity while the
    /// screen is backgrounded. The in-app ring shows the same snapshot.
    private func mirrorProgressToLiveActivity() {
        Task {
            while model.isRunning {
                if let progress = model.progress {
                    liveActivity.update(
                        progress: progress.fractionCompleted,
                        detail: progress.detail.isEmpty
                            ? (progress.currentStage?.title ?? "Signing")
                            : "\(progress.currentStage?.title ?? "Signing") — \(progress.detail)"
                    )
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            liveActivity.end(success: model.result?.status == .signed)
        }
    }
}

private struct ShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
