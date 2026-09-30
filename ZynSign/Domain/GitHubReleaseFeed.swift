import Foundation

/// One asset attached to a release in a repository feed.
struct ReleaseFeedAsset: Equatable, Hashable, Codable, Sendable {
    /// The asset's file name.
    let name: String
    /// The asset size in bytes, when the feed reports one.
    let byteSize: Int?
    /// The download address.
    let downloadURL: URL
    /// The asset's MIME type, when the feed reports one.
    let contentType: String?
}

/// One release in a repository feed.
struct ReleaseFeedEntry: Equatable, Hashable, Codable, Sendable {
    /// The release tag, e.g. `v1.2.0`.
    let tag: String
    /// The display name of the release, falling back to the tag.
    let title: String
    /// When the release was published, when the feed says so.
    let publishedAt: Date?
    /// Whether the feed marks the release as a pre-release.
    let isPrerelease: Bool
    /// Whether the feed marks the release as a draft.
    let isDraft: Bool
    /// The assets the release carries.
    let assets: [ReleaseFeedAsset]

    /// The first installable package asset, preferring `.ipa`, then `.tipa`.
    var packageAsset: ReleaseFeedAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".ipa") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".tipa") }
    }

    /// The tag stripped of a leading `v`, when version comparison needs a
    /// bare number string.
    var bareVersion: String {
        var text = tag
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }
}

/// A reference to one repository feed.
struct ReleaseFeedReference: Equatable, Hashable, Codable, Sendable, Identifiable {

    /// The feed's display identity, also its stable identifier.
    var id: String { "\(owner)/\(repository)" }

    /// The repository owner.
    let owner: String
    /// The repository name.
    let repository: String
    /// The bundle identifier this feed tracks for update comparison, when
    /// the user chose one. Feeds without a tracked app remain browsable.
    var trackedBundleIdentifier: String?

    /// Parses `owner/name`, refusing empty or malformed parts.
    init?(ownerSlashName: String) {
        let parts = ownerSlashName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = parts[0].trimmingCharacters(in: .whitespaces)
        let repository = parts[1].trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !repository.isEmpty,
              owner.rangeOfCharacter(from: .whitespaces) == nil,
              repository.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        self.owner = owner
        self.repository = repository
        self.trackedBundleIdentifier = nil
    }

    init(owner: String, repository: String, trackedBundleIdentifier: String? = nil) {
        self.owner = owner
        self.repository = repository
        self.trackedBundleIdentifier = trackedBundleIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case owner
        case repository
        case trackedBundleIdentifier
    }

    /// Decodes tolerantly: documents written before tracking existed simply
    /// carry no tracked app.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        repository = try container.decode(String.self, forKey: .repository)
        trackedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .trackedBundleIdentifier)
    }

    /// The canonical address of the repository.
    var webURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repository)")
    }

    /// The releases API address this feed reads.
    var releasesAPIURL: URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=25")
    }
}

/// Parses repository release feeds into structured entries.
///
/// The parser accepts the JSON shape public repository hosting services
/// publish for release listings. Unknown keys are ignored; entries missing a
/// tag are dropped; draft releases are dropped unless the caller keeps them.
/// A feed that fails to parse yields nothing and a typed reason, never a
/// partial guess.
enum ReleaseFeedParser {

    /// Why a feed could not be parsed.
    enum Failure: Error, Equatable, Hashable, Sendable {
        case invalidJSON
        case noEntries

        var message: String {
            switch self {
            case .invalidJSON: return "The release feed did not return readable JSON."
            case .noEntries: return "The release feed lists no releases."
            }
        }
    }

    private struct WireRelease: Codable {
        let tag_name: String?
        let name: String?
        let published_at: String?
        let prerelease: Bool?
        let draft: Bool?
        let assets: [WireAsset]?
    }

    private struct WireAsset: Codable {
        let name: String?
        let size: Int?
        let browser_download_url: String?
        let content_type: String?
    }

    /// Parses one feed body.
    ///
    /// - Parameters:
    ///   - data: The raw JSON body.
    ///   - includeDrafts: Whether draft releases survive the parse.
    ///   - iso8601: The date decoder, injectable for tests.
    static func parse(
        _ data: Data,
        includeDrafts: Bool = false,
        decoder: JSONDecoder = ReleaseFeedParser.makeDefaultDecoder()
    ) -> Result<[ReleaseFeedEntry], Failure> {
        guard let wire = try? decoder.decode([WireRelease].self, from: data) else {
            return .failure(.invalidJSON)
        }
        let entries: [ReleaseFeedEntry] = wire.compactMap { release in
            guard let tag = release.tag_name, !tag.isEmpty else { return nil }
            if release.draft == true && !includeDrafts { return nil }
            let assets: [ReleaseFeedAsset] = (release.assets ?? []).compactMap { asset in
                guard let name = asset.name, let link = asset.browser_download_url,
                      let url = URL(string: link) else { return nil }
                return ReleaseFeedAsset(
                    name: name,
                    byteSize: asset.size,
                    downloadURL: url,
                    contentType: asset.content_type
                )
            }
            return ReleaseFeedEntry(
                tag: tag,
                title: (release.name?.isEmpty == false ? release.name : tag) ?? tag,
                publishedAt: release.published_at.flatMap { Self.date(from: $0) },
                isPrerelease: release.prerelease ?? false,
                isDraft: release.draft ?? false,
                assets: assets
            )
        }
        guard !entries.isEmpty else { return .failure(.noEntries) }
        return .success(entries)
    }

    /// The default decoder: ISO-8601 dates, tolerant of fractional seconds.
    static func makeDefaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { box in
            let container = try box.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = formatter.date(from: raw) { return date }
            if let date = fallback.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: box.codingPath,
                debugDescription: "Unrecognized date format"
            ))
        }
        return decoder
    }

    private static func date(from raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }
}
