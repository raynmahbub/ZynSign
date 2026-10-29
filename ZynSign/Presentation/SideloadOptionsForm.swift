import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The editable state behind `SideloadOptionsForm`.
struct SideloadOptionsDraft: Equatable {

    var bundleIdentifier = ""
    var displayName = ""
    var name = ""
    var shortVersion = ""
    var version = ""
    var minimumOSVersion = ""

    var bundleIdentifierPrefix = ""
    var bundleIdentifierSuffix = ""
    var displayNamePrefix = ""
    var displayNameSuffix = ""
    var identifierReplacements: [String: String] = [:]
    var displayNameReplacements: [String: String] = [:]

    var ppqProtectionMode: PPQProtectionMode = .disabled
    var ppqProtectionToken = ""
    var dynamicPPQProtection = false

    var removesPlugIns = false
    var removesWatchApps = false
    var removesAppExtensions = false
    var removesURLSchemes = false
    var removesSupportedDevices = false
    var removesProvisioningProfile = false
    var removedBundlePaths: [String] = []
    var removedPathField = ""

    var entitlementOverrides: [String: EntitlementValue] = [:]
    var removedEntitlementKeys: [String] = []
    var rawEntitlementsXMLOverride = ""
    var mergesBinaryEntitlements = false
    var isolatesKeychainGroup = false

    var libraries: [String] = []
    var libraryField = ""
    var disinjectedLibraries: [String] = []
    var disinjectField = ""
    var injectsIntoNestedCode = false
    var targetedExtensionNames: [String] = []
    var extensionTargetField = ""

    var tweakInjectBase: TweakInjectBase = .executablePath
    var tweakInjectFolder: TweakInjectFolder = .frameworks
    var allowsTweakCollisionSuffixing = true
    var replacesSubstrateWithElleKit = false
    var fixesLegacyArm64eSlice = false

    var liquidGlassMode: LiquidGlassPatchMode = .default
    var appearanceOverride: AppAppearanceOverride = .default
    var enablesProMotion = false
    var enablesGameMode = false
    var enablesIPadFullscreen = false
    var enablesITunesFileSharing = false
    var localizesDisplayName = false

    var customIconPNGData: Data?
    var customIconName: String?
    var customInfoPlistEntries: [String: PlistCustomValue] = [:]
    var customInfoPlistRemovals: [String] = []
    var rawInfoPlistXMLOverride = ""

    var adHoc = false
    var hardenedRuntime = false
    var enablesFileSharing = false
    var onlyModify = false
    var deletesImportedAfterSigning = false

    var isEdited: Bool { options != SideloadSigningOptions.none }

    var editCount: Int {
        let opts = self.options
        var count = 0
        if opts.bundleIdentifier != nil { count += 1 }
        if opts.displayName != nil { count += 1 }
        if opts.name != nil { count += 1 }
        if opts.shortVersion != nil { count += 1 }
        if opts.version != nil { count += 1 }
        if opts.minimumOSVersion != nil { count += 1 }
        if opts.bundleIdentifierPrefix != nil || opts.bundleIdentifierSuffix != nil { count += 1 }
        if opts.displayNamePrefix != nil || opts.displayNameSuffix != nil { count += 1 }
        if opts.ppqProtectionMode != .disabled { count += 1 }
        if opts.removesPlugIns { count += 1 }
        if opts.removesWatchApps { count += 1 }
        if opts.removesAppExtensions { count += 1 }
        if opts.removesURLSchemes { count += 1 }
        if opts.removesSupportedDevices { count += 1 }
        if opts.removesProvisioningProfile { count += 1 }
        count += opts.removedBundlePaths.count
        count += opts.injectedLibraries.count
        count += opts.disinjectedLibraries.count
        if opts.mergesBinaryEntitlements { count += 1 }
        if opts.isolatesKeychainGroup { count += 1 }
        if opts.replacesSubstrateWithElleKit { count += 1 }
        if opts.fixesLegacyArm64eSlice { count += 1 }
        if opts.liquidGlassMode != .default { count += 1 }
        if opts.appearanceOverride != .default { count += 1 }
        if opts.enablesProMotion { count += 1 }
        if opts.enablesGameMode { count += 1 }
        if opts.enablesIPadFullscreen { count += 1 }
        if opts.localizesDisplayName { count += 1 }
        if opts.customIconPNGData != nil { count += 1 }
        if !opts.customInfoPlistEntries.isEmpty || opts.rawInfoPlistXMLOverride != nil { count += 1 }
        if !opts.entitlementOverrides.isEmpty || opts.rawEntitlementsXMLOverride != nil { count += 1 }
        if opts.adHoc { count += 1 }
        if opts.hardenedRuntime { count += 1 }
        if opts.enablesFileSharing || opts.enablesITunesFileSharing { count += 1 }
        if opts.onlyModify { count += 1 }
        return count
    }

