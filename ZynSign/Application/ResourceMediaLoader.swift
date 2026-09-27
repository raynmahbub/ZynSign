import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Media loader and cache coordinator for Resource Studio previews.
///
/// Ensures images and media assets are loaded lazily, cached safely with
/// memory bounds, and discarded when memory pressure occurs.
public final class ResourceMediaLoader: @unchecked Sendable {

    private let inspection: IPAResourceStudioInspection
    private let cache = NSCache<NSString, NSData>()
    private let tempDirectory: URL

    public init(inspection: IPAResourceStudioInspection) {
        self.inspection = inspection
        self.cache.countLimit = ResourceStudioLimits.thumbnailCacheLimit
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignResourceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    /// Loads raw data for a bundle resource with bounded memory caching.
    public func loadData(
        for bundlePath: BundlePath,
        recordID: ApplicationRecordIdentifier,
        maxBytes: Int = ResourceStudioLimits.maximumImagePreviewBytes
    ) async throws -> Data {
        let cacheKey = NSString(string: "\(recordID.rawValue):\(bundlePath.rawValue)")
        if let cached = cache.object(forKey: cacheKey) {
            return cached as Data
        }

        let data = try await inspection.readEntryData(
            recordWithID: recordID,
            bundlePath: bundlePath,
            maximumBytes: maxBytes
        )
        cache.setObject(data as NSData, forKey: cacheKey)
        return data
    }

    /// Loads and registers a font in-process, returning the registered font family/name.
    public func loadAndRegisterFont(
        for bundlePath: BundlePath,
        recordID: ApplicationRecordIdentifier
    ) async throws -> String? {
        let data = try await inspection.readEntryData(
            recordWithID: recordID,
            bundlePath: bundlePath,
            maximumBytes: ResourceStudioLimits.maximumFontRegistrationBytes
        )
        return CoreTextFontRegistrar.registerFont(from: data)
    }

    /// Stages a video file into a temporary sandbox URL for AVPlayer playback.
    public func stageVideo(
        for bundlePath: BundlePath,
        recordID: ApplicationRecordIdentifier
    ) async throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("\(bundlePath.lastComponent)", isDirectory: false)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let data = try await inspection.readEntryData(
            recordWithID: recordID,
            bundlePath: bundlePath,
            maximumBytes: ResourceStudioLimits.maximumVideoPlaybackBytes
        )
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Clears any cached media and temporary staged files.
    public func clearCache() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
}
