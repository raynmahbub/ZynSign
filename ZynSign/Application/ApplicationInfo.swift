import Foundation

/// Read-only facts about the running ZynSign application itself, used by the
/// shell — for example, the version shown under Settings.
///
/// This describes the application binary, not an inspected package. The
/// identity of a package under inspection is a domain concern
/// (`ApplicationIdentity`); this type only reports what this build declares
/// about itself, falling back to a neutral placeholder for values the bundle
/// does not provide rather than inventing one.
struct ApplicationInfo: Equatable {

    /// The display name declared by the application bundle.
    let displayName: String

    /// The marketing version (short version string) declared by the bundle.
    let marketingVersion: String

    /// The build number declared by the bundle.
    let buildVersion: String

    /// The fallback used when the bundle declares no version value.
    static let unknownVersion = "unknown"

    /// The fallback used when the bundle declares no display name.
    static let defaultDisplayName = "ZynSign"

    /// Resolves application information from a bundle information
    /// dictionary. Missing values fall back to neutral placeholders.
    static func resolve(from infoDictionary: [String: Any]?) -> ApplicationInfo {
        let displayName = string(infoDictionary?["CFBundleDisplayName"])
            ?? string(infoDictionary?["CFBundleName"])
            ?? defaultDisplayName
        let marketingVersion = string(infoDictionary?["CFBundleShortVersionString"]) ?? unknownVersion
        let buildVersion = string(infoDictionary?["CFBundleVersion"]) ?? unknownVersion
        return ApplicationInfo(
            displayName: displayName,
            marketingVersion: marketingVersion,
            buildVersion: buildVersion
        )
    }

    /// Reads the application information of a bundle, by default the running
    /// application's own bundle.
    static func current(bundle: Bundle = .main) -> ApplicationInfo {
        resolve(from: bundle.infoDictionary)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}
