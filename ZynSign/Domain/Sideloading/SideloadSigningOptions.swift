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

    /// Nested code the user asked to drop before signing.
    var removesPlugIns: Bool
    var removesWatchApps: Bool
    var removesAppExtensions: Bool
    var removesURLSchemes: Bool

    /// Extra entitlements merged over the profile's dictionary. A key the
    /// profile does not carry is never invented: the device would refuse it.
    var entitlementOverrides: [String: EntitlementValue]

    /// Libraries linked into the main executable (and nested code when asked).
    var injectedLibraries: [InjectedLibrary]
    var injectsIntoNestedCode: Bool

    /// Sign with no certificate. The CodeDirectory carries `CS_ADHOC` and no
    /// CMS blob is written.
    var adHoc: Bool

    /// Request the hardened-runtime flag (`CS_RUNTIME`).
    var hardenedRuntime: Bool

    static let none = SideloadSigningOptions(
        bundleIdentifier: nil, displayName: nil, name: nil,
        shortVersion: nil, version: nil, minimumOSVersion: nil,
        removesPlugIns: false, removesWatchApps: false,
        removesAppExtensions: false, removesURLSchemes: false,
        entitlementOverrides: [:], injectedLibraries: [],
        injectsIntoNestedCode: false, adHoc: false, hardenedRuntime: false
    )

    init(
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        name: String? = nil,
        shortVersion: String? = nil,
        version: String? = nil,
        minimumOSVersion: String? = nil,
        removesPlugIns: Bool = false,
        removesWatchApps: Bool = false,
        removesAppExtensions: Bool = false,
        removesURLSchemes: Bool = false,
        entitlementOverrides: [String: EntitlementValue] = [:],
        injectedLibraries: [InjectedLibrary] = [],
        injectsIntoNestedCode: Bool = false,
        adHoc: Bool = false,
        hardenedRuntime: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.name = name
        self.shortVersion = shortVersion
        self.version = version
        self.minimumOSVersion = minimumOSVersion
        self.removesPlugIns = removesPlugIns
        self.removesWatchApps = removesWatchApps
        self.removesAppExtensions = removesAppExtensions
        self.removesURLSchemes = removesURLSchemes
        self.entitlementOverrides = entitlementOverrides
        self.injectedLibraries = injectedLibraries
        self.injectsIntoNestedCode = injectsIntoNestedCode
        self.adHoc = adHoc
        self.hardenedRuntime = hardenedRuntime
    }
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
indirect enum EntitlementValue: Equatable, Hashable, Sendable {
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
        }
    }
}

extension SideloadSigningOptions {

    /// ZynSign caps injection because every entry costs header space in the
    /// binary, and a header is a few hundred bytes, not a list.
    static let maximumInjectedLibraries = 16

    /// Whether the options change anything. Used to decide whether the plan
    /// is worth showing and to skip the rewrite entirely.
    var isEmpty: Bool {
        self == SideloadSigningOptions.none
    }

    /// Validate every field before a package is opened.
    func validate(hasCertificate: Bool) throws {
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
        if adHoc && hasCertificate {
            throw SideloadOptionError.adHocWithCertificate
        }
    }

    /// A reverse-DNS identifier: at least two dot-separated parts, each made
    /// of letters, digits and hyphens, and no part empty.
    static func isReverseDNS(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, value.count <= 155 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 63 && part.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    /// Published version strings allow one to three numeric components.
    static func isVersionString(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), value.count <= 32 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 10 && part.allSatisfy { $0.isNumber }
        }
    }

    /// Install names must be absolute or explicitly relative. A bare file
    /// name would be resolved by dyld against an unrelated working directory.
    static func isInstallName(_ value: String) -> Bool {
        let prefixes = ["@executable_path/", "@rpath/", "@loader_path/", "/System/", "/usr/lib/"]
        guard !value.isEmpty, value.count <= 1_024,
              !value.contains(".."), !value.contains("\0") else { return false }
        return prefixes.contains { value.hasPrefix($0) }
    }
}

/// What the pipeline will do to one Info.plist, derived from the options.
///
/// The plan is value data so it can be shown to the user before anything is
/// written, and so the tests can pin the exact edits without a package.
struct InfoPlistOverridePlan: Equatable, Sendable {
    let values: [String: PlistSetting]
    let keysToRemove: [String]

    /// One declared value, typed so a number stays a number.
    enum PlistSetting: Equatable, Sendable {
        case string(String)
        case boolean(Bool)
        case integer(Int)
    }

    var isEmpty: Bool { values.isEmpty && keysToRemove.isEmpty }
}

enum InfoPlistOverrides {

    /// Main application: identity plus the keys the user asked to drop.
    static func mainApplicationPlan(_ options: SideloadSigningOptions) -> InfoPlistOverridePlan {
        var values: [String: InfoPlistOverridePlan.PlistSetting] = [:]
        if let bundleIdentifier = options.bundleIdentifier {
            values["CFBundleIdentifier"] = .string(bundleIdentifier)
        }
        if let displayName = options.displayName {
            values["CFBundleDisplayName"] = .string(displayName)
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
        var removed: [String] = []
        if options.removesURLSchemes {
            removed = ["CFBundleURLTypes", "LSApplicationQueriesSchemes"]
        }
        return InfoPlistOverridePlan(values: values, keysToRemove: removed)
    }

    /// An app extension keeps its own suffix but follows a renamed parent, so
    /// its identifier can never point at a bundle that no longer exists.
    static func extensionIdentifier(oldIdentifier: String,
                                    oldParentIdentifier: String,
                                    newParentIdentifier: String) -> String? {
        let prefix = oldParentIdentifier + "."
        guard oldIdentifier.hasPrefix(prefix) else { return nil }
        return newParentIdentifier + oldIdentifier.dropFirst(oldParentIdentifier.count)
    }
}
