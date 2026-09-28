import Foundation

/// Why a URL was refused before any bytes were requested.
///
/// Refusals are about the address itself. A URL that passes is still untrusted:
/// repository membership and a successful transfer are not evidence that the
/// bytes are an application package.
enum DownloadURLRejection: String, Equatable, Hashable, Sendable, Error {

    case empty
    case unparsable
    case unsupportedScheme
    case missingHost
    case embeddedCredentials
    case insecureTransport

    /// A short explanation safe to show directly.
    var userMessage: String {
        switch self {
        case .empty:
            return "Enter a download address."
        case .unparsable:
            return "That address could not be read."
        case .unsupportedScheme:
            return "ZynSign only downloads from https addresses, or from an install manifest that points at one."
        case .missingHost:
            return "That address has no host, so ZynSign will not request it."
        case .embeddedCredentials:
            return "ZynSign will not download an address that embeds a username or password."
        case .insecureTransport:
            return "ZynSign does not download over insecure http. Use an https address."
        }
    }
}

/// What a user-supplied link is asking ZynSign to fetch.
enum DownloadLink: Equatable, Sendable {

    /// An address that may be the package itself. It is not trusted as a package
    /// until the artifact is validated after transfer.
    case artifact(URL)

    /// An install-manifest address. The manifest must be fetched and parsed
    /// before any package transfer starts. The manifest is not the package.
    case installManifest(URL)
}

/// The address rules the Download Center applies before it requests bytes.
///
/// Repository metadata and user-supplied links share one rule: https, a host,
/// and no embedded credentials. `http`, `file`, and script schemes are refused
/// here so a configured source cannot widen the rule by publishing them.
/// Passing this policy is not trust. The downloaded bytes are still validated
/// before they can be imported.
enum DownloadURLPolicy {

    /// The largest package the center will accept. A declared or transferred
    /// size above this is refused rather than buffered.
    static let maximumArtifactBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    /// The largest repository document the center will parse.
    static let maximumCatalogBytes = 8 * 1_024 * 1_024

    /// Classifies a user-supplied link. A missing scheme is read as https.
    /// An `itms-services` install link is accepted only as a pointer to an
    /// https manifest, never as a package address.
    static func classifyUserLink(_ raw: String) -> Result<DownloadLink, DownloadURLRejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed) else { return .failure(.unparsable) }
        let scheme = components.scheme?.lowercased()
        if scheme == "itms-services" {
            guard let url = components.url else { return .failure(.unparsable) }
            guard let manifest = manifestURL(fromInstallLink: url) else {
                return .failure(.unsupportedScheme)
            }
            return .success(.installManifest(manifest))
        }
        var normalized = components
        if scheme == nil || scheme?.isEmpty == true {
            // Setting the scheme on components that never had one leaves the
            // authority unparsed and no host to validate. Re-read the same
            // text as an address, which is what "a missing scheme is read
            // as https" promises.
            guard let withScheme = URLComponents(string: "https://" + trimmed) else {
                return .failure(.unparsable)
            }
            normalized = withScheme
        }
        guard let url = normalized.url else { return .failure(.unparsable) }
        if normalized.path.lowercased().hasSuffix(".plist") {
            return validateHTTPS(url).map { .installManifest($0) }
        }
        return validateHTTPS(url).map { .artifact($0) }
    }

    /// Validates an address that will be requested as repository metadata or
    /// as a package. https only.
    static func validateHTTPS(_ url: URL) -> Result<URL, DownloadURLRejection> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unparsable)
        }
        return validateHTTPS(components)
    }

    /// Validates a string address used by a repository feed. A missing scheme
    /// is not invented here: repository metadata must already say https.
    static func validateRepositoryAddress(_ string: String) -> Result<URL, DownloadURLRejection> {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed), components.url != nil else {
            return .failure(.unparsable)
        }
        return validateHTTPS(components)
    }

    /// The https manifest named by an `itms-services` install link, if the
    /// link's query carries one. Anything else is refused.
    static func manifestURL(fromInstallLink url: URL) -> URL? {
        guard url.scheme?.lowercased() == "itms-services" else { return nil }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        guard let raw = items.first(where: { $0.name == "url" })?.value else { return nil }
        guard case let .success(manifest) = validateRepositoryAddress(raw) else { return nil }
        return manifest
    }

    // MARK: - Shared https rule

    private static func validateHTTPS(_ components: URLComponents) -> Result<URL, DownloadURLRejection> {
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            return .failure(.unsupportedScheme)
        }
        guard scheme == "https" else {
            if scheme == "http" { return .failure(.insecureTransport) }
            return .failure(.unsupportedScheme)
        }
        if let user = components.user, !user.isEmpty { return .failure(.embeddedCredentials) }
        if components.password != nil { return .failure(.embeddedCredentials) }
        guard let host = components.host, !host.isEmpty, host != "." else {
            return .failure(.missingHost)
        }
        guard let url = components.url else { return .failure(.unparsable) }
        return .success(url)
    }
}
