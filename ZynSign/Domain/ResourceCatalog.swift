import Foundation

/// The complete, read-only aggregate catalog of resources discovered inside an IPA.
///
/// Holds parsed and indexed assets across all categories: icons, launch assets,
/// images, fonts, localizations, audio, video, duplicates, and relationships.
public struct ResourceCatalog: @unchecked Sendable {

    public let summary: ResourceSummary
    public let icons: [AppIconAsset]
    public let launchAsset: LaunchScreenAsset
    public let images: [ImageAsset]
    public let fonts: [FontAsset]
    public let localizations: [LocalizationLanguageGroup]
    public let localizationFiles: [LocalizationFileAsset]
    public let audio: [AudioAsset]
    public let videos: [VideoAsset]
    public let duplicates: ResourceDuplicateReport
    public let relationships: AssetRelationships
    public let searchIndex: ResourceSearchIndex

    public var primaryIcon: AppIconAsset? {
        icons.first(where: { $0.isPrimary }) ?? icons.first
    }

    public var alternateIcons: [AppIconAsset] {
        icons.filter { $0.isAlternate }
    }

    public var allAssets: [any ResourceItem] {
        var items: [any ResourceItem] = []
        items.append(contentsOf: icons)
        items.append(contentsOf: images)
        items.append(contentsOf: fonts)
        items.append(contentsOf: localizationFiles)
        items.append(contentsOf: audio)
        items.append(contentsOf: videos)
        return items
    }

    public init(
        summary: ResourceSummary = .empty,
        icons: [AppIconAsset] = [],
        launchAsset: LaunchScreenAsset = .empty,
        images: [ImageAsset] = [],
        fonts: [FontAsset] = [],
        localizations: [LocalizationLanguageGroup] = [],
        localizationFiles: [LocalizationFileAsset] = [],
        audio: [AudioAsset] = [],
        videos: [VideoAsset] = [],
        duplicates: ResourceDuplicateReport = .empty,
        relationships: AssetRelationships = .empty,
        searchIndex: ResourceSearchIndex? = nil
    ) {
        self.summary = summary
        self.icons = icons
        self.launchAsset = launchAsset
        self.images = images
        self.fonts = fonts
        self.localizations = localizations
        self.localizationFiles = localizationFiles
        self.audio = audio
        self.videos = videos
        self.duplicates = duplicates
        self.relationships = relationships
        self.searchIndex = searchIndex ?? ResourceSearchIndex(
            icons: icons,
            launchImages: launchAsset.launchImages,
            images: images,
            fonts: fonts,
            localizationFiles: localizationFiles,
            audio: audio,
            videos: videos
        )
    }

    /// Finds a resource item matching the specified bundle path.
    public func item(at path: BundlePath) -> (any ResourceItem)? {
        allAssets.first { $0.bundlePath == path }
    }

    public static let empty = ResourceCatalog()
}
