import Foundation

/// Common interface for any resource discovered inside an IPA bundle.
public protocol ResourceItem: Identifiable, Sendable {
    var id: String { get }
    var bundlePath: BundlePath { get }
    var fileName: String { get }
    var fileSize: Int { get }
    var category: ResourceCategory { get }
    var format: String { get }
    var detailsText: String { get }
}

/// An app icon discovered in the bundle or declared in Info.plist.
public struct AppIconAsset: ResourceItem, Equatable, Hashable, Sendable {

    public enum Role: String, Equatable, Hashable, Sendable {
        case primary = "Primary"
        case alternate = "Alternate"
        case standard = "Standard"
        case document = "Document"
    }

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let role: Role
    public let isPrimary: Bool
    public let isAlternate: Bool
    public let iconSetName: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let scale: Int?
    public let idiom: String?
    public let category: ResourceCategory = .icon

    public var dimensions: (width: Int, height: Int)? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return (pixelWidth, pixelHeight)
    }

    public var dimensionsDescription: String {
        if let pixelWidth, let pixelHeight {
            return "\(pixelWidth) × \(pixelHeight)"
        }
        return "Unknown size"
    }

    public var roleDescription: String {
        if isPrimary { return "Primary Icon" }
        if isAlternate { return "Alternate Icon (\(iconSetName))" }
        return "Icon Asset"
    }

    public var detailsText: String {
        var parts: [String] = []
        if let scale {
            parts.append("@\(scale)x")
        }
        if let idiom {
            parts.append(idiom.capitalized)
        }
        if let pixelWidth, let pixelHeight {
            parts.append("\(pixelWidth)×\(pixelHeight)")
        }
        return parts.isEmpty ? roleDescription : parts.joined(separator: " · ")
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String = "PNG",
        role: Role = .standard,
        isPrimary: Bool = false,
        isAlternate: Bool = false,
        iconSetName: String = "AppIcon",
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        scale: Int? = nil,
        idiom: String? = nil
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.role = role
        self.isPrimary = isPrimary
        self.isAlternate = isAlternate
        self.iconSetName = iconSetName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.idiom = idiom
    }
}

/// Discovered launch screen assets and declared launch configuration.
public struct LaunchScreenAsset: Equatable, Hashable, Sendable {

    public enum LaunchType: String, Equatable, Hashable, Sendable {
        case storyboard = "Storyboard"
        case launchScreenNib = "Compiled NIB"
        case launchScreenPlist = "Info.plist Configuration"
        case launchImages = "Static Launch Images"
        case none = "None Declared"

        public var displayName: String { rawValue }
    }

    public let activeType: LaunchType
    public let activeAssetSummary: String
    public let storyboardPaths: [BundlePath]
    public let launchImages: [ImageAsset]
    public let launchNibEntries: [BundlePath]
    public let declaredStoryboardName: String?
    public let declaredConfiguration: [String: String]

    public var totalAssetCount: Int {
        storyboardPaths.count + launchImages.count + launchNibEntries.count
    }

    public init(
        activeType: LaunchType = .none,
        activeAssetSummary: String = "No launch asset detected",
        storyboardPaths: [BundlePath] = [],
        launchImages: [ImageAsset] = [],
        launchNibEntries: [BundlePath] = [],
        declaredStoryboardName: String? = nil,
        declaredConfiguration: [String: String] = [:]
    ) {
        self.activeType = activeType
        self.activeAssetSummary = activeAssetSummary
        self.storyboardPaths = storyboardPaths
        self.launchImages = launchImages
        self.launchNibEntries = launchNibEntries
        self.declaredStoryboardName = declaredStoryboardName
        self.declaredConfiguration = declaredConfiguration
    }

    public static let empty = LaunchScreenAsset()
}

/// An image asset discovered inside the bundle.
public struct ImageAsset: ResourceItem, Equatable, Hashable, Sendable {

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let scale: Int?
    public let isAppIcon: Bool
    public let isLaunchImage: Bool
    public let category: ResourceCategory
    public let tag: String?

