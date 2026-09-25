import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Signing screen — Smart Sign with real entitlements, DER (0x20400) and Live Activities.
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
    @StateObject private var liveActivity = LiveActivityService()

    private var selectedIdentity: SigningIdentity? {
        guard let id = selectedIdentityID else { return nil }
        return identities.first { $0.id == id }
    }
    private var canSign: Bool { !isSigning && selectedIdentityID != nil && profileData != nil && entry.isArtifactAvailable }

    var body: some View {
        List {
            appSection
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
        .refreshable { await loadIdentities() }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in handleProfilePicker(result) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .alert("Signing Failed", isPresented: Binding(get: { signingError != nil }, set: { if !$0 { signingError = nil } })) { Button("OK", role: .cancel) { signingError = nil } } message: { Text(signingError ?? "") }
        .zToast(isPresented: $showSuccessToast, message: "Signed — ready in Documents/Signed", style: .success)
        .zToast(isPresented: $showErrorToast, message: signingError ?? "Refused — working copy discarded", style: .error, duration: .seconds(4))
        .zBottomSheet(isPresented: $showSigningOptions) {
            NavigationStack { SigningOptionsView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSigningOptions = false } } } }
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
            NavigationLink { BundleExplorerView(inspection: env.bundleInspection, entry: entry) } label: { Label("Explore IPA", systemImage: "square.stack.3d.up") }.disabled(!entry.isArtifactAvailable)
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
                }.pickerStyle(.navigationLink)
                if let idt = selectedIdentity {
                    LabeledContent("Key", value: idt.keyAvailability.rawValue)
                    LabeledContent("Association", value: String(describing: idt.association))
                    LabeledContent("Capability", value: String(describing: idt.capabilityState))
                    HStack { if idt.isUsableForSigning { ZStatusBadge.ready("Ready to sign") } else { ZStatusBadge.needsAttention("Not usable") }; Spacer() }
                    if idt.isUsableForSigning { Text("Private key verified, association matched — pipeline will verify again on sign.").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Usable only when key is available, certificate ↔ key match, and capability is ready. Re-import the correct .p12 or check validity.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: { Text("Signing Identity") } footer: { Text("Private keys never leave the Keychain and are never displayed. The pipeline verifies key association and protection on every operation.") }
    }

    private var profileSection: some View {
        Section {
            if let name = profileFileName, let data = profileData {
                LabeledContent("Profile", value: name)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                Button("Remove Profile", role: .destructive) { profileData = nil; profileFileName = nil; profileError = nil }
            } else {
                Button { showProfileImporter = true } label: { Label("Choose Provisioning Profile…", systemImage: "doc.badge.ellipsis") }
                Text("A .mobileprovision file that authorizes the target bundle identifier and contains the signing certificate. The file is read only for this signing run and is not persisted.").font(.caption).foregroundStyle(.secondary)
            }
            if let err = profileError { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            Button("Choose from Files") { showProfileImporter = true }.font(.footnote)
        } header: { Text("Provisioning Profile") }
    }

    private var derivedEntitlements: CodeSigningEntitlements? {
        guard let data = profileData else { return nil }
        return try? Self.entitlements(fromProvisioningProfile: data)
    }
    private var derivedEntitlementsDiagnostic: String? {
        guard let data = profileData else { return nil }
        do { _ = try Self.entitlements(fromProvisioningProfile: data); return nil }
        catch let e as ZynSignError { return e.userMessage }
        catch let e as EntitlementsError { return "Entitlements error: \(String(describing: e))" }
        catch { return "The profile's entitlements could not be derived." }
    }

    private var entitlementsSection: some View {
        Section {
            if profileData == nil {
                LabeledContent("Entitlements", value: "Choose a profile first")
                Text("Choose a provisioning profile to derive its entitlements. The signing pipeline validates the set against the profile before any code is signed.").font(.caption).foregroundStyle(.secondary)
            } else if let entitlements = derivedEntitlements {
                HStack { LabeledContent("Entitlements", value: "\(entitlements.count) from profile"); Spacer(); ZStatusBadge("\(entitlements.count) keys", systemImage: "checkmark.seal.fill", kind: .success) }
                if entitlements.isEmpty { Text("The profile authorizes an empty entitlement set — the pipeline will sign with no additional claims.").font(.caption).foregroundStyle(.secondary) }
                else {
                    ForEach(entitlements.keys.prefix(8), id: \.self) { key in HStack { Text(key).font(.caption).monospaced(); Spacer(); Text(Self.entitlementValueSummary(entitlements[key])).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
                    if entitlements.count > 8 { Text("+ \(entitlements.count - 8) more — full set is signed and verified, not truncated.").font(.caption2).foregroundStyle(.secondary) }
                    Text("Derived directly from the profile's Entitlements dictionary and preserved verbatim (unknown keys kept, ordering canonicalized on serialization). The pipeline holds this set against the profile's policy before signing.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { LabeledContent("Entitlements", value: "Derivation failed — empty will be tried"); Spacer(); ZStatusBadge("Not derived", systemImage: "exclamationmark.triangle", kind: .error) }
                if let diag = derivedEntitlementsDiagnostic { Text(diag).font(.caption).foregroundStyle(.orange) }
                Text("ZynSign could not read entitlements from this profile. Signing will proceed with an empty set and the pipeline's profile stage will refuse if the profile requires claims.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $emitDEREntitlements) { Label("DER entitlements (iOS 15+ • 0x20400)", systemImage: "doc.text.image") }.tint(.blue)
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(emitDEREntitlements ? "0x20400" : "0x20200", systemImage: "cpu", kind: emitDEREntitlements ? .info : .neutral)
                ZStatusBadge(emitDEREntitlements ? "Slot 5 + 7" : "Slot 5", systemImage: "square.stack.3d.up", kind: .neutral)
            }
            Text(emitDEREntitlements ? "DER is on — emits XML blob (slot 5, 0xFADE7171) and deterministic DER SET (slot 7, 0xFADE7172, v0x20400). iOS 15+ validates slot 7; older validates slot 5." : "DER is off — XML entitlements only (slot 5, v0x20200). Turn on for iOS 15+ DER enforcement.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if liveActivity.isActive, let state = liveActivity.currentState {
                HStack(spacing: ZSpacing.xs) { ZStatusBadge(state.stage, systemImage: "livephoto", kind: .info); ZStatusBadge("\(Int(state.progress*100))%", systemImage: "percent", kind: .neutral) }
                Text(state.detail).font(.caption2).foregroundStyle(.secondary)
            }
            NavigationLink { SigningOptionsView() } label: { Label("Signing Options", systemImage: "slider.horizontal.3") }
            Button { ZHaptics.tap(); showSigningOptions = true } label: { Label("Quick Options (Sheet)", systemImage: "rectangle.bottomthird.inset.filled") }.foregroundStyle(.secondary)
        } header: { Text("Entitlements") }
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
                                    HStack(spacing: ZSpacing.xs) { ZStatusBadge("Signing", systemImage: "hammer.fill", kind: .info); ZStatusBadge("9 stages", systemImage: "list.number", kind: .neutral); if emitDEREntitlements { ZStatusBadge("DER 0x20400", systemImage: "cpu", kind: .info) } }
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
                                        if result.status == .signed { ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success); if let c = result.stages?.discovery.nestedItemCount { ZStatusBadge("\(c) nested", systemImage: "internaldrive", kind: .neutral) }; if emitDEREntitlements { ZStatusBadge("DER", systemImage: "doc.text.image", kind: .info) } }
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
        if selectedIdentityID == nil { return "Select a signing identity." }
        if profileData == nil { return "Choose a provisioning profile." }
        if isSigning { return "A signing run is already in progress." }
        return "Resolve the requirements above to sign."
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

    private func loadIdentities() async {
        isLoadingIdentities = true
        defer { isLoadingIdentities = false }
        do {
            identities = try env.identityStore.listIdentities()
            identitiesError = nil
            if selectedIdentityID == nil, let first = identities.first(where: { $0.isUsableForSigning }) ?? identities.first { selectedIdentityID = first.id }
        } catch let e as ZynSignError { identitiesError = e.userMessage } catch { identitiesError = "Secure identity storage could not be accessed." }
    }

    private func handleProfilePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "mobileprovision" || ext == "provisionprofile" else { profileError = "The selected file is not a provisioning profile. Choose a .mobileprovision file."; return }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 10 * 1024 * 1024 else { profileError = "The profile could not be read or is too large."; return }
            profileData = data; profileFileName = url.lastPathComponent; profileError = nil
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            profileError = (error as? ZynSignError)?.userMessage ?? "The file picker could not provide the selected profile."
        }
    }

    private func sign() async {
        guard let identityID = selectedIdentityID, let profile = profileData else { signingError = "Select an identity and a provisioning profile."; return }
        guard entry.isArtifactAvailable else { signingError = "The package file is not available."; return }
        let sourceURL = env.artifactFileURL(for: entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { signingError = "The package file could not be found in ZynSign's storage."; return }
        isSigning = true; signingResult = nil; signingError = nil; outputURL = nil
        await liveActivity.start(stage: "Signing", detail: "Integrity → Profile → Discovery…")
        let entitlements: CodeSigningEntitlements
        if let derived = derivedEntitlements { entitlements = derived }
        else if let data = profileData, let fallback = try? Self.entitlements(fromProvisioningProfile: data) { entitlements = fallback }
        else {
            do { entitlements = try CodeSigningEntitlements(values: [:]) }
            catch { signingError = "The entitlement set could not be created."; isSigning = false; await liveActivity.end(success: false); return }
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let signedDir = docs.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: signedDir, withIntermediateDirectories: true)
        let base = (entry.record.displayName ?? entry.record.bundleIdentifier.rawValue).replacingOccurrences(of: " ", with: "_")
        let output = signedDir.appendingPathComponent("\(base)_signed.ipa")
        try? FileManager.default.removeItem(at: output)
        var options = SignApplicationOptions()
        if emitDEREntitlements { options = SignApplicationOptions(emitDEREntitlements: true) }
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

extension SigningView {
    fileprivate static func entitlements(fromProvisioningProfile data: Data) throws -> CodeSigningEntitlements {
        let payload: Data
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent { payload = content }
        else if let r = data.range(of: Data("<?xml".utf8)) { payload = data.subdata(in: r.lowerBound..<data.endIndex) }
        else if let r = data.range(of: Data("bplist00".utf8)) { payload = data.subdata(in: r.lowerBound..<data.endIndex) }
        else { payload = data }
        let parser = PropertyListProvisioningProfileParser()
        do {
            let profile = try parser.parse(ProvisioningProfilePayload(plistData: payload))
            if let ent = profile.entitlements { return try CodeSigningEntitlements(profileEntitlements: ent) }
            return try CodeSigningEntitlements(values: [:])
        } catch {
            if let direct = try? EntitlementsPlistParser.parse(payload) { return direct }
            throw error
        }
    }
    fileprivate static func entitlementValueSummary(_ value: ProvisioningProfileValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .string(let s): return s.count > 32 ? String(s.prefix(32)) + "…" : s
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .real(let r): return String(describing: r)
        case .data(let d): return "\(d.count) bytes"
        case .date: return "date"
        case .array(let a): return "\(a.count) items"
        case .dictionary(let d): return "\(d.count) keys"
        }
    }
}
