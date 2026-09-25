import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The Certificates screen — import, inspect, and manage signing identities.
///
/// Certificates are device-only: the private key never leaves the Keychain,
/// is stored `WhenUnlockedThisDeviceOnly` and non-extractable, and no key
/// material is logged or displayed. Import is explicit: the user picks a
/// `.p12` / `.pfx` file, enters the password, and the PKCS#12 container is
/// validated and registered through the secure store. The screen lists every
/// registered identity with its certificate metadata, validity, chain status,
/// and readiness for signing, and allows removal of the registration (the
/// borrowed key itself remains owned by its provisioning component).
struct CertificatesView: View {

    @Environment(\.applicationEnvironment) private var env

    @State private var identities: [SigningIdentity] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var pendingFileName: String?
    @State private var showPasswordSheet = false
    @State private var password = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importSuccess: String?

    @State private var identityToRemove: SigningIdentity?
    @State private var showDeleteConfirm = false
    @State private var showImportToast = false

    var body: some View {
        Group {
            if isLoading {
                ScrollView { ZSkeleton(rows: 4).padding() }
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Certificates Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if identities.isEmpty {
                ContentUnavailableView {
                    Label("No Certificates", systemImage: "signature")
                } description: {
                    Text("Import a .p12 or .pfx file to add a signing identity. Identities stay in the Keychain, marked non-extractable, and are never logged.")
                } actions: {
                    Button("Import Certificate…", systemImage: "square.and.arrow.down") {
                        showImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Supports password-protected PKCS#12 containers. The password is used only for import and is never stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            } else {
                List {
                    if let msg = importSuccess {
                        Section {
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if let err = importError, !showPasswordSheet {
                        Section {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("Identities (\(identities.count))") {
                        ForEach(identities, id: \.id) { identity in
                            NavigationLink(value: identity) {
                                CertificateRow(identity: identity)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    identityToRemove = identity
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    identityToRemove = identity
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Remove Registration", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Section("Security") {
                        Label("Private keys are device-only, non-extractable, and never logged.", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(.secondary)
                        Label("Removing a registration does not delete the borrowed Keychain key.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Certificates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Label("Import", systemImage: "plus")
                }
                .disabled(isImporting)
            }
            ToolbarItem(placement: .topBarLeading) {
                if isImporting { ProgressView() }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in handlePicker(result) }
        .sheet(isPresented: $showPasswordSheet) { passwordSheet }
        .confirmationDialog(
            "Remove Registration?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: identityToRemove
        ) { identity in
            Button("Remove Registration", role: .destructive) {
                Task { await remove(identity) }
            }
            Button("Cancel", role: .cancel) { identityToRemove = nil }
        } message: { identity in
            Text("“\(identity.displayName)” will be forgotten. The Keychain key it borrowed will not be deleted. This cannot be undone.")
        }
        .navigationDestination(for: SigningIdentity.self) { identity in
            CertificateDetailView(identity: identity)
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil && !showPasswordSheet }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .zToast(isPresented: $showImportToast, message: importSuccess ?? "Imported", style: .success)
        .onChange(of: importSuccess) { _, new in
            if new != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showImportToast = true }
            }
        }
    }

    // MARK: - Password sheet

    private var passwordSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("Certificate Password"), footer: Text("The password is used only to decrypt the selected PKCS#12 container. It is never stored, logged, or persisted.")) {
                    if let name = pendingFileName {
                        LabeledContent("File", value: name)
                    }
                    SecureField("Password (leave empty if none)", text: $password)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let err = importError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Import Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingData = nil; pendingFileName = nil; password = ""; importError = nil; showPasswordSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await performImport() } }
                        .disabled(isImporting)
                }
            }
            .overlay { if isImporting { ProgressView("Importing…").frame(maxWidth: .infinity, maxHeight: .infinity).background(.ultraThinMaterial) } }
            .interactiveDismissDisabled(isImporting)
        }
    }

    // MARK: - Actions

    private func handlePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "p12" || ext == "pfx" else {
                importError = "The selected file is not a PKCS#12 container. Choose a .p12 or .pfx file."
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                importError = "The selected file could not be read."
                return
            }
            guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
                importError = "The selected file is too large or empty."
                return
            }
            pendingData = data
            pendingFileName = url.lastPathComponent
            password = ""
            importError = nil
            showPasswordSheet = true
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            importError = (error as? ZynSignError)?.userMessage ?? "The file picker could not provide the selected file."
        }
    }

    private func performImport() async {
        guard let data = pendingData else { return }
        isImporting = true
        importError = nil
        importSuccess = nil
        do {
            let id = try env.pkcs12Importer.importPKCS12(data: data, password: password)
            if let identity = try? env.identityStore.identity(withID: id) {
                importSuccess = "Imported “\(identity.displayName)”."
            } else {
                importSuccess = "Certificate imported."
            }
            pendingData = nil; pendingFileName = nil; password = ""; showPasswordSheet = false
            env.recordAnalyticsEvent(category: .certificate, name: "certificate.imported", succeeded: true)
            await env.signingDiagnostics?.identitiesDidChange()
            NotificationCenter.default.post(name: .zynsignSigningIdentityChanged, object: nil)
            await reload()
        } catch let e as ZynSignError {
            importError = e.userMessage
            env.recordAnalyticsEvent(category: .certificate, name: "certificate.importFailed", succeeded: false)
        } catch {
            importError = (error as? ZynSignError)?.userMessage ?? "The certificate could not be imported."
            env.recordAnalyticsEvent(category: .certificate, name: "certificate.importFailed", succeeded: false)
        }
        isImporting = false
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            identities = try env.identityStore.listIdentities()
            loadError = nil
        } catch let e as ZynSignError {
            loadError = e.userMessage
        } catch {
            loadError = "Secure identity storage could not be accessed."
        }
    }

    private func remove(_ identity: SigningIdentity) async {
        #if os(iOS)
        if let secure = env.identityStore as? SecureIdentityStore {
            do {
                try secure.removeRegistration(identity.id)
                await env.signingDiagnostics?.identitiesDidChange()
                NotificationCenter.default.post(name: .zynsignSigningIdentityChanged, object: nil)
                await reload()
                importSuccess = "Removed “\(identity.displayName)”."
            } catch let e as ZynSignError {
                importError = e.userMessage
            } catch {
                importError = "The registration could not be removed."
            }
            identityToRemove = nil
            return
        }
        #endif
        importError = "Removing identities is not available on this platform."
        identityToRemove = nil
    }
}

// MARK: - Row & Detail

struct CertificateRow: View {
    let identity: SigningIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName).lineLimit(1).font(.body)
                    Text(identity.certificate.subject.displayName).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if identity.isUsableForSigning {
                    ZStatusBadge.ready()
                } else {
                    ZStatusBadge.needsAttention()
                }
            }
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(validityText, systemImage: "calendar", kind: .neutral)
                ZStatusBadge(identity.keyAvailability.rawValue, systemImage: "key", kind: identity.keyAvailability == .available ? .info : .warning)
                if identity.association == .matched {
                    ZStatusBadge.matched()
                } else if identity.association == .mismatched {
                    ZStatusBadge.mismatch()
                } else {
                    ZStatusBadge("Unknown", systemImage: "link", kind: .neutral)
                }
            }
            Text(fingerprintText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private var icon: String {
        switch identity.certificate.publicKeyInfo.algorithm {
        case .rsa: return "key.fill"
        case .ec: return "key.viewfinder"
        case .unknown: return "key"
        }
    }
    private var color: Color {
        identity.isUsableForSigning ? .green : .orange
    }
    private var validityText: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "\(f.string(from: identity.certificate.notValidBefore)) – \(f.string(from: identity.certificate.notValidAfter))"
    }
    private var fingerprintText: String {
        let hex = identity.certificate.sha256Fingerprint.hexDigest
        return String(hex.prefix(16)) + "…" + String(hex.suffix(16))
    }
}

