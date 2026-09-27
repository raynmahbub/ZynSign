import Foundation

/// An independent AltSource-compatible adapter. Unknown extension keys are ignored;
/// malformed known fields reject the entire snapshot, never a partial catalog.
struct StoreManifestValidator {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumApps = 5000

    func parse(_ data: Data, sourceID: UUID, url: URL) throws -> CatalogSource {
        guard data.count <= Self.maximumBytes else { throw StoreFailure.invalid("The source manifest exceeds the 8 MB limit.") }
        let feed: Feed
        do { feed = try JSONDecoder().decode(Feed.self, from: data) }
        catch { throw StoreFailure.invalid("Invalid manifest: expected a JSON source with name, apps, and correctly typed app fields. \(error.localizedDescription)") }
        let name = try text(feed.name, field: "source name", limit: 200)
        guard feed.apps.count <= Self.maximumApps else { throw StoreFailure.invalid("A source may contain at most 5,000 apps.") }
        var bundles = Set<String>()
        var apps: [CatalogApp] = []
        for app in feed.apps {
            let bundle = try text(app.bundleIdentifier, field: "bundleIdentifier", limit: 255)
            guard bundle.contains("."), bundle.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
                  !bundle.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
                  bundles.insert(bundle).inserted else {
                throw StoreFailure.invalid("Invalid or duplicate bundleIdentifier: \(bundle). Each app must appear once per source.")
            }
            let releases = try (app.versions ?? [Release(version: app.version, date: app.versionDate, localizedDescription: app.versionDescription, downloadURL: app.downloadURL, size: app.size, minOSVersion: app.minOSVersion, maxOSVersion: app.maxOSVersion)]).map { release -> CatalogRelease in
                let version = try text(release.version, field: "version for \(bundle)", limit: 100)
                guard let rawURL = release.downloadURL else { throw StoreFailure.invalid("Missing downloadURL for \(bundle) \(version).") }
                let download = try StoreURLPolicy.validate(rawURL)
                if let size = release.size, size <= 0 || size > 4 * 1024 * 1024 * 1024 { throw StoreFailure.invalid("Invalid download size for \(bundle).") }
                var date: Date?
                if let raw = release.date {
                    date = Self.date(raw)
                    guard date != nil else { throw StoreFailure.invalid("Invalid release date for \(bundle); use ISO 8601 or yyyy-MM-dd.") }
                }
                for os in [release.minOSVersion, release.maxOSVersion].compactMap({ $0 }) {
                    guard CatalogVersion.components(os) != nil else { throw StoreFailure.invalid("Invalid OS version for \(bundle).") }
                }
                if let min = release.minOSVersion, let max = release.maxOSVersion, CatalogVersion.isNewer(min, than: max) {
                    throw StoreFailure.invalid("Minimum OS exceeds maximum OS for \(bundle).")
                }
                return CatalogRelease(version: version, date: date, notes: try optionalText(release.localizedDescription, field: "release notes"), downloadURL: download, size: release.size, minOSVersion: release.minOSVersion, maxOSVersion: release.maxOSVersion)
            }
            guard !releases.isEmpty, releases.count <= 200, Set(releases.map(\.version)).count == releases.count else {
                throw StoreFailure.invalid("An app requires 1–200 releases with unique version strings: \(bundle).")
            }
            // AltSource arrays are newest-first. Do not infer an update from release dates.
            let shots = try app.screenshotURLs?.urls.map(StoreURLPolicy.validate) ?? []
            guard shots.count <= 30 else { throw StoreFailure.invalid("At most 30 screenshots are supported per app.") }
            apps.append(CatalogApp(sourceID: sourceID, bundleID: bundle,
                name: try text(app.name, field: "app name", limit: 200),
                developer: try text(app.developerName, field: "developerName for \(bundle)", limit: 200),
                developerIconURL: try app.developerIconURL.map(StoreURLPolicy.validate),
                keywords: try optionalKeywords(app.keywords),
                subtitle: try optionalText(app.subtitle, field: "subtitle", limit: 500),
                description: try optionalText(app.localizedDescription, field: "description") ?? "No description supplied.",
                iconURL: try app.iconURL.map(StoreURLPolicy.validate), screenshots: shots,
                category: try optionalText(app.category, field: "category", limit: 100) ?? "Utilities",
                releases: releases, featured: (app.featured ?? false) || (feed.featuredApps?.contains(bundle) ?? false)))
        }
        if let featured = feed.featuredApps, !Set(featured).isSubset(of: bundles) {
            throw StoreFailure.invalid("featuredApps contains a bundle identifier not present in apps.")
        }
        return CatalogSource(id: sourceID, url: url, name: name,
            identifier: try optionalText(feed.identifier, field: "source identifier", limit: 500),
            iconURL: try feed.iconURL.map(StoreURLPolicy.validate),
            summary: try optionalText(feed.subtitle ?? feed.description, field: "source description"), apps: apps)
    }

    private func text(_ value: String?, field: String, limit: Int) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }) else {
            throw StoreFailure.invalid("Missing, empty, or oversized \(field).")
        }
        return value
    }
    private func optionalText(_ value: String?, field: String, limit: Int = 100_000) throws -> String? {
        guard let value else { return nil }
        if value.isEmpty { return nil }
        return try text(value, field: field, limit: limit)
    }
    private func optionalKeywords(_ values: [String]?) throws -> [String]? {
        guard let values else { return nil }
        guard values.count <= 64 else { throw StoreFailure.invalid("An app may provide at most 64 search keywords.") }
        return try values.map { try text($0, field: "search keyword", limit: 100) }
    }
    static func date(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard raw.count == 10, let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return date
    }

    private struct Feed: Decodable {
        let name: String
        let identifier: String?
        let iconURL: String?
        let subtitle: String?
        let description: String?
        let apps: [App]
        let featuredApps: [String]?
    }
    private struct App: Decodable {
        let name: String
        let bundleIdentifier: String
        let developerName: String
        let developerIconURL: String?
        let keywords: [String]?
        let subtitle: String?
        let localizedDescription: String?
        let iconURL: String?
        let screenshotURLs: Screenshots?
        let category: String?
        let featured: Bool?
        let versions: [Release]?
        let version: String?
        let versionDate: String?
        let versionDescription: String?
        let downloadURL: String?
        let size: Int64?
        let minOSVersion: String?
        let maxOSVersion: String?
    }
    private struct Release: Decodable {
        let version: String?
        let date: String?
        let localizedDescription: String?
        let downloadURL: String?
        let size: Int64?
        let minOSVersion: String?
        let maxOSVersion: String?
    }
    private struct Screenshots: Decodable {
        let urls: [String]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flat = try? container.decode([String].self) { urls = flat; return }
            let devices = try container.decode([String: [String]].self)
            urls = (devices["iphone"] ?? []) + (devices["ipad"] ?? [])
            guard devices.keys.allSatisfy({ ["iphone", "ipad"].contains($0) }) else {
                throw StoreFailure.invalid("Unsupported screenshot device group.")
            }
        }
    }
}
