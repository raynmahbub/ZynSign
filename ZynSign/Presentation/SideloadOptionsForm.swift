import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The editable state behind `SideloadOptionsForm`.
///
/// Every field is text or a switch, because that is what a person types and
/// toggles; the conversion to `SideloadSigningOptions` is where empties become
/// `nil` and whitespace is trimmed. Validation is delegated to the domain
/// value, so the form refuses with the same sentences the signing pipeline
/// would use — there is no second set of rules to drift.
struct SideloadOptionsDraft: Equatable {

    var bundleIdentifier = ""
    var displayName = ""
    var name = ""
    var shortVersion = ""
    var version = ""
    var minimumOSVersion = ""

    var removesPlugIns = false
    var removesWatchApps = false
    var removesAppExtensions = false
    var removesURLSchemes = false

    var injectsIntoNestedCode = false
    var adHoc = false
    var hardenedRuntime = false
    var enablesFileSharing = false

    /// Libraries staged for injection, as the user typed them.
    var libraries: [String] = []

    /// A new install name being typed.
    var libraryField = ""

    /// Whether the draft would change a package.
    ///
    /// The comparison is over the options the draft produces, so a field
    /// holding nothing but spaces is not an edit: it means "keep the
    /// package's value", which is what the run would do.
    var isEdited: Bool { options != SideloadSigningOptions.none }

    /// How many edits are switched on, for the summary row.
    var editCount: Int {
        let options = self.options
        var count = 0
        if options.bundleIdentifier != nil { count += 1 }
        if options.displayName != nil { count += 1 }
        if options.name != nil { count += 1 }
        if options.shortVersion != nil { count += 1 }
        if options.version != nil { count += 1 }
        if options.minimumOSVersion != nil { count += 1 }
        if options.removesPlugIns { count += 1 }
        if options.removesWatchApps { count += 1 }
        if options.removesAppExtensions { count += 1 }
        if options.removesURLSchemes { count += 1 }
        count += options.injectedLibraries.count
        if options.adHoc { count += 1 }
        if options.hardenedRuntime { count += 1 }
        if options.enablesFileSharing { count += 1 }
        if !options.tweaks.isEmpty { count += options.tweaks.count }
        return count
    }

    /// The domain value, with empty text fields read as "keep the package's".
    var options: SideloadSigningOptions {
        SideloadSigningOptions(
            bundleIdentifier: Self.normalised(bundleIdentifier),
            displayName: Self.normalised(displayName),
            name: Self.normalised(name),
            shortVersion: Self.normalised(shortVersion),
            version: Self.normalised(version),
            minimumOSVersion: Self.normalised(minimumOSVersion),
            removesPlugIns: removesPlugIns,
            removesWatchApps: removesWatchApps,
            removesAppExtensions: removesAppExtensions,
            removesURLSchemes: removesURLSchemes,
            entitlementOverrides: [:],
            injectedLibraries: libraries.map { InjectedLibrary(installName: $0) },
            injectsIntoNestedCode: injectsIntoNestedCode,
            adHoc: adHoc,
            hardenedRuntime: hardenedRuntime,
            enablesFileSharing: enablesFileSharing
        )
    }

    /// The first thing wrong with the draft, if anything.
    ///
    /// `hasCertificate` decides whether an ad-hoc request conflicts with the
    /// chosen identity; the caller knows that, the draft does not.
    func problem(hasCertificate: Bool) -> String? {
        do {
            try options.validate(hasCertificate: hasCertificate)
            return nil
        } catch let error as SideloadOptionError {
            return error.message
        } catch {
            return "These edits cannot be applied to a package."
        }
    }

    /// Adds the typed install name, refusing a duplicate rather than letting
    /// the domain value reject the whole set later.
    mutating func addLibrary() {
        let candidate = libraryField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !libraries.contains(candidate) else { return }
        libraries.append(candidate)
        libraryField = ""
    }

    mutating func removeLibrary(_ installName: String) {
        libraries.removeAll { $0 == installName }
    }

    private static func normalised(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The package edits a sideloading tool offers, as a form.
///
/// It is deliberately a plain `View` over a binding: the signing screen owns
/// the draft, so an edit survives a re-render and the same form can be used
/// from the sideloading screen later without a second model.
struct SideloadOptionsForm: View {

    @Binding var draft: SideloadOptionsDraft

    /// Whether the run has a certificate. An ad-hoc request and a certificate
    /// are mutually exclusive, and only the caller knows which it has.
    let hasCertificate: Bool

    var body: some View {
        Group {
            identitySection
            removalSection
            injectionSection
            signatureSection
            if let problem = draft.problem(hasCertificate: hasCertificate) {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            field("Bundle identifier", text: $draft.bundleIdentifier,
                  prompt: "com.example.app", keyboard: .URL)
            field("Display name", text: $draft.displayName, prompt: "App Name")
            field("Name", text: $draft.name, prompt: "App")
            field("Version", text: $draft.shortVersion, prompt: "1.0", keyboard: .decimalPad)
            field("Build", text: $draft.version, prompt: "1", keyboard: .numberPad)
            field("Minimum iOS", text: $draft.minimumOSVersion, prompt: "14.0", keyboard: .decimalPad)
        } header: {
            Text("Identity")
        } footer: {
            Text("Leave a field empty to keep the package's own value. A renamed app carries its extensions with it, and the provisioning profile must cover the new identifier.")
        }
    }

    private var removalSection: some View {
        Section {
            Toggle("Remove app extensions", isOn: $draft.removesAppExtensions)
            Toggle("Remove plug-ins", isOn: $draft.removesPlugIns)
            Toggle("Remove watch app", isOn: $draft.removesWatchApps)
            Toggle("Remove URL schemes", isOn: $draft.removesURLSchemes)
        } header: {
            Text("Nested code")
        } footer: {
            Text("Removals happen before anything is signed, so the signature covers what is left. A watch app cannot run inside an iOS process, and an extension needs its own profile.")
        }
    }

    private var injectionSection: some View {
        Section {
            ForEach(draft.libraries, id: \.self) { installName in
                HStack {
                    Text(installName).font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Button {
                        draft.removeLibrary(installName)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(installName)")
                }
            }
            HStack {
                TextField("@executable_path/Frameworks/Tweak.dylib", text: $draft.libraryField)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") { draft.addLibrary() }
                    .buttonStyle(.borderless)
                    .disabled(draft.libraryField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !draft.libraries.isEmpty {
                Toggle("Also inject into nested code", isOn: $draft.injectsIntoNestedCode)
            }
        } header: {
            Text("Injected libraries")
        } footer: {
            Text("Each library becomes an LC_LOAD_DYLIB in the main executable, written into header padding the binary already has. An image without room is refused rather than patched past its first section.")
        }
    }

    private var signatureSection: some View {
        Section {
            Toggle("Ad-hoc signature", isOn: $draft.adHoc)
                .disabled(!hasCertificate ? false : false)
            Toggle("Hardened runtime", isOn: $draft.hardenedRuntime)
            Toggle("Show in the Files app", isOn: $draft.enablesFileSharing)
        } header: {
            Text("Signature")
        } footer: {
            Text(hasCertificate
                 ? "Ad-hoc writes CS_ADHOC and no CMS blob; a stock device does not install an ad-hoc package, which is what guest containers use."
                 : "No certificate is selected, so this run signs ad-hoc — the same signature a guest container needs.")
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private func field(
        _ title: String,
        text: Binding<String>,
        prompt: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

#Preview("Package edits") {
    Form {
        SideloadOptionsForm(draft: .constant(SideloadOptionsDraft()), hasCertificate: true)
    }
}
