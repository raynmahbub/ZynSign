/// The identity of an application bundle as its own metadata declares it.
///
/// A pure domain value: it records what a package claims about itself and
/// carries no file references, platform objects, or verification results. The
/// display and version strings are preserved exactly as declared, because
/// raw observed values and normalized display values are distinct domain
/// concepts.
///
/// A constructible `ApplicationIdentity` means only that the declared values
/// satisfied ZynSign's syntactic rules. It is not evidence that the bundle
/// exists, is loadable, or is signed.
struct ApplicationIdentity: Equatable, Hashable {

    /// The bundle's declared identifier.
    let bundleIdentifier: BundleIdentifier

    /// The display name exactly as declared; not normalized or trimmed.
    let displayName: String

    /// The marketing version string exactly as declared (for example, "1.4.2").
    let shortVersionString: String

    /// The build version string exactly as declared (for example, "87").
    let buildVersion: String

    /// Creates an identity, throwing a typed domain error when the declared
    /// bundle identifier fails validation.
    init(
        bundleIdentifier: String,
        displayName: String,
        shortVersionString: String,
        buildVersion: String
    ) throws {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            throw ZynSignError(
                category: .invalidInput,
                userMessage: "The application's declared identity is not valid.",
                diagnosticDetail: "The declared bundle identifier failed ZynSign's syntactic validation."
            )
        }
        self.bundleIdentifier = identifier
        self.displayName = displayName
        self.shortVersionString = shortVersionString
        self.buildVersion = buildVersion
    }
}