struct CertificateDetailView: View {
    let identity: SigningIdentity
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Identity") {
                LabeledContent("Display Name", value: identity.displayName)
                LabeledContent("Identifier", value: identity.id.rawValue)
                    .textSelection(.enabled)
                LabeledContent("Storage", value: identity.storage.rawValue)
                LabeledContent("Non-extractable", value: identity.isKeyNonExportable.map { $0 ? "Yes" : "No" } ?? "Unknown")
            }
            Section("Certificate") {
                LabeledContent("Subject", value: identity.certificate.subject.displayName)
                LabeledContent("Issuer", value: identity.certificate.issuer.displayName)
                LabeledContent("Serial", value: identity.certificate.serialNumber.hexadecimal.uppercased())
                    .textSelection(.enabled)
                LabeledContent("SHA-256 Fingerprint", value: identity.certificate.sha256Fingerprint.hexDigest)
                    .textSelection(.enabled)
                LabeledContent("Valid From", value: identity.certificate.notValidBefore.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Valid Until", value: identity.certificate.notValidAfter.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Public Key", value: publicKeyText)
                LabeledContent("Key Adequate", value: identity.certificate.publicKeyInfo.appearsAdequateForCodeSigning ? "Yes" : "No")
                LabeledContent("Self-signed", value: identity.certificate.isSelfSigned ? "Yes" : "No")
            }
            Section("Key Status") {
                LabeledContent("Key Availability", value: identity.keyAvailability.rawValue)
                LabeledContent("Association", value: String(describing: identity.association))
                LabeledContent("Capability", value: String(describing: identity.capabilityState))
                LabeledContent("Usable for Signing", value: identity.isUsableForSigning ? "Yes" : "No")
                    .foregroundStyle(identity.isUsableForSigning ? .green : .orange)
            }
            Section("Export / Backup") {
                Button {
                    do {
                        let svc = CertificateExportService()
                        let url = try svc.backupURL(for: identity)
                        shareURL = url
                        showShare = true
                    } catch {
                        exportError = "The certificate backup could not be created."
                    }
                } label: {
                    Label("Export Public Backup (JSON)", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(.blue)
                Button {
                    do {
                        let svc = CertificateExportService()
                        let url = try svc.backupURL(for: identity)
                        shareURL = url
                        showShare = true
                    } catch {
                        exportError = "Share failed."
                    }
                } label: {
                    Label("Share Certificate Metadata", systemImage: "doc.text")
                }
                Text("Exports public metadata only — private key never leaves the Keychain and is never exported. Keep your original .p12 in a secure location; ZynSign does not re-export private-key bytes.").font(.footnote).foregroundStyle(.secondary)
                if let err = exportError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
            }
            Section {
                Text("Private-key bytes are never displayed, logged, or persisted outside the Keychain. This screen shows only public certificate metadata and the store's status snapshot.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(identity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(url: url)
            }
        }
    }

    private var publicKeyText: String {
        let info = identity.certificate.publicKeyInfo
        let algo = info.algorithm.displayName
        if let bits = info.keySizeInBits {
            return "\(algo) • \(bits) bits"
        }
        return algo
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ ui: UIActivityViewController, context: Context) {}
}
