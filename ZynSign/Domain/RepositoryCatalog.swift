import Foundation

/// One version a repository declared for an application.
struct RepositoryAppVersion: Equatable, Hashable, Sendable, Codable, Identifiable {
    let version: String
    let build: String?
    let date: String?
    let notes: String?
    let downloadURL: String
    let size: Int64?
    let sha256: String?

    var id: String { version + "|" + downloadURL }
}

/// One application a validated repository catalog lists.
///
/// `latest` is the version the center will offer. When the feed's versions
/// could not be ordered, `versionComparisonIsDefinite` is false and the update
/// engine will not claim that version is newer than an installed one.
struct RepositoryApp: Equatable, Hashable, Sendable, Codable, Identifiable {
    let name: String
    let bundleIdentifier: String
    let subtitle: String?
    let developerName: String?
    let summary: String?
    let iconURL: String?
    let versions: [RepositoryAppVersion]
    let latest: RepositoryAppVersion
    let versionComparisonIsDefinite: Bool

    var id: String { bundleIdentifier }
}

/// A repository document that passed metadata validation.
///
/// Acceptance means the document was JSON, named its apps, and every listed
/// app has at least one https download address that passed the URL policy.
/// It does not mean the packages are authentic, signed, or safe to import.
struct RepositoryCatalog: Equatable, Sendable, Codable {
    let name: String
    let identifier: String?
    let sourceURL: String
    let apps: [RepositoryApp]
    let fetchedAt: Date
    /// Apps that were skipped because their own metadata failed. The feed
    /// itself was still accepted. Empty when every app was usable.
    let skippedAppCount: Int
}

/// The outcome of examining repository metadata before any package is fetched.
struct RepositoryCatalogExamination: Equatable, Sendable {
    let catalog: RepositoryCatalog?
    let findings: [String]

    var isAccepted: Bool { catalog != nil }

    static func rejected(_ finding: String) -> RepositoryCatalogExamination {
        RepositoryCatalogExamination(catalog: nil, findings: [finding])
    }
}

/// Parses AltSource-compatible repository JSON.
///
/// The parser is pure and fail-closed for the document: a body that is not a
/// JSON object with an `apps` array is rejected entirely, and no download
/// address from it is returned. An individual app with no acceptable https
/// package address is skipped and counted, not downloaded. A configured source
/// is not treated as trust — this only decides whether the metadata is
/// well-formed enough to offer.
enum RepositoryCatalogParser {

    static let maximumApps = 2_000
    static let maximumVersionsPerApp = 40
    static let maximumNotesCharacters = 8_000

