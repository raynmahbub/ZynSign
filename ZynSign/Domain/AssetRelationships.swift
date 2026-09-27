import Foundation

/// Groups related app icon variants into one logical icon set.
public struct AppIconSetGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let name: String
    public let isPrimary: Bool
    public let icons: [AppIconAsset]

    public var count: Int { icons.count }

    public var resolutionsSummary: String {
        let resolutions = icons.compactMap { $0.dimensionsDescription }.filter { $0 != "Unknown size" }
        let unique = Array(Set(resolutions)).sorted()
        return unique.isEmpty ? "\(count) variants" : unique.prefix(3).joined(separator: ", ")
    }

    public init(name: String, isPrimary: Bool, icons: [AppIconAsset]) {
        self.id = name
        self.name = name
        self.isPrimary = isPrimary
        self.icons = icons.sorted { ($0.pixelWidth ?? 0) > ($1.pixelWidth ?? 0) }
    }
}

/// Groups launch assets (storyboards, nibs, images) into one launch presentation group.
public struct LaunchAssetGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let name: String
    public let activeLaunchType: LaunchScreenAsset.LaunchType
    public let storyboardPaths: [BundlePath]
    public let launchImages: [ImageAsset]
    public let launchNibEntries: [BundlePath]

    public var totalCount: Int {
        storyboardPaths.count + launchImages.count + launchNibEntries.count
    }

    public init(
        name: String = "Launch Assets",
        activeLaunchType: LaunchScreenAsset.LaunchType,
        storyboardPaths: [BundlePath],
        launchImages: [ImageAsset],
        launchNibEntries: [BundlePath]
    ) {
        self.id = name
        self.name = name
        self.activeLaunchType = activeLaunchType
        self.storyboardPaths = storyboardPaths
        self.launchImages = launchImages
        self.launchNibEntries = launchNibEntries
    }
}

/// Groups localized string tables across multiple languages (e.g. `Localizable.strings` in en, fr, de, ja).
public struct LocalizationTableGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let tableName: String
    public let languages: [String]
    public let files: [LocalizationFileAsset]
    public let totalKeys: Int

    public var languageCount: Int { languages.count }

    public init(tableName: String, files: [LocalizationFileAsset]) {
        self.id = tableName
        self.tableName = tableName
        self.files = files
        self.languages = Array(Set(files.map(\.languageCode))).sorted()
        self.totalKeys = files.reduce(0) { $0 + $1.keyCount }
    }
}

/// Groups font weight and style variations under their shared font family.
public struct FontFamilyGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let familyName: String
    public let styles: [String]
    public let fonts: [FontAsset]

    public var count: Int { fonts.count }

    public var stylesSummary: String {
        styles.joined(separator: ", ")
    }

    public init(familyName: String, fonts: [FontAsset]) {
        self.id = familyName
        self.familyName = familyName
        self.fonts = fonts.sorted { $0.style.localizedStandardCompare($1.style) == .orderedAscending }
        self.styles = Array(Set(fonts.map(\.style))).sorted()
    }
}

/// Holds all structured relationships between bundled resources.
public struct AssetRelationships: Equatable, Hashable, Sendable {

    public let iconSets: [AppIconSetGroup]
    public let launchAssets: LaunchAssetGroup
    public let localizationTables: [LocalizationTableGroup]
    public let fontFamilies: [FontFamilyGroup]

    public init(
        iconSets: [AppIconSetGroup] = [],
        launchAssets: LaunchAssetGroup = LaunchAssetGroup(
            activeLaunchType: .none,
            storyboardPaths: [],
            launchImages: [],
            launchNibEntries: []
        ),
        localizationTables: [LocalizationTableGroup] = [],
        fontFamilies: [FontFamilyGroup] = []
    ) {
        self.iconSets = iconSets
        self.launchAssets = launchAssets
        self.localizationTables = localizationTables
        self.fontFamilies = fontFamilies
    }

    public static let empty = AssetRelationships()
}

/// Derives structured relationships from raw resource collections.
public enum AssetRelationshipGrouper {

    public static func group(
        icons: [AppIconAsset],
        launch: LaunchScreenAsset,
        localizations: [LocalizationFileAsset],
        fonts: [FontAsset]
    ) -> AssetRelationships {
        // 1. Group icons by set name (Primary vs Alternate vs others)
        var iconsBySet: [String: [AppIconAsset]] = [:]
        for icon in icons {
            let setName = icon.isPrimary ? "Primary App Icon" : (icon.isAlternate ? "Alternate: \(icon.iconSetName)" : icon.iconSetName)
            iconsBySet[setName, default: []].append(icon)
        }
        let iconSets = iconsBySet.map { name, setIcons in
            AppIconSetGroup(name: name, isPrimary: setIcons.contains { $0.isPrimary }, icons: setIcons)
        }.sorted { ($0.isPrimary ? 0 : 1) < ($1.isPrimary ? 0 : 1) }

        // 2. Launch assets
        let launchGroup = LaunchAssetGroup(
            name: "Launch Assets",
            activeLaunchType: launch.activeType,
            storyboardPaths: launch.storyboardPaths,
            launchImages: launch.launchImages,
            launchNibEntries: launch.launchNibEntries
        )

        // 3. Group localization files by table name
        var locByTable: [String: [LocalizationFileAsset]] = [:]
        for loc in localizations {
            locByTable[loc.tableName, default: []].append(loc)
        }
        let localizationTables = locByTable.map { table, files in
            LocalizationTableGroup(tableName: table, files: files)
        }.sorted { $0.tableName.localizedStandardCompare($1.tableName) == .orderedAscending }

        // 4. Group fonts by family name
        var fontsByFamily: [String: [FontAsset]] = [:]
        for font in fonts {
            fontsByFamily[font.fontFamily, default: []].append(font)
        }
        let fontFamilies = fontsByFamily.map { family, familyFonts in
            FontFamilyGroup(familyName: family, fonts: familyFonts)
        }.sorted { $0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending }

        return AssetRelationships(
            iconSets: iconSets,
            launchAssets: launchGroup,
            localizationTables: localizationTables,
            fontFamilies: fontFamilies
        )
    }
}