    public var dimensions: (width: Int, height: Int)? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return (pixelWidth, pixelHeight)
    }

    public var dimensionsDescription: String {
        if let pixelWidth, let pixelHeight {
            return "\(pixelWidth) × \(pixelHeight)"
        }
        return "Unknown dimensions"
    }

    public var detailsText: String {
        var parts: [String] = []
        if let pixelWidth, let pixelHeight {
            parts.append("\(pixelWidth)×\(pixelHeight)")
        }
        if let scale {
            parts.append("@\(scale)x")
        }
        parts.append(format.uppercased())
        return parts.joined(separator: " · ")
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        scale: Int? = nil,
        isAppIcon: Bool = false,
        isLaunchImage: Bool = false,
        category: ResourceCategory = .image,
        tag: String? = nil
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.isAppIcon = isAppIcon
        self.isLaunchImage = isLaunchImage
        self.category = category
        self.tag = tag
    }
}

/// A bundled font asset.
public struct FontAsset: ResourceItem, Equatable, Hashable, Sendable {

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let fontName: String
    public let fontFamily: String
    public let style: String
    public let previewSentence: String
    public let category: ResourceCategory = .font

    public var detailsText: String {
        "\(fontFamily) · \(style) · \(format.uppercased())"
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String,
        fontName: String,
        fontFamily: String,
        style: String = "Regular",
        previewSentence: String = "The quick brown fox jumps over the lazy dog."
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.style = style
        self.previewSentence = previewSentence
    }
}

/// A bundled audio asset.
public struct AudioAsset: ResourceItem, Equatable, Hashable, Sendable {

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let duration: TimeInterval?
    public let sampleRate: Double?
    public let channelCount: Int?
    public let category: ResourceCategory = .audio

    public var durationFormatted: String {
        guard let duration, duration > 0 else { return "—" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var detailsText: String {
        var parts: [String] = [format.uppercased()]
        if let duration, duration > 0 {
            parts.append(durationFormatted)
        }
        return parts.joined(separator: " · ")
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String,
        duration: TimeInterval? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A bundled video asset.
public struct VideoAsset: ResourceItem, Equatable, Hashable, Sendable {

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let duration: TimeInterval?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let category: ResourceCategory = .video

    public var resolution: (width: Int, height: Int)? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return (pixelWidth, pixelHeight)
    }

    public var resolutionDescription: String {
        if let pixelWidth, let pixelHeight {
            return "\(pixelWidth) × \(pixelHeight)"
        }
        return "Unknown resolution"
    }

    public var durationFormatted: String {
        guard let duration, duration > 0 else { return "—" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var detailsText: String {
        var parts: [String] = [format.uppercased()]
        if let pixelWidth, let pixelHeight {
            parts.append("\(pixelWidth)×\(pixelHeight)")
        }
        if let duration, duration > 0 {
            parts.append(durationFormatted)
        }
        return parts.joined(separator: " · ")
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String,
        duration: TimeInterval? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One localized key-value string entry.
public struct LocalizationEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let comment: String?

    public init(key: String, value: String, comment: String? = nil) {
        self.id = key
        self.key = key
        self.value = value
        self.comment = comment
    }
}

/// A localized `.strings` or `.stringsdict` file asset.
public struct LocalizationFileAsset: ResourceItem, Equatable, Hashable, Sendable {

    public let id: String
    public let bundlePath: BundlePath
    public let fileName: String
    public let fileSize: Int
    public let format: String
    public let languageCode: String
    public let tableName: String
    public let keyCount: Int
    public let entries: [LocalizationEntry]
    public let category: ResourceCategory = .localization

    public var detailsText: String {
        "\(tableName) · \(keyCount) keys · \(languageCode.uppercased())"
    }

    public init(
        bundlePath: BundlePath,
        fileName: String,
        fileSize: Int,
        format: String,
        languageCode: String,
        tableName: String,
        keyCount: Int,
        entries: [LocalizationEntry] = []
    ) {
        self.id = bundlePath.rawValue
        self.bundlePath = bundlePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.format = format
        self.languageCode = languageCode
        self.tableName = tableName
        self.keyCount = keyCount
        self.entries = entries
    }
}

/// A group of localization files under one `.lproj` folder.
public struct LocalizationLanguageGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let languageCode: String
    public let displayName: String
    public let lprojPath: BundlePath
    public let files: [LocalizationFileAsset]
    public let totalKeyCount: Int

    public var fileCount: Int { files.count }

    public init(
        languageCode: String,
        displayName: String,
        lprojPath: BundlePath,
        files: [LocalizationFileAsset],
        totalKeyCount: Int
    ) {
        self.id = languageCode
        self.languageCode = languageCode
        self.displayName = displayName
        self.lprojPath = lprojPath
        self.files = files
        self.totalKeyCount = totalKeyCount
    }
}
