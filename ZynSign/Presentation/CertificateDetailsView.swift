import SwiftUI
import UIKit

/// The dedicated details screen for one signing identity.
///
/// The screen presents the identity in the order a developer reads it:
/// who it is (common name, organization, team), what the certificate
/// declares (issuer, serial, algorithm, key size, fingerprint), how much
/// validity is left (created, expires, remaining days), and the state of
/// the key behind it. The quick actions a card offers are all here too:
/// set the default, rename the display label locally, copy the team ID,
/// export the public metadata, and remove the registration.
///
/// The screen reads the item live from the model by fingerprint, so a
/// change made on the screen — a rename, a default, a removal — is
/// reflected as it happens, and a removal made elsewhere takes the screen
/// to its "no longer available" state rather than showing a ghost.
struct CertificateDetailView: View {

    @ObservedObject private var model: CertificateManagerModel
    let fingerprint: String

    @State private var itemPendingRemoval: CertificateManagerModel.CertificateItem?
    @State private var showDeleteConfirm = false
    @State private var showRename = false
    @State private var exportURL: URL?
    @State private var showExportShare = false
    @State private var exportError: String?
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .success

    /// Creates the detail screen for one registered identity.
    ///
    /// Written explicitly because the stored `private` and `@State`
    /// properties would otherwise synthesize an initializer no other file
    /// can call.
    init(model: CertificateManagerModel, fingerprint: String) {
        self._model = ObservedObject(wrappedValue: model)
        self.fingerprint = fingerprint
    }

    /// The item as the model holds it right now, or `nil` when the identity
    /// is no longer registered (removed while this screen was showing).
    private var item: CertificateManagerModel.CertificateItem? {
        guard case .loaded(let items) = model.phase else { return nil }
        return items.first { $0.id == fingerprint }
    }

