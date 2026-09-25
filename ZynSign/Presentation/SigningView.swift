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
struct SigningView: View {
    let entry: LibraryEntry
    @Environment(\.applicationEnvironment) private var env
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SigningEngineModel()
    @State private var identities: [SigningIdentity] = []
    @State private var selectedIdentityID: SigningIdentityIdentifier?
    @State private var isLoadingIdentities = true
    @State private var identitiesError: String?
    @State private var profileData: Data?
    @State private var profileFileName: String?
    @State private var profileError: String?
    @State private var showProfileImporter = false
    @State private var shareItem: ShareURL?
    @State private var showSigningOptions = false
    @State private var showSuccessToast = false
    @State private var showErrorToast = false
    @State private var emitDEREntitlements = false
    @State private var successScale: CGFloat = 1
    @StateObject private var liveActivity = LiveActivityService()

    private var isSigning: Bool { model.isRunning }
    private var selectedIdentity: SigningIdentity? {
        guard let id = selectedIdentityID else { return nil }
        return identities.first { $0.id == id }
    }
    private var canSign: Bool {
        !isSigning && selectedIdentityID != nil && profileData != nil && entry.isArtifactAvailable
    }

    var body: some View {
        List {
            appSection
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
        .task { await loadIdentities() }
        .refreshable { await loadIdentities() }
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
        .zToast(isPresented: $showSuccessToast, message: "Signed, verified, and delivered to Documents/Signed", style: .success)
        .zToast(isPresented: $showErrorToast, message: model.result?.failure?.userMessage ?? "Refused — nothing was delivered", style: .error, duration: .seconds(4))
        .zBottomSheet(isPresented: $showSigningOptions) {
            NavigationStack { SigningOptionsView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSigningOptions = false } } } }
        }
        .onChange(of: model.result?.status) { _, new in
            guard let new else { return }
            if new == .signed {
                ZHaptics.success()
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
            if let name = profileFileName, let data = profileData {
                LabeledContent("Profile", value: name)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                Button("Remove Profile", role: .destructive) { profileData = nil; profileFileName = nil; profileError = nil }
            } else {
                Button { showProfileImporter = true } label: { Label("Choose Provisioning Profile…", systemImage: "doc.badge.ellipsis") }
                Text("A .mobileprovision file that authorizes the target bundle identifier and contains the signing certificate. The file is read for this run and is not persisted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let err = profileError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
            }
        } header: {
            Text("Provisioning Profile")
        }
    }

    private var derivedEntitlements: CodeSigningEntitlements? {
        guard let data = profileData else { return nil }
        return try? Self.entitlements(fromProvisioningProfile: data)
    }
    private var derivedEntitlementsDiagnostic: String? {
        guard let data = profileData else { return nil }
        do { _ = try Self.entitlements(fromProvisioningProfile: data); return nil }
        catch let error as ZynSignError { return error.userMessage }
        catch { return "The profile's entitlements could not be derived." }
    }

    private var entitlementsSection: some View {
        Section {
            if profileData == nil {
                Text("Choose a provisioning profile to derive its entitlements. The engine holds the set against the profile before any code is signed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let entitlements = derivedEntitlements {
                HStack {
                    LabeledContent("Entitlements", value: "\(entitlements.count) from profile")
                    Spacer()
                    ZStatusBadge("\(entitlements.count) claims", systemImage: "checkmark.seal.fill", kind: entitlements.isEmpty ? .neutral : .success)
                }
                if entitlements.isEmpty {
                    Text("The profile authorizes an empty entitlement set — the run signs with no additional claims.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entitlements.keys.prefix(8), id: \.self) { key in
                        HStack {
                            Text(key).font(.caption).monospaced()
                            Spacer()
                            Text(Self.entitlementValueSummary(entitlements[key]))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if entitlements.count > 8 {
                        Text("+ \(entitlements.count - 8) more — the full set is signed and verified, never truncated.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Derived from the profile's Entitlements dictionary and preserved verbatim. Independent verification compares the embedded claims against this set after signing.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    LabeledContent("Entitlements", value: "Derivation failed")
                    Spacer()
                    ZStatusBadge("Not derived", systemImage: "exclamationmark.triangle", kind: .error)
                }
                if let diagnostic = derivedEntitlementsDiagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange) }
                Text("Signing proceeds with an empty set; the profile stage refuses the run if the profile requires claims.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $emitDEREntitlements) { Label("DER entitlements (iOS 15+ • 0x20400)", systemImage: "doc.text.image") }
                .tint(.blue)
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(emitDEREntitlements ? "0x20400" : "0x20200", systemImage: "cpu", kind: emitDEREntitlements ? .info : .neutral)
                ZStatusBadge(emitDEREntitlements ? "Slots 5 + 7" : "Slot 5", systemImage: "square.stack.3d.up", kind: .neutral)
            }
            Text(emitDEREntitlements
                 ? "DER is on — the XML blob (slot 5, 0xFADE7171) and the deterministic DER SET (slot 7, 0xFADE7172) are emitted with CodeDirectory version 0x20400."
                 : "DER is off — XML entitlements only (slot 5), CodeDirectory version 0x20200. Turn on for iOS 15+ DER enforcement.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NavigationLink { SigningOptionsView() } label: { Label("Signing Options", systemImage: "slider.horizontal.3") }
        } header: {
            Text("Entitlements")
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        Section {
            Button { startSigning() } label: {
                HStack {
                    Spacer()
                    if isSigning {
                        ProgressView().tint(.white)
                        Text("Signing…").foregroundStyle(.white)
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
        } footer: {
            Text("The engine prepares an isolated working copy, validates the bundle, signs every nested binary inner-first, seals resources, signs the main executable, verifies the result independently, and only delivers a container that verified. Any refusal ends the run and leaves nothing behind.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whyDisabled: String {
        if !entry.isArtifactAvailable { return "The package file is not available." }
        if selectedIdentityID == nil { return "Select a signing identity." }
        if profileData == nil { return "Choose a provisioning profile." }
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

    private func loadIdentities() async {
        isLoadingIdentities = true
        defer { isLoadingIdentities = false }
        do {
            identities = try env.identityStore.listIdentities()
            identitiesError = nil
            if selectedIdentityID == nil,
               let first = identities.first(where: { $0.isUsableForSigning }) ?? identities.first {
                selectedIdentityID = first.id
            }
        } catch let error as ZynSignError {
            identitiesError = error.userMessage
        } catch {
            identitiesError = "Secure identity storage could not be accessed."
        }
    }

    private func handleProfilePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "mobileprovision" || ext == "provisionprofile" else {
                profileError = "The selected file is not a provisioning profile. Choose a .mobileprovision file."
                return
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
                profileError = "The profile could not be read or is too large."
                return
            }
            profileData = data
            profileFileName = url.lastPathComponent
            profileError = nil
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }
            profileError = (error as? ZynSignError)?.userMessage ?? "The file picker could not provide the selected profile."
        }
    }

    /// Collects the run's inputs and hands them to the engine.
    private func startSigning() {
        guard let identityID = selectedIdentityID, let profile = profileData else { return }
        guard entry.isArtifactAvailable else { return }
        let sourceURL = env.artifactFileURL(for: entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let entitlements: CodeSigningEntitlements
        if let derived = derivedEntitlements {
            entitlements = derived
        } else if let empty = try? CodeSigningEntitlements(values: [:]) {
            entitlements = empty
        } else {
            return
        }
        ZHaptics.tap()
        liveActivity.start(stage: "Preparing", detail: "Creating an isolated working copy…")
        model.run(
            SigningEngineModel.makeRequest(
                entry: entry,
                sourceURL: sourceURL,
                profile: profile,
                identityID: identityID,
                entitlements: entitlements,
                emitDEREntitlements: emitDEREntitlements
            ),
            environment: env
        )
        mirrorProgressToLiveActivity()
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

extension SigningView {

    /// Derives the entitlement set a profile authorizes, reading the CMS
    /// container when the profile is wrapped and the payload directly when it
    /// is not.
    fileprivate static func entitlements(fromProvisioningProfile data: Data) throws -> CodeSigningEntitlements {
        let payload: Data
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent {
            payload = content
        } else if let range = data.range(of: Data("<?xml".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else if let range = data.range(of: Data("bplist00".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else {
            payload = data
        }
        let parser = PropertyListProvisioningProfileParser()
        do {
            let profile = try parser.parse(ProvisioningProfilePayload(plistData: payload))
            if let entitlements = profile.entitlements {
                return try CodeSigningEntitlements(profileEntitlements: entitlements)
            }
            return try CodeSigningEntitlements(values: [:])
        } catch {
            if let direct = try? EntitlementsPlistParser.parse(payload) {
                return direct
            }
            throw error
        }
    }

    /// A short, display-only rendering of one entitlement value. The value
    /// itself is signed verbatim; this text is for the screen.
    fileprivate static func entitlementValueSummary(_ value: ProvisioningProfileValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .string(let text):
            return text.count > 32 ? String(text.prefix(32)) + "…" : text
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .integer(let number):
            return String(number)
        case .real(let number):
            return String(number)
        case .data(let data):
            return "\(data.count) bytes"
        case .date:
            return "date"
        case .array(let items):
            return "\(items.count) items"
        case .dictionary(let entries):
            return "\(entries.count) keys"
        }
    }
}
