import Foundation

/// The signing options every sideloading tool exposes, in one value.
///
/// Signing a package and editing it are one act, not two. The edits a
/// signing workflow offers — rename the app, drop refused nested code, inject
/// a library — are decisions about *bytes*, not about the pipeline. Keeping
/// them in one validated value means the pipeline does not grow a second code
/// path: the options are resolved into a plan, and the plan is what the engine
/// applies.
///
/// Nothing here reads a file, touches a key, or formats a screen. Validation
/// is about the options themselves, so a refusal names the option and its
/// rule before any package is opened.
struct SideloadSigningOptions: Equatable, Sendable {

    /// Replacement declared identity. `nil` keeps the package's own value.
    var bundleIdentifier: String?
    var displayName: String?
    var name: String?
    var shortVersion: String?
    var version: String?
    var minimumOSVersion: String?

    /// Prefix/suffix and dictionary substring replacements for bundle ID and display name.
    var bundleIdentifierPrefix: String?
    var bundleIdentifierSuffix: String?
    var displayNamePrefix: String?
    var displayNameSuffix: String?
    var identifierReplacements: [String: String]
    var displayNameReplacements: [String: String]

    /// PPQ protection mode (Disabled, Suffix Token, or Stealth Identifier).
    var ppqProtectionMode: PPQProtectionMode
    var ppqProtectionToken: String
    var dynamicPPQProtection: Bool

    /// Nested code and restriction removals before signing.
    var removesPlugIns: Bool
    var removesWatchApps: Bool
    var removesAppExtensions: Bool
    var removesURLSchemes: Bool
    var removesSupportedDevices: Bool
    var removesProvisioningProfile: Bool
    var removedBundlePaths: [String]

    /// Extra entitlements merged over the profile's dictionary, plus keys to drop
    /// or a full raw XML entitlements override when explicitly authored.
    var entitlementOverrides: [String: EntitlementValue]
    var removedEntitlementKeys: [String]
    var rawEntitlementsXMLOverride: String?
    var mergesBinaryEntitlements: Bool
    var isolatesKeychainGroup: Bool

    /// Libraries linked into the main executable (and nested code when asked),
    /// plus existing load commands to strip (Disinject).
    var injectedLibraries: [InjectedLibrary]
    var injectsIntoNestedCode: Bool
    var targetedExtensionNames: [String]
    var disinjectedLibraries: [String]

    /// Tweak payloads staged into `Frameworks` (or `.app` root) and linked into
    /// the main executable, plus structured `.framework` / `.bundle` / `.appex` payloads.
    var tweaks: [SideloadStagedTweak]
    var stagedBundlePayloads: [SideloadStagedBundlePayload]
    var tweakInjectBase: TweakInjectBase
    var tweakInjectFolder: TweakInjectFolder
    var allowsTweakCollisionSuffixing: Bool

    /// Binary & runtime compatibility patches.
    var replacesSubstrateWithElleKit: Bool
    var fixesLegacyArm64eSlice: Bool
    var liquidGlassMode: LiquidGlassPatchMode
    var appearanceOverride: AppAppearanceOverride
    var enablesProMotion: Bool
    var enablesGameMode: Bool
    var enablesIPadFullscreen: Bool
    var enablesITunesFileSharing: Bool
    var localizesDisplayName: Bool

    /// Custom PNG icon override and arbitrary `Info.plist` key/XML overrides.
    var customIconPNGData: Data?
    var customInfoPlistEntries: [String: PlistCustomValue]
    var customInfoPlistRemovals: [String]
    var rawInfoPlistXMLOverride: String?

    /// Execution mode flags.
    var adHoc: Bool
    var hardenedRuntime: Bool
    var enablesFileSharing: Bool
    var onlyModify: Bool
    var deletesImportedAfterSigning: Bool

    static let none = SideloadSigningOptions()

