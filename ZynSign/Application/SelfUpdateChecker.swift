import Foundation

/// Checks GitHub Releases (`raynmahbub/ZynSign` by default) for newer builds
/// of ZynSign itself, comparing semantic tags against the running app version
/// and surfacing `.ipa` release assets for one-tap download into `DownloadCenter`.
struct SelfUpdateChecker: Sendable {

    static let defaultRepositorySlug = "raynmahbub/ZynSign"

    struct UpdateStatus: Equatable, Sendable {
        let currentVersion: String
        let latestTag: String
        let releaseTitle: String
        let publishedAt: Date?
        let ipaAssetURL: URL?
        let isNewerAvailable: Bool
    }

    private let transport: any ReleaseFeedTransport

    init(transport: any ReleaseFeedTransport) {
        self.transport = transport
    }

    func checkForUpdates(
        currentVersion: String,
        repositorySlug: String = SelfUpdateChecker.defaultRepositorySlug
    ) async throws -> UpdateStatus? {
        guard let reference = ReleaseFeedReference(ownerSlashName: repositorySlug),
              let url = reference.releasesAPIURL else {
            return nil
        }
        let data = try await transport.fetch(url: url, timeout: GitHubReleaseSourceProvider.fetchTimeout)
        let releases: [ReleaseFeedEntry]
        switch ReleaseFeedParser.parse(data) {
        case .success(let parsed):
            releases = parsed
        case .failure:
            return nil
        }
        guard let latest = releases.first(where: { !$0.isDraft }) ?? releases.first else {
            return nil
        }
        let newer = AppVersionComparison.isUpdate(latest.bareVersion, over: currentVersion)
        return UpdateStatus(
            currentVersion: currentVersion,
            latestTag: latest.tag,
            releaseTitle: latest.title,
            publishedAt: latest.publishedAt,
            ipaAssetURL: latest.packageAsset?.downloadURL,
            isNewerAvailable: newer
        )
    }
}
