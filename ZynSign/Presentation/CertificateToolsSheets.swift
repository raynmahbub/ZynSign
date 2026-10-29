import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum PKCS12PickerTypes {
    static let allowed: [UTType] = {
        var types: [UTType] = []
        for ext in ["p12", "pfx"] {
            if let ut = UTType(filenameExtension: ext), !types.contains(ut) { types.append(ut) }
        }
        for id in ["com.rsa.pkcs-12", "com.microsoft.pkcs12"] {
            if let ut = UTType(id), !types.contains(ut) { types.append(ut) }
        }
        types.append(.data)
        return types
    }()
}

/// Import or create portable `.zcert` identity + profile archives.
struct ZynIdentityArchiveSheet: View {
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var isPickingArchive = false
    @State private var passwordOverride = ""
    @State private var exportName = "IdentityArchive"
    @State private var exportPassword = ""
    @State private var exportNotes = ""
    @State private var selectedP12URL: URL?
    @State private var isPickingP12 = false
    @State private var savedProfiles: [ProvisioningProfileSummary] = []
    @State private var selectedProfileID: ProvisioningProfileIdentifier?
    @State private var shareFileURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Action", selection: $mode) {
                        Text("Import .zcert").tag(0)
                        Text("Export .zcert").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.secondary)
                    }
                }

                if mode == 0 {
                    Section("Import .zcert Identity Archive") {
                        SecureField("Optional Password Override", text: $passwordOverride)
                        Button {
                            isPickingArchive = true
                        } label: {
                            Label("Choose .zcert File…", systemImage: "shippingbox.and.arrow.backward.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                } else {
                    Section("Create .zcert Identity Archive") {
                        TextField("Archive Name", text: $exportName)
                        SecureField("P12 Password (stored in archive)", text: $exportPassword)
                        TextField("Notes (optional)", text: $exportNotes)
                        Button {
                            isPickingP12 = true
                        } label: {
                            Label(selectedP12URL?.lastPathComponent ?? "Select .p12 File…", systemImage: "key.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        if !savedProfiles.isEmpty {
                            Picker("Provisioning Profile", selection: $selectedProfileID) {
                                Text("Choose Profile…").tag(nil as ProvisioningProfileIdentifier?)
                                ForEach(savedProfiles, id: \.id) { prof in
                                    Text(prof.name).tag(Optional(prof.id))
                                }
                            }
                        }
                        Button {
                            Task { await buildAndShareArchive() }
                        } label: {
                            Label("Generate & Share .zcert", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(selectedP12URL == nil || selectedProfileID == nil)
                    }
                }
            }
            .navigationTitle("Identity Archives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                savedProfiles = (try? await environment.provisioningProfiles?.allProfiles()) ?? []
                if selectedProfileID == nil {
                    selectedProfileID = savedProfiles.first?.id
                }
            }
            .fileImporter(isPresented: $isPickingArchive, allowedContentTypes: [.data, .item]) { result in
                if case .success(let url) = result {
                    Task { await importArchive(from: url) }
                }
            }
            .fileImporter(isPresented: $isPickingP12, allowedContentTypes: PKCS12PickerTypes.allowed) { result in
                if case .success(let url) = result {
                    selectedP12URL = url
                }
            }
            .sheet(isPresented: Binding(
                get: { shareFileURL != nil },
                set: { if !$0 { shareFileURL = nil } }
            )) {
                if let url = shareFileURL {
                    CertificateToolShareSheet(url: url)
                }
            }
        }
    }

    private func importArchive(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let outcome = try await CertificateBundleAssistant.importIdentityArchive(
                data: data,
                passwordOverride: passwordOverride,
                pkcs12Importer: environment.pkcs12Importer,
                profileImporter: environment.provisioningProfileImporter,
                profileLibrary: environment.provisioningProfiles
            )
            ZHaptics.success()
            statusMessage = "Imported “\(outcome.packageName)” and profile “\(outcome.profileSummary.name)”."
        } catch let err as ZynCertificateBundleCodec.CodecError {
            statusMessage = err.message
        } catch let zErr as ZynSignError {
            statusMessage = zErr.userMessage
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func buildAndShareArchive() async {
        guard let p12URL = selectedP12URL,
              let profID = selectedProfileID,
              let profBytes = try? await environment.provisioningProfiles?.profileBytes(withID: profID) else {
            statusMessage = "Select both a .p12 file and a saved provisioning profile."
            return
        }
        let accessed = p12URL.startAccessingSecurityScopedResource()
        defer { if accessed { p12URL.stopAccessingSecurityScopedResource() } }
        do {
            let p12Bytes = try Data(contentsOf: p12URL)
            let pkg = ZynCertificateBundle(
                name: exportName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "IdentityArchive" : exportName,
                password: exportPassword,
                p12Data: p12Bytes,
                mobileProvisionData: profBytes,
                notes: exportNotes
            )
            let encoded = try ZynCertificateBundleCodec.encode(pkg)
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(pkg.name).zcert")
            try encoded.write(to: outURL, options: .atomic)
            ZHaptics.success()
            shareFileURL = outURL
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// Bounded common-passphrase & custom wordlist recovery sheet for `.p12` files.
struct P12PasswordRecoverySheet: View {
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL?
    @State private var isPickingP12 = false
    @State private var customWordlist = ""
    @State private var isRunning = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Locked PKCS#12 (.p12)") {
                    Button {
                        isPickingP12 = true
                    } label: {
                        Label(selectedURL?.lastPathComponent ?? "Choose .p12 File…", systemImage: "lock.doc.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }

                Section {
                    TextEditor(text: $customWordlist)
                        .font(ZTypography.codeCaption)
                        .frame(minHeight: 110)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Custom Candidate Passwords (One per Line)")
                } footer: {
                    Text("Tests your custom candidates first, followed by filename stems and common certificate passphrases (1, 1234, 123456, password, apple, cert, developer, etc.).")
                }

                Section {
                    Button {
                        Task { await runRecovery() }
                    } label: {
                        HStack {
                            Label(isRunning ? "Testing Passwords…" : "Recover Password & Import", systemImage: "key.viewfinder")
                            Spacer()
                            if isRunning { ProgressView() }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(selectedURL == nil || isRunning)
                }

                if let resultMessage {
                    Section("Result") {
                        Text(resultMessage)
                            .font(ZTypography.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("P12 Password Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isPickingP12, allowedContentTypes: PKCS12PickerTypes.allowed) { result in
                if case .success(let url) = result {
                    selectedURL = url
                    resultMessage = nil
                }
            }
        }
    }

    private func runRecovery() async {
        guard let url = selectedURL else { return }
        isRunning = true
        defer { isRunning = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try Data(contentsOf: url)
            let outcome = try await CertificateBundleAssistant.recoverAndImportPKCS12(
                data: bytes,
                fileName: url.lastPathComponent,
                customWordlist: customWordlist,
                importer: environment.pkcs12Importer
            )
            ZHaptics.success()
            let pwDisplay = outcome.matchedPassword.isEmpty ? "(empty password)" : "“\(outcome.matchedPassword)”"
            resultMessage = "Matched password \(pwDisplay) after \(outcome.testedCount) check(s) and imported certificate into Keychain."
        } catch let zErr as ZynSignError {
            resultMessage = zErr.userMessage
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}

/// Bundled `signing-assets/` discovery & one-tap import sheet.
struct BundledSigningAssetsSheet: View {
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [BundledSigningAssetsDiscovery.DiscoveredAssetSet] = []
    @State private var manualPassword = ""
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    SecureField("Fallback P12 Password (when password.txt is absent)", text: $manualPassword)
                }
                Section("Discovered signing-assets (\(assets.count))") {
                    if assets.isEmpty {
                        Text("Place paired .p12 + .mobileprovision folders inside Documents/signing-assets/<Folder>/ (or bundle signing-assets/) to import them in one tap.")
                            .font(ZTypography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(assets) { item in
                            HStack(spacing: ZSpacing.sm) {
                                Image(systemName: "tray.full.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                    Text(item.folderName).font(ZTypography.subheadline)
                                    Text("\(item.p12URL.lastPathComponent) + \(item.profileURL.lastPathComponent)")
                                        .font(ZTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import") {
                                    Task { await importAssetSet(item) }
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bundled Signing Assets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                assets = BundledSigningAssetsDiscovery.discover()
            }
        }
    }

    private func importAssetSet(_ item: BundledSigningAssetsDiscovery.DiscoveredAssetSet) async {
        var importedParts: [String] = []
        if let importer = environment.provisioningProfileImporter,
           let summary = try? await importer.importProfile(at: item.profileURL) {
            try? await environment.provisioningProfiles?.upsert(summary)
            importedParts.append(summary.name)
        }
        if let bytes = try? Data(contentsOf: item.p12URL) {
            let pw = item.password.isEmpty ? manualPassword : item.password
            if (try? environment.pkcs12Importer.importPKCS12(data: bytes, password: pw)) != nil {
                importedParts.append(item.p12URL.lastPathComponent)
            }
        }
        ZHaptics.success()
        statusMessage = importedParts.isEmpty
            ? "Could not import \(item.folderName). Check the P12 password."
            : "Imported: \(importedParts.joined(separator: ", "))."
    }
}

/// Encrypted DNS (DoH / DoT) `.mobileconfig` generator for anti-revoke protection.
struct DNSRevocationShieldSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum PresetOption: String, CaseIterable, Identifiable {
        case adGuard = "AdGuard DoH"
        case cloudflare = "Cloudflare DoH"
        case quad9 = "Quad9 DoH"
        case nextDNS = "NextDNS DoH"
        case customDoT = "Custom DoT"
        var id: String { rawValue }
    }

    @State private var preset: PresetOption = .adGuard
    @State private var endpointText = "https://dns.adguard-dns.com/dns-query"
    @State private var enableOnDemand = true
    @State private var statusMessage: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("DNS Resolver", selection: $preset) {
                        ForEach(PresetOption.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    TextField(preset == .customDoT ? "DoT Hostname (e.g. dns.nextdns.io)" : "DoH HTTPS Endpoint", text: $endpointText)
                        .font(ZTypography.codeCaption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Encrypted DNS Resolver")
                } footer: {
                    Text("Generates a standard iOS Configuration Profile (.mobileconfig) configuring system-wide Encrypted DNS. Install in Settings → General → VPN, DNS & Device Management.")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.orange)
                    }
                }

                Section("Protection Rules") {
                    Toggle("Enable On-Demand Across Wi-Fi & Cellular", isOn: $enableOnDemand)
                }

                Section("Known Revocation Hostnames (\(DNSRevocationShieldProfile.appleRevocationHostnames.count))") {
                    ForEach(DNSRevocationShieldProfile.appleRevocationHostnames, id: \.self) { host in
                        Text(host).font(ZTypography.codeCaption)
                    }
                }

                Section {
                    Button {
                        exportMobileConfig()
                    } label: {
                        Label("Export .mobileconfig Profile", systemImage: "shield.lefthalf.filled.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .navigationTitle("DNS Shield Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: preset) { _, next in
                switch next {
                case .adGuard: endpointText = "https://dns.adguard-dns.com/dns-query"
                case .cloudflare: endpointText = "https://cloudflare-dns.com/dns-query"
                case .quad9: endpointText = "https://dns.quad9.net/dns-query"
                case .nextDNS: endpointText = "https://dns.nextdns.io/"
                case .customDoT: endpointText = "dns.adguard-dns.com"
                }
            }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let url = shareURL {
                    CertificateToolShareSheet(url: url)
                }
            }
        }
    }

    private func exportMobileConfig() {
        do {
            let data = try DNSRevocationShieldProfile.generateMobileconfig(
                displayName: "ZynSign Encrypted DNS (\(preset.rawValue))",
                protocolKind: preset == .customDoT ? .tls : .https,
                endpoint: endpointText,
                onDemandEnabled: enableOnDemand
            )
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("ZynSign-DNS-Shield.mobileconfig")
            try data.write(to: out, options: .atomic)
            statusMessage = nil
            ZHaptics.success()
            shareURL = out
        } catch let err as DNSRevocationShieldProfile.ProfileError {
            statusMessage = err.message
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct CertificateToolShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