    init(
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        name: String? = nil,
        shortVersion: String? = nil,
        version: String? = nil,
        minimumOSVersion: String? = nil,
        bundleIdentifierPrefix: String? = nil,
        bundleIdentifierSuffix: String? = nil,
        displayNamePrefix: String? = nil,
        displayNameSuffix: String? = nil,
        identifierReplacements: [String: String] = [:],
        displayNameReplacements: [String: String] = [:],
        ppqProtectionMode: PPQProtectionMode = .disabled,
        ppqProtectionToken: String = "",
        dynamicPPQProtection: Bool = false,
        removesPlugIns: Bool = false,
        removesWatchApps: Bool = false,
        removesAppExtensions: Bool = false,
        removesURLSchemes: Bool = false,
        removesSupportedDevices: Bool = false,
        removesProvisioningProfile: Bool = false,
        removedBundlePaths: [String] = [],
        entitlementOverrides: [String: EntitlementValue] = [:],
        removedEntitlementKeys: [String] = [],
        rawEntitlementsXMLOverride: String? = nil,
        mergesBinaryEntitlements: Bool = false,
        isolatesKeychainGroup: Bool = false,
        injectedLibraries: [InjectedLibrary] = [],
        tweaks: [SideloadStagedTweak] = [],
        stagedBundlePayloads: [SideloadStagedBundlePayload] = [],
        tweakInjectBase: TweakInjectBase = .executablePath,
        tweakInjectFolder: TweakInjectFolder = .frameworks,
        allowsTweakCollisionSuffixing: Bool = false,
        injectsIntoNestedCode: Bool = false,
        targetedExtensionNames: [String] = [],
        disinjectedLibraries: [String] = [],
        replacesSubstrateWithElleKit: Bool = false,
        fixesLegacyArm64eSlice: Bool = false,
        liquidGlassMode: LiquidGlassPatchMode = .default,
        appearanceOverride: AppAppearanceOverride = .default,
        enablesProMotion: Bool = false,
        enablesGameMode: Bool = false,
        enablesIPadFullscreen: Bool = false,
        enablesITunesFileSharing: Bool = false,
        localizesDisplayName: Bool = false,
        customIconPNGData: Data? = nil,
        customInfoPlistEntries: [String: PlistCustomValue] = [:],
        customInfoPlistRemovals: [String] = [],
        rawInfoPlistXMLOverride: String? = nil,
        adHoc: Bool = false,
        hardenedRuntime: Bool = false,
        enablesFileSharing: Bool = false,
        onlyModify: Bool = false,
        deletesImportedAfterSigning: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.name = name
        self.shortVersion = shortVersion
        self.version = version
        self.minimumOSVersion = minimumOSVersion
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.bundleIdentifierSuffix = bundleIdentifierSuffix
        self.displayNamePrefix = displayNamePrefix
        self.displayNameSuffix = displayNameSuffix
        self.identifierReplacements = identifierReplacements
        self.displayNameReplacements = displayNameReplacements
        self.ppqProtectionMode = ppqProtectionMode
        self.ppqProtectionToken = ppqProtectionToken
        self.dynamicPPQProtection = dynamicPPQProtection
        self.removesPlugIns = removesPlugIns
        self.removesWatchApps = removesWatchApps
        self.removesAppExtensions = removesAppExtensions
        self.removesURLSchemes = removesURLSchemes
        self.removesSupportedDevices = removesSupportedDevices
        self.removesProvisioningProfile = removesProvisioningProfile
        self.removedBundlePaths = removedBundlePaths
        self.entitlementOverrides = entitlementOverrides
        self.removedEntitlementKeys = removedEntitlementKeys
        self.rawEntitlementsXMLOverride = rawEntitlementsXMLOverride
        self.mergesBinaryEntitlements = mergesBinaryEntitlements
        self.isolatesKeychainGroup = isolatesKeychainGroup
        self.injectedLibraries = injectedLibraries
        self.tweaks = tweaks
        self.stagedBundlePayloads = stagedBundlePayloads
        self.tweakInjectBase = tweakInjectBase
        self.tweakInjectFolder = tweakInjectFolder
        self.allowsTweakCollisionSuffixing = allowsTweakCollisionSuffixing
        self.injectsIntoNestedCode = injectsIntoNestedCode
        self.targetedExtensionNames = targetedExtensionNames
        self.disinjectedLibraries = disinjectedLibraries
        self.replacesSubstrateWithElleKit = replacesSubstrateWithElleKit
        self.fixesLegacyArm64eSlice = fixesLegacyArm64eSlice
        self.liquidGlassMode = liquidGlassMode
        self.appearanceOverride = appearanceOverride
        self.enablesProMotion = enablesProMotion
        self.enablesGameMode = enablesGameMode
        self.enablesIPadFullscreen = enablesIPadFullscreen
        self.enablesITunesFileSharing = enablesITunesFileSharing
        self.localizesDisplayName = localizesDisplayName
        self.customIconPNGData = customIconPNGData
        self.customInfoPlistEntries = customInfoPlistEntries
        self.customInfoPlistRemovals = customInfoPlistRemovals
        self.rawInfoPlistXMLOverride = rawInfoPlistXMLOverride
        self.adHoc = adHoc
        self.hardenedRuntime = hardenedRuntime
        self.enablesFileSharing = enablesFileSharing
        self.onlyModify = onlyModify
        self.deletesImportedAfterSigning = deletesImportedAfterSigning
    }
}