    var options: SideloadSigningOptions {
        SideloadSigningOptions(
            bundleIdentifier: Self.normalised(bundleIdentifier),
            displayName: Self.normalised(displayName),
            name: Self.normalised(name),
            shortVersion: Self.normalised(shortVersion),
            version: Self.normalised(version),
            minimumOSVersion: Self.normalised(minimumOSVersion),
            bundleIdentifierPrefix: Self.normalised(bundleIdentifierPrefix),
            bundleIdentifierSuffix: Self.normalised(bundleIdentifierSuffix),
            displayNamePrefix: Self.normalised(displayNamePrefix),
            displayNameSuffix: Self.normalised(displayNameSuffix),
            identifierReplacements: identifierReplacements,
            displayNameReplacements: displayNameReplacements,
            ppqProtectionMode: ppqProtectionMode,
            ppqProtectionToken: ppqProtectionMode == .disabled ? "" : ppqProtectionToken,
            dynamicPPQProtection: ppqProtectionMode == .disabled ? false : dynamicPPQProtection,
            removesPlugIns: removesPlugIns,
            removesWatchApps: removesWatchApps,
            removesAppExtensions: removesAppExtensions,
            removesURLSchemes: removesURLSchemes,
            removesSupportedDevices: removesSupportedDevices,
            removesProvisioningProfile: removesProvisioningProfile,
            removedBundlePaths: removedBundlePaths,
            entitlementOverrides: entitlementOverrides,
            removedEntitlementKeys: removedEntitlementKeys,
            rawEntitlementsXMLOverride: Self.normalised(rawEntitlementsXMLOverride),
            mergesBinaryEntitlements: mergesBinaryEntitlements,
            isolatesKeychainGroup: isolatesKeychainGroup,
            injectedLibraries: libraries.map { InjectedLibrary(installName: $0) },
            tweaks: [],
            stagedBundlePayloads: [],
            tweakInjectBase: tweakInjectBase,
            tweakInjectFolder: tweakInjectFolder,
            allowsTweakCollisionSuffixing: allowsTweakCollisionSuffixing,
            injectsIntoNestedCode: injectsIntoNestedCode,
            targetedExtensionNames: targetedExtensionNames,
            disinjectedLibraries: disinjectedLibraries,
            replacesSubstrateWithElleKit: replacesSubstrateWithElleKit,
            fixesLegacyArm64eSlice: fixesLegacyArm64eSlice,
            liquidGlassMode: liquidGlassMode,
            appearanceOverride: appearanceOverride,
            enablesProMotion: enablesProMotion,
            enablesGameMode: enablesGameMode,
            enablesIPadFullscreen: enablesIPadFullscreen,
            enablesITunesFileSharing: enablesITunesFileSharing,
            localizesDisplayName: localizesDisplayName,
            customIconPNGData: customIconPNGData,
            customInfoPlistEntries: customInfoPlistEntries,
            customInfoPlistRemovals: customInfoPlistRemovals,
            rawInfoPlistXMLOverride: Self.normalised(rawInfoPlistXMLOverride),
            adHoc: adHoc,
            hardenedRuntime: hardenedRuntime,
            enablesFileSharing: enablesFileSharing,
            onlyModify: onlyModify,
            deletesImportedAfterSigning: deletesImportedAfterSigning
        )
    }

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

    mutating func addLibrary() {
        let candidate = libraryField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !libraries.contains(candidate) else { return }
        libraries.append(candidate)
        libraryField = ""
    }

    mutating func removeLibrary(_ installName: String) {
        libraries.removeAll { $0 == installName }
    }