    static func examine(
        data: Data,
        sourceURL: URL,
        fetchedAt: Date,
        maximumBytes: Int = DownloadURLPolicy.maximumCatalogBytes
    ) -> RepositoryCatalogExamination {
        guard data.count <= maximumBytes else {
            return .rejected("The source document is larger than ZynSign will parse.")
        }
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .rejected("The source is not JSON, so ZynSign did not read any download address from it.")
        }
        guard let root = rootObject as? [String: Any] else {
            return .rejected("The source JSON is not an object, so ZynSign did not read any download address from it.")
        }
        guard let appsValue = root["apps"] else {
            return .rejected("The source has no apps list, so ZynSign did not download anything from it.")
        }
        guard let apps = appsValue as? [[String: Any]] else {
            return .rejected("The source's apps list is not a list of objects.")
        }
        if apps.count > maximumApps {
            return .rejected("The source lists more applications than ZynSign will accept in one document.")
        }
        var parsed: [RepositoryApp] = []
        var skipped = 0
        for app in apps {
            switch parseApp(app) {
            case let .success(parsedApp):
                parsed.append(parsedApp)
            case .failure:
                skipped += 1
            }
        }
        let name = nonEmptyString(root["name"]) ?? sourceURL.host ?? "Source"
        let identifier = nonEmptyString(root["identifier"])
        let catalog = RepositoryCatalog(
            name: name,
            identifier: identifier,
            sourceURL: sourceURL.absoluteString,
            apps: parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            fetchedAt: fetchedAt,
            skippedAppCount: skipped
        )
        var findings: [String] = []
        if skipped > 0 {
            findings.append("\(skipped) \(skipped == 1 ? "app was" : "apps were") skipped because their download metadata was not acceptable.")
        }
        return RepositoryCatalogExamination(catalog: catalog, findings: findings)
    }

    // MARK: - Apps

    private static func parseApp(_ object: [String: Any]) -> Result<RepositoryApp, DownloadURLRejection> {
        guard let name = nonEmptyString(object["name"]) else { return .failure(.empty) }
        guard let bundle = nonEmptyString(object["bundleIdentifier"]), BundleIdentifier(rawValue: bundle) != nil else {
            return .failure(.unparsable)
        }
        let versions = parseVersions(object)
        guard !versions.isEmpty else { return .failure(.unsupportedScheme) }
        let ordered = selectLatest(versions)
        return .success(RepositoryApp(
            name: String(name.prefix(200)),
            bundleIdentifier: bundle,
            subtitle: nonEmptyString(object["subtitle"]),
            developerName: nonEmptyString(object["developerName"]),
            summary: boundedNotes(nonEmptyString(object["localizedDescription"]) ?? nonEmptyString(object["description"])),
            iconURL: iconAddress(object["iconURL"]),
            versions: ordered.versions,
            latest: ordered.latest,
            versionComparisonIsDefinite: true
        ))
    }

    private static func parseVersions(_ object: [String: Any]) -> [RepositoryAppVersion] {
        if let listed = object["versions"] as? [[String: Any]] {
            return Array(listed.prefix(maximumVersionsPerApp)).compactMap(parseVersion)
        }
        return parseVersion(object).map { [$0] } ?? []
    }

    private static func parseVersion(_ object: [String: Any]) -> RepositoryAppVersion? {
        let version = nonEmptyString(object["version"]) ?? nonEmptyString(object["cfBundleShortVersionString"])
        guard let version else { return nil }
        guard let rawURL = nonEmptyString(object["downloadURL"]) else { return nil }
        guard case let .success(url) = DownloadURLPolicy.validateRepositoryAddress(rawURL) else { return nil }
        let sha = checksum(object["sha256"])
        if object["sha256"] != nil && sha == nil { return nil }
        return RepositoryAppVersion(
            version: String(version.prefix(64)),
            build: nonEmptyString(object["buildVersion"]) ?? nonEmptyString(object["cfBundleVersion"]),
            date: nonEmptyString(object["date"]) ?? nonEmptyString(object["versionDate"]),
            notes: boundedNotes(
                nonEmptyString(object["localizedDescription"])
                    ?? nonEmptyString(object["versionDescription"])
                    ?? nonEmptyString(object["news"])
            ),
            downloadURL: url.absoluteString,
            size: byteCount(object["size"]),
            sha256: sha
        )
    }

    private static func selectLatest(
        _ versions: [RepositoryAppVersion]
    ) -> (latest: RepositoryAppVersion, versions: [RepositoryAppVersion]) {
        var best = versions[0]
        for version in versions.dropFirst() {
            if DeclaredVersionOrder.compare(version.version, best.version) == .orderedDescending {
                best = version
            }
        }
        let ordered = versions.sorted { lhs, rhs in
            DeclaredVersionOrder.compare(lhs.version, rhs.version) == .orderedDescending
        }
        return (best, ordered)
    }

    private static func iconAddress(_ value: Any?) -> String? {
        guard let raw = nonEmptyString(value) else { return nil }
        guard case let .success(url) = DownloadURLPolicy.validateRepositoryAddress(raw) else { return nil }
        return url.absoluteString
    }

    private static func checksum(_ value: Any?) -> String? {
        guard let raw = nonEmptyString(value)?.lowercased() else { return nil }
        guard raw.count == 64, raw.allSatisfy(\.isHexDigit) else { return nil }
        return raw
    }

    private static func byteCount(_ value: Any?) -> Int64? {
        let number: Int64?
        if let int = value as? Int { number = Int64(int) }
        else if let int = value as? Int64 { number = int }
        else if let double = value as? Double, double.isFinite { number = Int64(double) }
        else { number = nil }
        guard let number, number > 0, number <= DownloadURLPolicy.maximumArtifactBytes else { return nil }
        return number
    }

    private static func boundedNotes(_ notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        if notes.count <= maximumNotesCharacters { return notes }
        return String(notes.prefix(maximumNotesCharacters))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads an install manifest. Only a property-list `software-package` asset
/// whose address passes the https rule is accepted. Text scanning is not used.
enum InstallManifestParser {

    static func ipaURL(from data: Data) -> URL? {
        guard data.count <= DownloadURLPolicy.maximumCatalogBytes else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .openStep,
              let dictionary = root as? [String: Any],
              let items = dictionary["items"] as? [[String: Any]] else {
            return nil
        }
        for item in items {
            guard let assets = item["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                let kind = (asset["kind"] as? String)?.lowercased()
                guard kind == "software-package" else { continue }
                guard let raw = asset["url"] as? String,
                      case let .success(url) = DownloadURLPolicy.validateRepositoryAddress(raw) else {
                    continue
                }
                return url
            }
        }
        return nil
    }
}