/// A tweak payload the library staged for this package.
struct SideloadStagedTweak: Equatable, Hashable, Sendable {

    /// The file name the payload takes inside `Frameworks`. One path component,
    /// ending in `.dylib`.
    let fileName: String

    /// The payload bytes, exactly as the library stores them.
    let bytes: Data

    init(fileName: String, bytes: Data) {
        self.fileName = fileName
        self.bytes = bytes
    }

    /// The default install name the injected load command carries.
    var installName: String { "@executable_path/Frameworks/\(fileName)" }
}

/// One library linked into a binary's load commands.
struct InjectedLibrary: Equatable, Hashable, Sendable {
    /// The install name written into `LC_LOAD_DYLIB`, e.g.
    /// `@executable_path/Frameworks/Tweak.dylib`.
    let installName: String
    /// `LC_LOAD_WEAK_DYLIB` when the image may be absent at launch.
    let isWeak: Bool

    init(installName: String, isWeak: Bool = false) {
        self.installName = installName
        self.isWeak = isWeak
    }
}

/// A typed entitlement value, kept in the shapes a property list allows so
/// merging cannot silently stringify a boolean.
indirect enum EntitlementValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case data(Data)
    case array([EntitlementValue])
    case dictionary([String: EntitlementValue])
}

/// What is wrong with a set of options. Each case names the field and its
/// rule; none of them is a generic "invalid options".
enum SideloadOptionError: Error, Equatable, Hashable, Sendable {
    case emptyBundleIdentifier
    case malformedBundleIdentifier(String)
    case emptyDisplayName
    case malformedVersion(field: String, value: String)
    case malformedMinimumOS(String)
    case invalidInstallName(String)
    case duplicateInstallName(String)
    case adHocWithCertificate
    case tooManyInjectedLibraries(limit: Int)
    case tooManyStagedTweaks(limit: Int)
    case invalidTweakFileName(String)
    case duplicateTweakFileName(String)
    case emptyTweakPayload(String)
    case stagedTweaksTooLarge(bytes: Int, limit: Int)
    case invalidRawPlistXML(String)

    var message: String {
        switch self {
        case .emptyBundleIdentifier:
            return "A replacement bundle identifier cannot be empty."
        case .malformedBundleIdentifier(let value):
            return "“\(value)” is not a reverse-DNS bundle identifier."
        case .emptyDisplayName:
            return "A replacement display name cannot be empty."
        case .malformedVersion(let field, let value):
            return "\(field) “\(value)” is not a version string (digits and at most two dots)."
        case .malformedMinimumOS(let value):
            return "Minimum OS “\(value)” is not a version string (digits and at most two dots)."
        case .invalidInstallName(let value):
            return "“\(value)” is not an install name (use @executable_path, @rpath, @loader_path, /System or /usr/lib)."
        case .duplicateInstallName(let value):
            return "“\(value)” is injected more than once."
        case .adHocWithCertificate:
            return "An ad-hoc signature cannot be combined with a signing certificate."
        case .tooManyInjectedLibraries(let limit):
            return "Injection is limited to \(limit) libraries per package."
        case .tooManyStagedTweaks(let limit):
            return "A package carries at most \(limit) staged tweaks."
        case .invalidTweakFileName(let name):
            return "“\(name)” is not a tweak file name (one file, ending in .dylib)."
        case .duplicateTweakFileName(let name):
            return "Two staged tweaks are named “\(name)”."
        case .emptyTweakPayload(let name):
            return "The staged tweak “\(name)” carries no bytes."
        case .stagedTweaksTooLarge(let bytes, let limit):
            return "The staged tweaks total \(bytes) bytes; a package carries at most \(limit / (1024 * 1024)) MiB."
        case .invalidRawPlistXML(let field):
            return "The custom \(field) XML is not a valid property list dictionary."
        }
    }
}

extension SideloadSigningOptions {

    static let maximumInjectedLibraries = 16
    static let maximumStagedTweaks = 12
    static let maximumStagedTweakBytes = 64 * 1_024 * 1_024

