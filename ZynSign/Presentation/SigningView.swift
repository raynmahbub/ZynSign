import SwiftUI
import UniformTypeIdentifiers

/// The Signing area of the shell: choose a library package, a
/// provisioning profile, and a signing identity, then run the signing
/// pipeline.
///
/// The screen is explicit about what a run establishes. Profiles are
/// validated standalone before anything is signed; a development identity
/// is generated in this device's Keychain and is not an Apple-issued
/// certificate; a delivered container was checked by ZynSign's own
/// verifier only. Nothing on this screen claims trust, Apple acceptance,
/// or installability, and no installation control exists anywhere.
struct SigningView: View {

    @StateObject private var model: SigningModel
    @State private var isShowingProfilePicker = false

    init(signing: ApplicationSigning, library: ApplicationLibrary) {
        _model = StateObject(
            wrappedValue: SigningModel(signing: signing, library: library)
        )
    }

    /// The document types the profile picker offers. A profile extension
    /// the platform does not know falls back to any data file, because
    /// the validation pipeline judges the bytes, not the picker.
    private static let profileContentTypes: [UTType] = [
        UTType(filenameExtension: "mobileprovision") ?? .data
    ]

    var body: some View {
        NavigationStack {
            Form {
                packageSection
                profileSection
                identitySection
                signSection
                if let outcome = model.outcome {
                    outcomeSection(outcome)
                }
            }
            .navigationTitle(ShellSection.signing.title)
            .disabled(model.activity == .signing)
            .fileImporter(
                isPresented: $isShowingProfilePicker,
                allowedContentTypes: Self.profileContentTypes
            ) { result in
                if case .success(let url) = result {
                    model.chooseProfile(at: url)
                }
            }
        }
    }

    // MARK: Sections

    private var packageSection: some View {
        Section {
            if model.entries.isEmpty {
                Text("No packages with available files. Import one in the Applications area first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Package", selection: $model.selectedEntry) {
                    Text("Choose…")
                        .tag(LibraryEntry?.none)
                    ForEach(model.entries, id: \.self) { entry in
                        Text(Self.displayName(for: entry))
                            .tag(LibraryEntry?.some(entry))
                    }
                }
            }
        } header: {
            Text("Package")
        } footer: {
            Text("The package is read as it sits in the library; signing never modifies the original.")
        }
    }

    private var profileSection: some View {
        Section {
            Button("Choose Provisioning Profile…") {
                isShowingProfilePicker = true
            }
            if let fileName = model.profileFileName {
                LabeledContent("File", value: fileName)
                if let result = model.profileResult {
                    LabeledContent(
                        "Validation",
                        value: result.overallStatus.displayName
                    )
                    if let profile = result.profile {
                        if let name = profile.profileName {
                            LabeledContent("Profile", value: name)
                        }
                        if let expiration = profile.expirationDate {
                            LabeledContent("Expires") {
                                Text(expiration, style: .date)
                            }
                        }
                        if let entitlements = profile.entitlements {
                            LabeledContent(
                                "Entitlement Claims",
                                value: "\(entitlements.values.count)"
                            )
                        }
                    }
                    LabeledContent("CMS Signature") {
                        Text(cmsDescription(for: result))
                    }
                }
                Button("Clear Profile", role: .destructive) {
                    model.clearProfile()
                }
            }
            if let problem = model.profileProblem {
                Text(problem)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Provisioning Profile")
        } footer: {
            Text("Validation covers the profile's container signature, payload, structure, and ZynSign's compatibility rules. It establishes neither trust nor authorization.")
        }
    }

    private var identitySection: some View {
        Section {
            if model.identities.isEmpty {
                Text("No signing identity is registered on this device.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Identity", selection: $model.selectedIdentity) {
                    Text("Choose…")
                        .tag(SigningIdentity?.none)
                    ForEach(model.identities, id: \.self) { identity in
                        Text(Self.displayName(for: identity))
                            .tag(SigningIdentity?.some(identity))
                    }
                }
            }
            Button("Create Development Identity") {
                model.createIdentity()
            }
            .disabled(model.activity == .working || model.activity == .signing)
            if let problem = model.identityProblem {
                Text(problem)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Signing Identity")
        } footer: {
            Text("A development identity is a key generated in this device's Keychain with a self-signed certificate. It carries no Apple chain and no team, and it will not appear inside an Apple-issued profile.")
        }
    }

    private var signSection: some View {
        Section {
            Button {
                model.runSigning()
            } label: {
                HStack {
                    Text("Sign Package")
                    Spacer()
                    if model.activity == .signing {
                        ProgressView()
                    }
                }
            }
            .disabled(!canSign)
        } header: {
            Text("Sign")
        } footer: {
            Text("Signing refuses rather than proceeds with missing or incompatible inputs, and a refused run delivers nothing. The output is a container verified by ZynSign alone; installation is not offered anywhere in this application.")
        }
    }

    private func outcomeSection(_ outcome: SigningModel.Outcome) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(outcome.headline)
                    .font(.headline)
                Text(outcome.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let outputURL = outcome.outputURL {
                    ShareLink(item: outputURL) {
                        Label("Share Signed Container", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Result")
        }
    }

    // MARK: Derived state

    private var canSign: Bool {
        model.activity == .idle
            && model.selectedEntry != nil
            && model.selectedIdentity != nil
            && model.profileData != nil
    }

    private func cmsDescription(
        for result: ProvisioningProfilePipelineResult
    ) -> String {
        // No evidence object means the question was never evaluated; a
        // present one carries a definite verified/unverified answer.
        guard result.verification != nil else {
            return "Not evaluated"
        }
        return result.isProfileAuthenticated ? "Verified" : "Not verified"
    }

    // MARK: Display helpers

    private static func displayName(for entry: LibraryEntry) -> String {
        SigningModel.displayName(for: entry)
    }

    private static func displayName(for identity: SigningIdentity) -> String {
        SigningModel.displayName(for: identity)
    }
}

#Preview {
    let environment = CompositionRoot.makeApplicationEnvironment()
    return SigningView(
        signing: environment.signing,
        library: environment.library
    )
}
