import Foundation

/// Safe memory and byte bounds for Resource & Asset Studio inspection and previews.
///
/// Ensures ZynSign maintains low memory usage, responsive scrolling, and bounded
/// reads even on gigantic applications.
public enum ResourceStudioLimits {

    /// Bounded prefix read for parsing image dimensions (PNG, JPEG, GIF, WebP).
    public static let imageHeaderPrefixBytes: Int = 4 * 1024

    /// Maximum full image read allowed for high-resolution gallery previews.
    public static let maximumImagePreviewBytes: Int = 12 * 1024 * 1024

    /// Bounded read for font table inspection.
    public static let fontHeaderPrefixBytes: Int = 64 * 1024

    /// Maximum font file read for in-memory registration and typography rendering.
    public static let maximumFontRegistrationBytes: Int = 16 * 1024 * 1024

    /// Maximum strings or stringsdict file read for parsing localization tables.
    public static let maximumStringsFileBytes: Int = 2 * 1024 * 1024

    /// Maximum audio file read for in-memory audio playback.
    public static let maximumAudioPlaybackBytes: Int = 32 * 1024 * 1024

    /// Maximum video header read for timescale, duration, and dimension inspection.
    public static let videoHeaderPrefixBytes: Int = 128 * 1024

    /// Maximum video file read for staging to temporary playback.
    public static let maximumVideoPlaybackBytes: Int = 64 * 1024 * 1024

    /// Maximum number of cached thumbnails held in memory simultaneously.
    public static let thumbnailCacheLimit: Int = 250
}