    static func isTweakFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value.lowercased().hasSuffix(".dylib"),
              !value.contains("/"), !value.contains("\\"),
              !value.hasPrefix("."), value != ".." else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || "-_.+".contains(character))
        }
    }

    var isEmpty: Bool {
        self == SideloadSigningOptions.none
    }

    /// Resolves the effective install name for a staged `.dylib` under this
    /// option set's `tweakInjectBase` and `tweakInjectFolder`.
    func resolvedInstallName(for tweak: SideloadStagedTweak) -> String {
        tweakInjectFolder.installName(base: tweakInjectBase, fileName: tweak.fileName)
    }

    /// Resolves the effective bundle identifier for `originalBundleID`.
    func resolvedBundleIdentifier(originalBundleID: String) -> String? {
        let hasIdentifierChanges = bundleIdentifier != nil
            || !(bundleIdentifierPrefix ?? "").isEmpty
            || !(bundleIdentifierSuffix ?? "").isEmpty
            || !identifierReplacements.isEmpty
            || ppqProtectionMode != .disabled
        guard hasIdentifierChanges else { return nil }
        return PPQProtectionPolicy.resolveBundleIdentifier(
            original: originalBundleID,
            explicitReplacement: bundleIdentifier,
            prefix: bundleIdentifierPrefix,
            suffix: bundleIdentifierSuffix,
            replacements: identifierReplacements,
            ppqMode: ppqProtectionMode,
            ppqToken: ppqProtectionToken,
            dynamicProtection: dynamicPPQProtection
        )
    }

    /// Validate every field before a package is opened.
    func validate(hasCertificate: Bool) throws {
        try validateIdentityFields()
        try validateInjectionAndTweaks()
        try validateCustomXMLOverrides()
        if adHoc && hasCertificate && !onlyModify {
            throw SideloadOptionError.adHocWithCertificate
        }
    }

    private func validateIdentityFields() throws {
        if let identifier = bundleIdentifier {
            if identifier.isEmpty { throw SideloadOptionError.emptyBundleIdentifier }
            guard Self.isReverseDNS(identifier) else {
                throw SideloadOptionError.malformedBundleIdentifier(identifier)
            }
        }
        if let displayName, displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SideloadOptionError.emptyDisplayName
        }
        if let shortVersion, !Self.isVersionString(shortVersion) {
            throw SideloadOptionError.malformedVersion(field: "Version", value: shortVersion)
        }
        if let version, !Self.isVersionString(version) {
            throw SideloadOptionError.malformedVersion(field: "Build", value: version)
        }
        if let minimumOSVersion, !Self.isVersionString(minimumOSVersion) {
            throw SideloadOptionError.malformedMinimumOS(minimumOSVersion)
        }
    }

    private func validateInjectionAndTweaks() throws {
        guard injectedLibraries.count <= Self.maximumInjectedLibraries else {
            throw SideloadOptionError.tooManyInjectedLibraries(
                limit: Self.maximumInjectedLibraries)
        }
        var seen: Set<String> = []
        for library in injectedLibraries {
            guard Self.isInstallName(library.installName) else {
                throw SideloadOptionError.invalidInstallName(library.installName)
            }
            guard seen.insert(library.installName).inserted else {
                throw SideloadOptionError.duplicateInstallName(library.installName)
            }
        }
        let totalTweakItems = tweaks.count + stagedBundlePayloads.count
        guard totalTweakItems <= Self.maximumStagedTweaks else {
            throw SideloadOptionError.tooManyStagedTweaks(limit: Self.maximumStagedTweaks)
        }
        var tweakBytes = stagedBundlePayloads.reduce(0) { $0 + $1.totalBytes }
        var seenTweaks: Set<String> = []
        for tweak in tweaks {
            guard Self.isTweakFileName(tweak.fileName) else {
                throw SideloadOptionError.invalidTweakFileName(tweak.fileName)
            }
            guard !tweak.bytes.isEmpty else {
                throw SideloadOptionError.emptyTweakPayload(tweak.fileName)
            }
            tweakBytes += tweak.bytes.count
            let targetInstallName = resolvedInstallName(for: tweak)
            guard !seen.contains(targetInstallName) else {
                throw SideloadOptionError.duplicateInstallName(targetInstallName)
            }
            if !allowsTweakCollisionSuffixing {
                guard seenTweaks.insert(targetInstallName).inserted else {
                    throw SideloadOptionError.duplicateTweakFileName(tweak.fileName)
                }
            }
        }
        guard tweakBytes <= Self.maximumStagedTweakBytes else {
            throw SideloadOptionError.stagedTweaksTooLarge(
                bytes: tweakBytes, limit: Self.maximumStagedTweakBytes)
        }
    }

    private func validateCustomXMLOverrides() throws {
        if let xml = rawInfoPlistXMLOverride, !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard (try? PlistDocumentCodec.parseXML(xml)) != nil else {
                throw SideloadOptionError.invalidRawPlistXML("Info.plist")
            }
        }
        if let xml = rawEntitlementsXMLOverride, !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard (try? PlistDocumentCodec.parseXML(xml)) != nil else {
                throw SideloadOptionError.invalidRawPlistXML("Entitlements")
            }
        }
    }

    static func isReverseDNS(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, value.count <= 155 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 63 && part.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    static func isVersionString(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), value.count <= 32 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 10 && part.allSatisfy { $0.isNumber }
        }
    }

    static func isInstallName(_ value: String) -> Bool {
        let prefixes = ["@executable_path/", "@rpath/", "@loader_path/", "/System/", "/usr/lib/"]
        guard !value.isEmpty, value.count <= 1_024,
              !value.contains(".."), !value.contains("\0") else { return false }
        return prefixes.contains { value.hasPrefix($0) }
    }
}

