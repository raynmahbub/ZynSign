import Foundation

/// The functional category of one bundled application resource.
///
/// Categorization is derived from location, file extension, and bundle role
/// without requiring the entire entry to be parsed or decoded. It serves as
/// the primary organization and filtering axis in Resource & Asset Studio.
public enum ResourceCategory: String, CaseIterable, Hashable, Identifiable, Sendable {

    /// Application icon assets, including primary, alternate, and device-scaled variants.
    case icon

    /// Launch screen assets, including storyboards, nibs, and static launch images.
    case launch

    /// General visual images and artwork in the bundle or asset catalogs.
    case image

    /// Bundled TrueType, OpenType, and collection font assets.
    case font

    /// Audio media resources (MP3, WAV, M4A, CAF, AAC, etc.).
    case audio

    /// Video media resources (MP4, MOV, M4V, etc.).
    case video

    /// Localized string tables, dictionaries, and `.lproj` folders.
    case localization

    /// Other bundled resources not falling into the main categories.
    case other

    public var id: String { rawValue }

    /// A user-presentable human title for dashboard cards and navigation.
    public var displayName: String {
        switch self {
        case .icon: return "Icons"
        case .launch: return "Launch Assets"
        case .image: return "Images"
        case .font: return "Fonts"
        case .audio: return "Audio"
        case .video: return "Videos"
        case .localization: return "Localization Files"
        case .other: return "Other Resources"
        }
    }

    /// SF Symbol icon representing this resource category.
    public var systemImage: String {
        switch self {
        case .icon: return "app.badge"
        case .launch: return "arrow.up.right.video"
        case .image: return "photo"
        case .font: return "textformat"
        case .audio: return "waveform"
        case .video: return "film"
        case .localization: return "globe"
        case .other: return "doc"
        }
    }
}

/// The top-level filters available in the Resource Studio.
public enum ResourceFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all = "All"
    case images = "Images"
    case icons = "Icons"
    case fonts = "Fonts"
    case audio = "Audio"
    case video = "Video"
    case localization = "Localization"
    case largeFiles = "Large Files"

    public var id: String { rawValue }

    /// The SF symbol representing this filter.
    public var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .images: return "photo"
        case .icons: return "app.badge"
        case .fonts: return "textformat"
        case .audio: return "waveform"
        case .video: return "film"
        case .localization: return "globe"
        case .largeFiles: return "arrow.up.circle"
        }
    }

    /// Whether a resource item with the given category and size matches this filter.
    public func matches(category: ResourceCategory, fileSize: Int, largeFileThreshold: Int = 1_000_000) -> Bool {
        switch self {
        case .all:
            return true
        case .images:
            return category == .image || category == .icon || category == .launch
        case .icons:
            return category == .icon
        case .fonts:
            return category == .font
        case .audio:
            return category == .audio
        case .video:
            return category == .video
        case .localization:
            return category == .localization
        case .largeFiles:
            return fileSize >= largeFileThreshold
        }
    }
}

/// The count breakdown of resources discovered inside an application bundle.
///
/// This structure directly powers the Asset Dashboard summary cards and the
/// quick overview in the Application Details screen.
public struct ResourceSummary: Equatable, Hashable, Sendable {

    public let iconCount: Int
    public let launchAssetCount: Int
    public let imageCount: Int
    public let fontCount: Int
    public let audioCount: Int
    public let videoCount: Int
    public let localizationCount: Int
    public let totalResourceCount: Int
    public let totalByteCount: Int
    public let duplicateCount: Int
    public let wastedDuplicateBytes: Int

    public init(
        iconCount: Int = 0,
        launchAssetCount: Int = 0,
        imageCount: Int = 0,
        fontCount: Int = 0,
        audioCount: Int = 0,
        videoCount: Int = 0,
        localizationCount: Int = 0,
        totalResourceCount: Int = 0,
        totalByteCount: Int = 0,
        duplicateCount: Int = 0,
        wastedDuplicateBytes: Int = 0
    ) {
        self.iconCount = iconCount
        self.launchAssetCount = launchAssetCount
        self.imageCount = imageCount
        self.fontCount = fontCount
        self.audioCount = audioCount
        self.videoCount = videoCount
        self.localizationCount = localizationCount
        self.totalResourceCount = totalResourceCount
        self.totalByteCount = totalByteCount
        self.duplicateCount = duplicateCount
        self.wastedDuplicateBytes = wastedDuplicateBytes
    }

    /// Resolves the count for a specific category.
    public subscript(category: ResourceCategory) -> Int {
        switch category {
        case .icon: return iconCount
        case .launch: return launchAssetCount
        case .image: return imageCount
        case .font: return fontCount
        case .audio: return audioCount
        case .video: return videoCount
        case .localization: return localizationCount
        case .other: return max(0, totalResourceCount - (iconCount + launchAssetCount + imageCount + fontCount + audioCount + videoCount + localizationCount))
        }
    }

    /// Empty summary placeholder.
    public static let empty = ResourceSummary()
}
