import Foundation

/// Transport for release feed bodies. The platform implementation speaks
/// HTTPS with a bounded timeout; tests substitute a canned body.
protocol ReleaseFeedTransport: Sendable {
    /// Fetches the raw body at `url`.
    func fetch(url: URL, timeout: TimeInterval) async throws -> Data
}

/// Persistence for the repository feeds the user has added.
protocol ReleaseFeedCatalogStore: Sendable {
    /// The feeds the user added, in the order they were added.
    func all() throws -> [ReleaseFeedReference]
    /// Adds one feed; a feed already recorded is left alone.
    func add(_ reference: ReleaseFeedReference) throws
    /// Replaces the recorded feed with the same owner and repository, when
    /// one exists — the path tracking changes take.
    func replace(_ reference: ReleaseFeedReference) throws
    /// Removes one feed, when recorded.
    func remove(_ reference: ReleaseFeedReference) throws
}

/// The loaded state of one repository feed.
struct ReleaseFeedSnapshot: Equatable, Hashable, Sendable {
    /// The feed these entries came from.
    let reference: ReleaseFeedReference
    /// The parsed entries, newest first as the feed published them.
    let entries: [ReleaseFeedEntry]
    /// When the feed was last read.
    let fetchedAt: Date
}

/// Loads repository release feeds and keeps the user's list of feeds.
///
/// A feed is a discovery channel: it lists releases and where their package
/// assets live. Nothing a feed says is trusted — a package a user downloads
/// from one still passes the ordinary import boundary, fingerprint and all.
struct GitHubReleaseSourceProvider: Sendable {

    /// The most seconds one feed fetch may take.
    static let fetchTimeout: TimeInterval = 10

    private let transport: any ReleaseFeedTransport
    private let catalog: any ReleaseFeedCatalogStore

    init(transport: any ReleaseFeedTransport, catalog: any ReleaseFeedCatalogStore) {
        self.transport = transport
        self.catalog = catalog
    }

    /// The feeds the user has added.
    func feeds() throws -> [ReleaseFeedReference] {
        try catalog.all()
    }

    /// Adds a feed from `owner/name` text. Returns `false` when the text
    /// does not name a feed.
    @discardableResult
    func addFeed(ownerSlashName: String) throws -> Bool {
        guard let reference = ReleaseFeedReference(ownerSlashName: ownerSlashName) else {
            return false
        }
        try catalog.add(reference)
        return true
    }

    /// Removes one feed.
    func removeFeed(_ reference: ReleaseFeedReference) throws {
        try catalog.remove(reference)
    }

    /// Sets the application a feed tracks for update comparison, or clears
    /// tracking with `nil`.
    func setTracking(bundleIdentifier: String?, for reference: ReleaseFeedReference) throws {
        var updated = reference
        updated.trackedBundleIdentifier = bundleIdentifier
        try catalog.replace(updated)
    }

    /// Fetches and parses one feed.
    ///
    /// - Returns: The parsed snapshot.
    /// - Throws: A typed `ZynSignError` when the feed has no address, the
    ///   transport fails, or the body does not parse.
    func load(_ reference: ReleaseFeedReference, clock: Date = Date()) async throws -> ReleaseFeedSnapshot {
        guard let url = reference.releasesAPIURL else {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "The release feed reference does not form a usable address."
            )
        }
        let body: Data
        do {
            body = try await transport.fetch(url: url, timeout: Self.fetchTimeout)
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "Release feed \(reference.owner)/\(reference.repository) did not answer.",
                underlyingError: error
            )
        }
        switch ReleaseFeedParser.parse(body) {
        case .success(let entries):
            return ReleaseFeedSnapshot(reference: reference, entries: entries, fetchedAt: clock)
        case .failure(let failure):
            throw ZynSignError.releaseFeedUnreadable(
                diagnosticDetail: "Release feed \(reference.owner)/\(reference.repository): \(failure.message)"
            )
        }
    }
}

/// Compares library applications against release feeds and catalogs and
/// reports the applications a newer release exists for.
///
/// The tracker compares version strings with `AppVersionComparison` and
/// never infers an update from dates. A version pair it cannot compare is
/// reported as incomparable, not as an update.
struct LibraryUpdateTracker: Sendable {

    /// One application a newer release exists for.
    struct AvailableUpdate: Equatable, Hashable, Sendable {
        /// The display name of the application.
        let appName: String
        /// The bundle identifier of the application.
        let bundleIdentifier: String
        /// The version currently in the library.
        let installedVersion: String
        /// The newer version the source offers.
        let availableVersion: String
        /// Where the newer version was seen.
        let sourceName: String
        /// The download address of the newer release, when the source has one.
        let downloadURL: URL?
    }

    /// One installed application the tracker can compare.
    struct InstalledApp: Equatable, Hashable, Sendable {
        let appName: String
        let bundleIdentifier: String
        let version: String
    }

    /// One offered release the tracker can compare against.
    struct OfferedRelease: Equatable, Hashable, Sendable {
        let version: String
        let sourceName: String
        let bundleIdentifier: String?
        let downloadURL: URL?
    }

    /// Computes the available updates for `installed` against `offers`.
    ///
    /// Matching is by bundle identifier: an offer names the app it belongs
    /// to, and only that app may receive it. An offer that names no app is
    /// browse-only metadata and never produces an update — inferring one
    /// would be a guess, and the tracker does not guess.
    static func availableUpdates(
        installed: [InstalledApp],
        offers: [OfferedRelease]
    ) -> [AvailableUpdate] {
        var updates: [AvailableUpdate] = []
        for app in installed {
            let candidates = offers.filter { offer in
                guard let offerBundle = offer.bundleIdentifier else { return false }
                return offerBundle == app.bundleIdentifier
            }
            var best: OfferedRelease?
            for candidate in candidates {
                guard AppVersionComparison.isUpdate(candidate.version, over: app.version) else { continue }
                if let current = best {
                    if AppVersionComparison.compare(candidate.version, current.version) == .newer {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
            if let best {
                updates.append(AvailableUpdate(
                    appName: app.appName,
                    bundleIdentifier: app.bundleIdentifier,
                    installedVersion: app.version,
                    availableVersion: best.version,
                    sourceName: best.sourceName,
                    downloadURL: best.downloadURL
                ))
            }
        }
        return updates.sorted { ($0.appName, $0.bundleIdentifier) < ($1.appName, $1.bundleIdentifier) }
    }

    /// Turns one release feed snapshot into offered releases: every entry
    /// with a package asset and a parseable version. Each offer carries the
    /// bundle identifier the feed tracks, so update comparison can match by
    /// app; a feed that tracks no app produces browse-only offers.
    static func offers(from snapshot: ReleaseFeedSnapshot) -> [OfferedRelease] {
        snapshot.entries.compactMap { entry in
            guard AppVersionComparison.parse(entry.bareVersion) != nil else { return nil }
            return OfferedRelease(
                version: entry.bareVersion,
                sourceName: "\(snapshot.reference.owner)/\(snapshot.reference.repository)",
                bundleIdentifier: snapshot.reference.trackedBundleIdentifier,
                downloadURL: entry.packageAsset?.downloadURL
            )
        }
    }
}