/// What the pipeline will do to one Info.plist, derived from the options.
struct InfoPlistOverridePlan: Equatable, Sendable {
    let values: [String: PlistSetting]
    let keysToRemove: [String]

    enum PlistSetting: Equatable, Sendable {
        case string(String)
        case boolean(Bool)
        case integer(Int)
    }

    var isEmpty: Bool { values.isEmpty && keysToRemove.isEmpty }
}

enum InfoPlistOverrides {

    /// Main application: identity plus runtime flags and keys the user asked to drop.
    static func mainApplicationPlan(
        _ options: SideloadSigningOptions,
        originalBundleIdentifier: String = "",
        originalDisplayName: String = ""
    ) -> InfoPlistOverridePlan {
        var values: [String: InfoPlistOverridePlan.PlistSetting] = [:]
        if let resolvedID = options.resolvedBundleIdentifier(originalBundleID: originalBundleIdentifier) {
            values["CFBundleIdentifier"] = .string(resolvedID)
        }
        if let resolvedDisplay = PPQProtectionPolicy.resolveDisplayName(
            original: originalDisplayName,
            explicitReplacement: options.displayName,
            prefix: options.displayNamePrefix,
            suffix: options.displayNameSuffix,
            replacements: options.displayNameReplacements
        ) {
            values["CFBundleDisplayName"] = .string(resolvedDisplay)
        }
        if let name = options.name {
            values["CFBundleName"] = .string(name)
        }
        if let shortVersion = options.shortVersion {
            values["CFBundleShortVersionString"] = .string(shortVersion)
        }
        if let version = options.version {
            values["CFBundleVersion"] = .string(version)
        }
        if let minimumOSVersion = options.minimumOSVersion {
            values["MinimumOSVersion"] = .string(minimumOSVersion)
        }
        if options.enablesFileSharing {
            values["UIFileSharingEnabled"] = .boolean(true)
            values["LSSupportsOpeningDocumentsInPlace"] = .boolean(true)
        } else if options.enablesITunesFileSharing {
            values["UIFileSharingEnabled"] = .boolean(true)
        }
        if options.enablesProMotion {
            values["CADisableMinimumFrameDurationOnPhone"] = .boolean(true)
        }
        if options.enablesGameMode {
            values["GCSupportsGameMode"] = .boolean(true)
        }
        if options.enablesIPadFullscreen {
            values["UIRequiresFullScreen"] = .boolean(true)
        }
        if let style = options.appearanceOverride.plistValue {
            values["UIUserInterfaceStyle"] = .string(style)
        }
        var removed: [String] = []
        if options.removesURLSchemes {
            removed.append(contentsOf: ["CFBundleURLTypes", "LSApplicationQueriesSchemes"])
        }
        if options.removesSupportedDevices {
            removed.append("UISupportedDevices")
        }
        switch options.liquidGlassMode {
        case .default:
            break
        case .disable:
            values["UIDesignRequiresCompatibility"] = .boolean(true)
        case .enable:
            removed.append("UIDesignRequiresCompatibility")
        }
        return InfoPlistOverridePlan(values: values, keysToRemove: removed)
    }

    static func extensionIdentifier(oldIdentifier: String,
                                    oldParentIdentifier: String,
                                    newParentIdentifier: String) -> String? {
        let prefix = oldParentIdentifier + "."
        guard oldIdentifier.hasPrefix(prefix) else { return nil }
        return newParentIdentifier + oldIdentifier.dropFirst(oldParentIdentifier.count)
    }
}
