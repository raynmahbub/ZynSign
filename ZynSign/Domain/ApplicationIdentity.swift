/// The identity of an application bundle as its own metadata declares it.
///
/// A pure domain value: it records what a package claims about itself and
/// carries no file references, platform objects, or verification results.
///
/// Only the bundle identifier is required for a record: a bundle that
/// declares an identifier but no name or version is identified, with the
/// undeclared values left `nil` rather than filled by guessing. The declared
/// name and version strings are preserved exactly as declared, because raw
/// observed values and normalized display values are distinct domain
/// concepts; the resolved display name is the one derived value, and its
/// fallback policy is stated here.
///
/// A constructible `ApplicationIdentity` means only that the declared values
/// satisfied ZynSign's syntactic rules. It is not evidence that the bundle
/// exists, is loadable, or is signed.
struct ApplicationIdentity: Equatable, Hashable, Sendable {

    /// The bundle's declared identifier.
    let bundleIdentifier: BundleIdentifier

    /// The display name exactly as declared (CFBundleDisplayName), without
    /// normalization or trimming, or `nil` when the bundle declares none.
    let declaredDisplayName: String?

    /// The bundle name exactly as declared (CFBundleName), without
    /// normalization or trimming, or `nil` when the bundle declares none.
    let declaredBundleName: String?

    /// The marketing version string exactly as declared
    /// (CFBundleShortVersionString), or `nil` when the bundle declares none.
    /// No version-format system is imposed on the value.
    let shortVersionString: String?

    /// The build version string exactly as declared (CFBundleVersion), or
    /// `nil` when the bundle declares none.
    let buildVersion: String?

    /// The display name to present for the bundle.
    ///
    /// The fallback policy is deterministic: the declared display name when
    /// it is present and non-empty, otherwise the declared bundle name when
    /// it is present and non-empty, otherwise `nil`. An absent or empty name
    /// is never replaced by an invented one.
    var displayName: String? {
        if let display = declaredDisplayName, !display.isEmpty {
            return display
        }
        if let bundle = declaredBundleName, !bundle.isEmpty {
            return bundle
        }
        return nil
    }

    /// Creates an identity from declared values, throwing a typed domain
    /// error when the declared bundle identifier fails validation.
    ///
    /// The `displayName` parameter is the declared CFBundleDisplayName value
    /// and the `bundleName` parameter the declared CFBundleName value; both
    /// are preserved exactly as supplied.
    init(
        bundleIdentifier: String,
        displayName: String? = nil,
        bundleName: String? = nil,
        shortVersionString: String? = nil,
        buildVersion: String? = nil
    ) throws {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            throw ZynSignError(
                category: .invalidInput,
                userMessage: "The application's declared identity is not valid.",
                diagnosticDetail: "The declared bundle identifier failed ZynSign's syntactic validation."
            )
        }
        self.init(
            bundleIdentifier: identifier,
            declaredDisplayName: displayName,
            declaredBundleName: bundleName,
            shortVersionString: shortVersionString,
            buildVersion: buildVersion
        )
    }

    /// Creates an identity from an already validated identifier.
    init(
        bundleIdentifier: BundleIdentifier,
        declaredDisplayName: String? = nil,
        declaredBundleName: String? = nil,
        shortVersionString: String? = nil,
        buildVersion: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.declaredDisplayName = declaredDisplayName
        self.declaredBundleName = declaredBundleName
        self.shortVersionString = shortVersionString
        self.buildVersion = buildVersion
    }
}
