import Foundation

/// An application the library already holds, as the update planner needs it.
///
/// Versions are the strings the package declared. They are not evidence the
/// package is genuine.
struct InstalledApplication: Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let version: String?
    let build: String?
    let recordID: String?
}

/// One update a configured repository offers for an installed application.
struct AppUpdateCandidate: Equatable, Hashable, Sendable, Identifiable {
    let name: String
    let bundleIdentifier: String
    let installedVersion: String?
    let installedBuild: String?
    let latestVersion: String
    let latestBuild: String?
    let sourceName: String
    let sourceIdentifier: String
    let releaseNotes: String?
    let releaseDate: String?
    let versionHistory: [DownloadVersionNote]
    let downloadRequest: DownloadRequest

    var id: String { sourceIdentifier + "|" + bundleIdentifier + "|" + latestVersion }

    /// The installed and latest versions as a short comparison line.
    var comparisonText: String {
        let installed = installedVersion ?? "Unknown"
        return "\(installed) → \(latestVersion)"
    }
}

/// Decides which configured-repository versions are updates.
///
/// Only catalogs the caller supplies are considered, and those catalogs must
/// already have passed metadata validation. A version is an update only when
/// `DeclaredVersionOrder` can say the repository version is newer. An equal
/// version, an older version, a version the user ignored, or a comparison
/// that cannot be made is not surfaced. Two sources offering the same app
/// produce two candidates — the planner does not pick a source silently.
enum UpdatePlanner {

    static func candidates(
        installed: [InstalledApplication],
        catalogs: [RepositoryCatalog],
        ignored: [IgnoredAppVersion]
    ) -> [AppUpdateCandidate] {
        let ignoredKeys = Set(ignored.map { "\($0.bundleIdentifier)|\($0.version)" })
        var results: [AppUpdateCandidate] = []
        for app in installed {
            for catalog in catalogs {
                guard let listing = catalog.apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
                    continue
                }
                guard listing.versionComparisonIsDefinite else { continue }
                let latest = listing.latest
                guard ignoredKeys.contains(app.bundleIdentifier + "|" + latest.version) == false else { continue }
                guard isNewer(latest, than: app) else { continue }
                guard let request = downloadRequest(for: listing, catalog: catalog) else { continue }
                results.append(AppUpdateCandidate(
                    name: listing.name,
                    bundleIdentifier: listing.bundleIdentifier,
                    installedVersion: app.version,
                    installedBuild: app.build,
                    latestVersion: latest.version,
                    latestBuild: latest.build,
                    sourceName: catalog.name,
                    sourceIdentifier: catalog.sourceURL,
                    releaseNotes: latest.notes ?? listing.summary,
                    releaseDate: latest.date,
                    versionHistory: listing.versions.map {
                        DownloadVersionNote(version: $0.version, date: $0.date, notes: $0.notes)
                    },
                    downloadRequest: request
                ))
            }
        }
        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Whether `latest` is strictly newer than the installed declaration.
    /// Returns false when the comparison cannot be made, rather than guessing.
    static func isNewer(_ latest: RepositoryAppVersion, than installed: InstalledApplication) -> Bool {
        let comparison = DeclaredVersionOrder.compare(
            version: installed.version,
            build: installed.build,
            with: latest.version,
            build: latest.build
        )
        return comparison == .orderedAscending
    }

    static func downloadRequest(for app: RepositoryApp, catalog: RepositoryCatalog) -> DownloadRequest? {
        guard let url = URL(string: app.latest.downloadURL) else { return nil }
        return DownloadRequest(
            displayName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            version: app.latest.version,
            build: app.latest.build,
            sourceName: catalog.name,
            sourceKind: DownloadRequest.kindUpdate,
            sourceIdentifier: catalog.sourceURL,
            remoteURL: url,
            iconURL: app.iconURL.flatMap(URL.init(string:)),
            expectedSHA256: app.latest.sha256,
            expectedByteCount: app.latest.size,
            releaseNotes: app.latest.notes ?? app.summary,
            releaseDate: app.latest.date,
            versionHistory: app.versions.map {
                DownloadVersionNote(version: $0.version, date: $0.date, notes: $0.notes)
            }
        )
    }
}