    var body: some View {
        Group {
            if let item {
                details(for: item)
            } else {
                ContentUnavailableView {
                    Label("No Longer Available", systemImage: "questionmark.circle")
                } description: {
                    Text("This identity is no longer registered. Go back to see your certificates.")
                }
            }
        }
        .navigationTitle(item?.displayName ?? "Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRename) {
            if let item {
                RenameIdentitySheet(
                    initialLabel: item.displayLabel,
                    certificateName: item.commonName,
                    onSave: { label in
                        Task {
                            if await model.setDisplayLabel(label, for: item) {
                                let removed = (label == nil)
                                presentToast(
                                    removed ? "Display label removed" : "Display label updated",
                                    style: .success
                                )
                            }
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL {
                #if os(iOS)
                ShareSheet(url: url)
                    .ignoresSafeArea()
                #endif
            }
        }
        .confirmationDialog(
            "Remove Identity?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: itemPendingRemoval
        ) { item in
            Button("Remove Identity", role: .destructive) {
                itemPendingRemoval = nil
                Task {
                    if await model.remove(item) {
                        presentToast("Identity removed", style: .success)
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemPendingRemoval = nil }
        } message: { item in
            Text("“\(item.displayName)” will be forgotten. The signing key it borrowed stays with its provisioning component, and anything signed with it is unaffected. This cannot be undone.")
        }
        .zToast(isPresented: $showToast, message: toastMessage, style: toastStyle)
    }

    // MARK: - Content

    private func details(for item: CertificateManagerModel.CertificateItem) -> some View {
        List {
            Section {
                header(for: item)
            }
            identitySection(for: item)
            certificateSection(for: item)
            validitySection(for: item)
            keyStatusSection(for: item)
            quickActions(for: item)
            Section {
                Text("Private-key bytes are never displayed, logged, or persisted outside the Keychain. This screen shows only public certificate metadata, the store's status snapshot, and your local notes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(for item: CertificateManagerModel.CertificateItem) -> some View {
        HStack(spacing: ZSpacing.sm) {
            CertificateIconWell(item: item, size: 52)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: ZSpacing.xs) {
                    if item.isDefault {
                        ZStatusBadge("Default for future signing", systemImage: "star.fill", kind: .info)
                    }
                    CertificateBadges.expiration(for: item)
                    CertificateBadges.kind(for: item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ZSpacing.xs)
    }

    private func identitySection(for item: CertificateManagerModel.CertificateItem) -> some View {
        Section("Identity") {
            LabeledContent("Common Name", value: item.commonName)
            if let organization = item.organization {
                LabeledContent("Organization", value: organization)
            }
            if let teamName = item.teamName {
                LabeledContent("Team Name", value: teamName)
            }
            if let teamID = item.teamID {
                LabeledContent("Team ID", value: teamID)
                    .textSelection(.enabled)
            }
            if let label = item.displayLabel {
                LabeledContent("Display Label", value: label)
                Button {
                    showRename = true
                } label: {
                    Label("Edit Display Label", systemImage: "pencil")
                }
                .foregroundStyle(.blue)
            }
        }
    }

    private func certificateSection(for item: CertificateManagerModel.CertificateItem) -> some View {
        Section("Certificate") {
            LabeledContent("Issuer", value: item.identity.certificate.issuer.displayName)
            LabeledContent("Serial Number", value: item.identity.certificate.serialNumber.hexadecimal.uppercased())
                .textSelection(.enabled)
            LabeledContent("Algorithm", value: algorithmText(for: item))
            LabeledContent("Signature Algorithm", value: item.identity.certificate.signatureAlgorithm.displayName)
            LabeledContent("SHA-256 Fingerprint", value: item.identity.certificate.sha256Fingerprint.hexDigest)
                .textSelection(.enabled)
            LabeledContent("Self-Signed", value: item.identity.certificate.isSelfSigned ? "Yes" : "No")
            if let imported = item.importedAt {
                LabeledContent("Imported", value: imported.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func validitySection(for item: CertificateManagerModel.CertificateItem) -> some View {
        let remaining = remainingText(for: item)
        return Section("Validity") {
            LabeledContent(
                "Created",
                value: item.identity.certificate.notValidBefore.formatted(date: .long, time: .omitted)
            )
            LabeledContent(
                "Expires",
                value: item.identity.certificate.notValidAfter.formatted(date: .long, time: .omitted)
            )
            LabeledContent("Remaining") {
                Text(remaining.text)
                    .foregroundStyle(remaining.color)
            }
            HStack {
                Text("Status")
                Spacer()
                CertificateBadges.expiration(for: item)
            }
        }
    }

    private func keyStatusSection(for item: CertificateManagerModel.CertificateItem) -> some View {
        Section("Key Status") {
            LabeledContent("Key Availability", value: item.identity.keyAvailability.rawValue.capitalized)
            LabeledContent("Association", value: String(describing: item.identity.association).capitalized)
            LabeledContent("Capability", value: String(describing: item.identity.capabilityState).capitalized)
            LabeledContent("Usable for Signing") {
                Text(item.identity.isUsableForSigning ? "Yes" : "No")
                    .foregroundStyle(item.identity.isUsableForSigning ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private func quickActions(for item: CertificateManagerModel.CertificateItem) -> some View {
        Section("Quick Actions") {
            if item.isDefault {
                Button {
                    Task { _ = await model.clearDefault() }
                } label: {
                    Label("Clear Default", systemImage: "star.slash")
                }
                .foregroundStyle(.orange)
            } else {
                Button {
                    Task { _ = await model.setDefault(item) }
                } label: {
                    Label("Set as Default for Future Signing", systemImage: "star")
                }
                .foregroundStyle(.blue)
            }
            Button {
                showRename = true
            } label: {
                Label("Rename Display Label", systemImage: "pencil")
            }
            .foregroundStyle(.blue)
            if let teamID = item.teamID {
                Button {
                    copyToPasteboard(teamID)
                } label: {
                    Label("Copy Team ID", systemImage: "doc.on.doc")
                }
                .foregroundStyle(.blue)
            }
            Button {
                exportMetadata(for: item)
            } label: {
                Label("Export Public Backup (JSON)", systemImage: "square.and.arrow.up")
            }
            .foregroundStyle(.blue)
            if let error = exportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            Button(role: .destructive) {
                itemPendingRemoval = item
                showDeleteConfirm = true
            } label: {
                Label("Remove Identity", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func algorithmText(for item: CertificateManagerModel.CertificateItem) -> String {
        let info = item.identity.certificate.publicKeyInfo
        let curve: String
        switch (info.curveName, info.curveIdentifier) {
        case (.some(let name), _): curve = " • \(name)"
        case (.none, .some(let identifier)): curve = " • \(identifier)"
        case (.none, .none): curve = ""
        }
        if let bits = info.keySizeInBits {
            return "\(info.algorithm.displayName) • \(bits) bits\(curve)"
        }
        return "\(info.algorithm.displayName)\(curve)"
    }

    private func remainingText(for item: CertificateManagerModel.CertificateItem) -> (text: String, color: Color) {
        switch item.expiration.status {
        case .healthy, .expiringSoon:
            let days = item.expiration.remainingDays ?? 0
            if days > 1 {
                return ("\(days) days remaining", .primary)
            } else if days == 1 {
                return ("1 day remaining", .primary)
            } else {
                return ("Expires today", .primary)
            }
        case .expired:
            let days = -(item.expiration.remainingDays ?? 0)
            if days > 1 {
                return ("Expired \(days) days ago", .red)
            } else if days == 1 {
                return ("Expired 1 day ago", .red)
            } else {
                return ("Expired today", .red)
            }
        case .notYetValid:
            return (
                "Valid from \(item.identity.certificate.notValidBefore.formatted(date: .abbreviated, time: .omitted))",
                .secondary
            )
        }
    }

    private func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #endif
        ZHaptics.tap()
        presentToast("Team ID copied", style: .info)
    }

    private func exportMetadata(for item: CertificateManagerModel.CertificateItem) {
        exportError = nil
        do {
            let service = CertificateExportService()
            exportURL = try service.backupURL(for: item.identity)
            showExportShare = true
        } catch {
            exportError = "The certificate backup could not be created."
        }
    }

    private func presentToast(_ message: String, style: ZToast.Style = .success) {
        toastMessage = message
        toastStyle = style
        withAnimation(ZMotion.interactive) {
            showToast = true
        }
    }
}

// MARK: - Import password sheet

/// The sheet that asks for the password protecting the selected
/// PKCS#12 container.
///
/// The password the user enters lives in this sheet's own state: it is
/// handed once to the import action and is destroyed with the sheet. It is
/// never stored, logged, shown again, or passed to analytics.
struct ImportIdentityPasswordSheet: View {

    let fileName: String
    let isImporting: Bool
    let importError: String?
    let onImport: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    /// Whether the password is shown as typed. A mistyped password is the
    /// commonest reason an import refuses a perfectly good `.p12`, and a
    /// masked field gives no way to see the difference.
    @State private var revealsPassword = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: fileName)
                    HStack(spacing: ZSpacing.sm) {
                        passwordField
                        Button {
                            revealsPassword.toggle()
                        } label: {
                            Image(systemName: revealsPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(revealsPassword ? "Hide the password" : "Show the password")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isImporting)
                    }
                } header: {
                    Text("Certificate Password")
                } footer: {
                    Text("The password is used only to unlock the selected file. It is never stored, shown again, or logged. Leave it empty when the file was exported without one.")
                }
                if let importError {
                    Section {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Import Certificate")
            .navigationBarTitleDisplayMode(.inline)
            // The sheet exists to type one thing: the field has the keyboard
            // from the first frame, and the keyboard's own button finishes the
            // job the toolbar button does.
            .defaultFocus($passwordFocused, true)
            .onSubmit { submit() }
            // Revealing replaces one field with the other; without this the
            // keyboard drops and typing the rest of the password means another
            // tap.
            .onChange(of: revealsPassword) { _, _ in passwordFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        submit()
                    }
                    .disabled(isImporting)
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    /// The field the password is typed into — masked by default, plain while
    /// it is being revealed. Both forms keep the same behaviour: no
    /// capitalisation, no correction, no autofill beyond the password hint.
    @ViewBuilder
    private var passwordField: some View {
        if revealsPassword {
            TextField("Password (leave empty if none)", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($passwordFocused)
        } else {
            SecureField("Password (leave empty if none)", text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($passwordFocused)
        }
    }

    /// Hands the password to the import, once.
    ///
    /// The keyboard's return key reaches this too, so a second press while an
    /// import is in flight is turned away here rather than starting a second
    /// one.
    /// Hands the typed password to the importer and puts the keyboard away, so
    /// the in-flight progress is visible while the work runs.
    private func submit() {
        guard !isImporting else { return }
        passwordFocused = false
        onImport(password)
    }
}

// MARK: - Import success summary

/// The success summary shown after an identity is imported: what arrived,
/// what it declares, and how much validity it has left.
struct ImportIdentitySummaryView: View {

    let item: CertificateManagerModel.CertificateItem
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: ZSpacing.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Certificate Imported")
                    .font(.title2.weight(.semibold))
                Text(item.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    summaryRow("Team", item.teamName ?? item.teamID ?? "Not declared")
                    summaryRow("Type", item.kind.displayName)
                    summaryRow("Expires", item.identity.certificate.notValidAfter.formatted(date: .abbreviated, time: .omitted))
                    summaryRow("Key", keyStatusText)
                }
                .padding(ZSpacing.md)
                .frame(maxWidth: .infinity)
                .zynCardBackground()
                Text("Your signing key stays on this device, in secure storage. It is never shown, logged, or exported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ZSpacing.lg)
                Spacer(minLength: 0)
            }
            .padding(.top, ZSpacing.xl)
            .frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var keyStatusText: String {
        switch item.identity.keyAvailability {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Rename sheet

/// The sheet that renames how an identity is displayed in ZynSign.
///
/// The rename is local only: it changes the label ZynSign shows, never the
/// certificate itself, and never affects signing. Saving with an empty
/// field clears the label and returns to the certificate's own name.
struct RenameIdentitySheet: View {

    let initialLabel: String?
    let certificateName: String
    let onSave: (String?) -> Void

    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(
        initialLabel: String?,
        certificateName: String,
        onSave: @escaping (String?) -> Void
    ) {
        self.initialLabel = initialLabel
        self.certificateName = certificateName
        self.onSave = onSave
        _draft = State(initialValue: initialLabel ?? "")
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display label", text: $draft)
                        .autocorrectionDisabled()
                } header: {
                    Text("Display Label")
                } footer: {
                    Text("Shown in ZynSign only. The certificate itself is never changed, and renaming does not affect signing. Leave empty to use the certificate's own name: “\(certificateName)”")
                }
                if trimmedDraft.count > IdentityAnnotation.maximumLabelLength {
                    Section {
                        Label(
                            "Display labels can be at most \(IdentityAnnotation.maximumLabelLength) characters.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Rename Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmedDraft.isEmpty ? nil : trimmedDraft)
                        dismiss()
                    }
                    .disabled(trimmedDraft.count > IdentityAnnotation.maximumLabelLength)
                }
            }
        }
    }
}

// MARK: - Share sheet

/// The system share sheet for a generated file, wrapped for SwiftUI.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ ui: UIActivityViewController, context: Context) {}
}

// MARK: - Previews

private let previewEnvironment = CompositionRoot.fallbackEnvironment

#Preview("Password Sheet") {
    ImportIdentityPasswordSheet(
        fileName: "Example.p12",
        isImporting: false,
        importError: nil,
        onImport: { _ in },
        onCancel: {}
    )
}