    mutating func configureAppClone(cloneLabel: String = "2") {
        let token = PPQProtectionPolicy.generateToken(length: 4)
        bundleIdentifierSuffix = "clone\(cloneLabel)\(token)"
        displayNameSuffix = " \(cloneLabel)"
        isolatesKeychainGroup = true
    }

    private static func normalised(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The package edits a sideloading tool offers, as a form.
struct SideloadOptionsForm: View {

    @Binding var draft: SideloadOptionsDraft
    let hasCertificate: Bool
    var profileSuggestedBundleID: String? = nil

    @State private var showInfoPlistEditor = false
    @State private var showEntitlementsEditor = false
    @State private var showIconImporter = false
    @State private var idReplaceOld = ""
    @State private var idReplaceNew = ""

    var body: some View {
        Group {
            quickPresetsSection
            identitySection
            ppqProtectionSection
            appearanceAndGlassSection
            removalSection
            injectionAndBinarySection
            advancedPlistAndEntitlementsSection
            signatureSection
            if let problem = draft.problem(hasCertificate: hasCertificate) {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .sheet(isPresented: $showInfoPlistEditor) {
            SigningInfoPlistOverridesSheet(draft: $draft)
        }
        .sheet(isPresented: $showEntitlementsEditor) {
            SigningEntitlementsOverridesSheet(draft: $draft)
        }
        .fileImporter(
            isPresented: $showIconImporter,
            allowedContentTypes: [.png, .jpeg, .image]
        ) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let raw = try? Data(contentsOf: url), !raw.isEmpty {
                    #if canImport(UIKit)
                    if let uiImage = UIImage(data: raw), let png = uiImage.pngData() {
                        draft.customIconPNGData = png
                    } else {
                        draft.customIconPNGData = raw
                    }
                    #else
                    draft.customIconPNGData = raw
                    #endif
                    draft.customIconName = url.lastPathComponent
                }
            }
        }
    }

    // MARK: - Sections

    private var quickPresetsSection: some View {
        Section {
            Toggle("Only Modify (Repackage Without Signing)", isOn: $draft.onlyModify)
            Button {
                ZHaptics.tap()
                draft.configureAppClone()
            } label: {
                Label("Configure Side-by-Side App Clone", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if let suggested = profileSuggestedBundleID, !suggested.isEmpty {
                Button {
                    ZHaptics.tap()
                    draft.bundleIdentifier = suggested
                } label: {
                    Label("Use Profile Bundle ID (\(suggested))", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        } header: {
            Text("Workflow Mode & Quick Actions")
        } footer: {
            Text("Only Modify edits Info.plist, icons, removals, and tweaks and rebuilds an unsigned .ipa. App Clone appends a unique bundle suffix and isolates Keychain storage.")
        }
    }

    private var identitySection: some View {
        Section {
            field("Bundle identifier", text: $draft.bundleIdentifier, prompt: "com.example.app", keyboard: .URL)
            field("Bundle ID prefix", text: $draft.bundleIdentifierPrefix, prompt: "dev", keyboard: .URL)
            field("Bundle ID suffix", text: $draft.bundleIdentifierSuffix, prompt: "alt", keyboard: .URL)
            field("Display name", text: $draft.displayName, prompt: "App Name")
            field("Display prefix", text: $draft.displayNamePrefix, prompt: "")
            field("Display suffix", text: $draft.displayNameSuffix, prompt: " +")
            field("Name", text: $draft.name, prompt: "App")
            field("Version", text: $draft.shortVersion, prompt: "1.0", keyboard: .decimalPad)
            field("Build", text: $draft.version, prompt: "1", keyboard: .numberPad)
            HStack {
                field("Minimum iOS", text: $draft.minimumOSVersion, prompt: "14.0", keyboard: .decimalPad)
                Menu {
                    ForEach(["12.0", "13.0", "14.0", "15.0", "16.0", "17.0"], id: \.self) { ver in
                        Button("iOS \(ver)") { draft.minimumOSVersion = ver }
                    }
                    Button("Keep Original") { draft.minimumOSVersion = "" }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .frame(width: 44, height: 44)
                }
            }
            Toggle("Force localize custom display name (.lproj)", isOn: $draft.localizesDisplayName)
            HStack(spacing: ZSpacing.sm) {
                Button {
                    showIconImporter = true
                } label: {
                    Label(draft.customIconName ?? "Choose Custom App Icon…", systemImage: "app.badge")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if draft.customIconPNGData != nil {
                    Button(role: .destructive) {
                        draft.customIconPNGData = nil
                        draft.customIconName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Identity & Icon")
        } footer: {
            Text("Leave a field empty to keep the package's own value. Force Localize updates *.lproj/InfoPlist.strings so localized springboard labels match your custom display name.")
        }
    }

    private var ppqProtectionSection: some View {
        Section {
            Picker("PPQ Protection", selection: $draft.ppqProtectionMode) {
                ForEach(PPQProtectionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if draft.ppqProtectionMode != .disabled {
                HStack(spacing: ZSpacing.sm) {
                    TextField("6-char token", text: $draft.ppqProtectionToken)
                        .font(ZTypography.codeCaption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Randomize") {
                        draft.ppqProtectionToken = PPQProtectionPolicy.generateToken()
                    }
                    .frame(minHeight: 44)
                }
                Toggle("Dynamic Protection", isOn: $draft.dynamicPPQProtection)
            }
        } header: {
            Text("PPQ Bundle ID Protection")
        } footer: {
            Text(draft.ppqProtectionMode.summary)
        }
        .onChange(of: draft.ppqProtectionMode) { _, newValue in
            if newValue != .disabled, draft.ppqProtectionToken.isEmpty {
                draft.ppqProtectionToken = PPQProtectionPolicy.generateToken()
            }
        }
    }

    private var appearanceAndGlassSection: some View {
        Section {
            Picker("App Appearance", selection: $draft.appearanceOverride) {
                ForEach(AppAppearanceOverride.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Liquid Glass Patch", selection: $draft.liquidGlassMode) {
                ForEach(LiquidGlassPatchMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Enable ProMotion (120Hz)", isOn: $draft.enablesProMotion)
            Toggle("Enable Game Mode", isOn: $draft.enablesGameMode)
            Toggle("Force iPad Fullscreen", isOn: $draft.enablesIPadFullscreen)
            Toggle("Show in Files App & Open in Place", isOn: $draft.enablesFileSharing)
            Toggle("iTunes File Sharing Only", isOn: $draft.enablesITunesFileSharing)
        } header: {
            Text("Runtime, Display & Liquid Glass")
        } footer: {
            Text("Liquid Glass Enable strips UIDesignRequiresCompatibility and upgrades Mach-O LC_BUILD_VERSION to SDK 26.0; Disable forces compatibility metrics on iOS 26+.")
        }
    }

    private var removalSection: some View {
        Section {
            Toggle("Remove app extensions", isOn: $draft.removesAppExtensions)
            Toggle("Remove plug-ins", isOn: $draft.removesPlugIns)
            Toggle("Remove watch app", isOn: $draft.removesWatchApps)
            Toggle("Remove URL schemes", isOn: $draft.removesURLSchemes)
            Toggle("Remove UISupportedDevices restriction", isOn: $draft.removesSupportedDevices)
            Toggle("Omit embedded.mobileprovision", isOn: $draft.removesProvisioningProfile)
            ForEach(draft.removedBundlePaths, id: \.self) { relPath in
                HStack {
                    Text(relPath).font(ZTypography.codeCaption)
                    Spacer()
                    Button {
                        draft.removedBundlePaths.removeAll { $0 == relPath }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: ZSpacing.sm) {
                TextField("Bundle path to remove (e.g. Frameworks/Ads.framework)", text: $draft.removedPathField)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let clean = draft.removedPathField.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty, !draft.removedBundlePaths.contains(clean) {
                        draft.removedBundlePaths.append(clean)
                        draft.removedPathField = ""
                    }
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Removals & Device Restrictions")
        } footer: {
            Text("Removals execute before resource sealing and code signing so the sealed manifest matches the final bundle.")
        }
    }

    private var injectionAndBinarySection: some View {
        Section {
            Picker("Tweak Inject Path", selection: $draft.tweakInjectBase) {
                ForEach(TweakInjectBase.allCases, id: \.self) { base in
                    Text(base.title).tag(base)
                }
            }
            Picker("Tweak Destination", selection: $draft.tweakInjectFolder) {
                ForEach(TweakInjectFolder.allCases, id: \.self) { folder in
                    Text(folder.title).tag(folder)
                }
            }
            Toggle("Replace CydiaSubstrate with ElleKit (@rpath)", isOn: $draft.replacesSubstrateWithElleKit)
            Toggle("Fix Legacy arm64e Slice (iOS 26+ ABI)", isOn: $draft.fixesLegacyArm64eSlice)
            Toggle("Auto-Suffix Duplicate Dylib Names (-2, -3)", isOn: $draft.allowsTweakCollisionSuffixing)
            Toggle("Also inject into nested extensions", isOn: $draft.injectsIntoNestedCode)

            ForEach(draft.libraries, id: \.self) { installName in
                HStack {
                    Text(installName).font(ZTypography.codeCaption)
                    Spacer()
                    Button {
                        draft.removeLibrary(installName)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(installName)")
                }
            }
            HStack(spacing: ZSpacing.sm) {
                TextField("@executable_path/Frameworks/Tweak.dylib", text: $draft.libraryField)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") { draft.addLibrary() }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .disabled(draft.libraryField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ForEach(draft.disinjectedLibraries, id: \.self) { target in
                HStack {
                    Label(target, systemImage: "scissors")
                        .font(ZTypography.codeCaption)
                    Spacer()
                    Button {
                        draft.disinjectedLibraries.removeAll { $0 == target }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: ZSpacing.sm) {
                TextField("Disinject dylib name or load path", text: $draft.disinjectField)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Strip") {
                    let clean = draft.disinjectField.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty, !draft.disinjectedLibraries.contains(clean) {
                        draft.disinjectedLibraries.append(clean)
                        draft.disinjectField = ""
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        } header: {
            Text("Tweak Injection & Mach-O Patching")
        } footer: {
            Text("Configure dyld load-command base path, ElleKit CydiaSubstrate @rpath rewriting, legacy arm64e capability fixups, and load-command stripping.")
        }
    }

    private var advancedPlistAndEntitlementsSection: some View {
        Section("Info.plist, Entitlements & Replacements") {
            Toggle("Merge Binary Entitlements", isOn: $draft.mergesBinaryEntitlements)
            Toggle("Isolate Keychain Group", isOn: $draft.isolatesKeychainGroup)
            Button {
                showInfoPlistEditor = true
            } label: {
                HStack {
                    Label("Info.plist Visual & XML Editor", systemImage: "doc.badge.gearshape")
                    Spacer()
                    if !draft.customInfoPlistEntries.isEmpty || !draft.rawInfoPlistXMLOverride.isEmpty {
                        Text("Active")
                            .font(ZTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(ZTypography.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            Button {
                showEntitlementsEditor = true
            } label: {
                HStack {
                    Label("Entitlements Override Editor", systemImage: "key.viewfinder")
                    Spacer()
                    if !draft.entitlementOverrides.isEmpty || !draft.rawEntitlementsXMLOverride.isEmpty {
                        Text("Active")
                            .font(ZTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(ZTypography.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            ForEach(draft.identifierReplacements.keys.sorted(), id: \.self) { src in
                HStack {
                    Text("\(src) → \(draft.identifierReplacements[src] ?? "")")
                        .font(ZTypography.codeCaption)
                    Spacer()
                    Button {
                        draft.identifierReplacements.removeValue(forKey: src)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: ZSpacing.xs) {
                TextField("Find ID part", text: $idReplaceOld)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Replace", text: $idReplaceNew)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Map") {
                    let k = idReplaceOld.trimmingCharacters(in: .whitespacesAndNewlines)
                    let v = idReplaceNew.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !k.isEmpty {
                        draft.identifierReplacements[k] = v
                        idReplaceOld = ""
                        idReplaceNew = ""
                    }
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var signatureSection: some View {
        Section {
            Toggle("Ad-hoc signature", isOn: $draft.adHoc)
            Toggle("Hardened runtime", isOn: $draft.hardenedRuntime)
            Toggle("Delete imported source app after signing", isOn: $draft.deletesImportedAfterSigning)
        } header: {
            Text("Signature & Post-Signing")
        } footer: {
            Text(hasCertificate
                 ? "Ad-hoc writes CS_ADHOC and no CMS blob; a stock device does not install an ad-hoc package, which is what guest containers use."
                 : "No certificate is selected, so this run signs ad-hoc — the same signature a guest container needs.")
        }
    }

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
