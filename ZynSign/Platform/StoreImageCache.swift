import Foundation
import UIKit
import CryptoKit
import ImageIO

/// Separate evictable artwork cache. Metadata lives in Application Support;
/// images may be purged by the OS. No promise that unseen artwork is available offline.
actor StoreImageCache {
    static let shared = StoreImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let directory: URL
    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("StoreArtwork")
        memory.totalCostLimit = 40 * 1024 * 1024
    }
    func image(_ url: URL) async -> UIImage? {
        guard (try? StoreURLPolicy.validate(url.absoluteString)) != nil else { return nil }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = inFlight[url] { return await task.value }
        let path = directory.appendingPathComponent(key)
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: path), let image = Self.decode(data) { return image }
            guard let response = try? await StoreHTTPClient().fetch(url, limit: 12 * 1024 * 1024),
                  let image = Self.decode(response.data) else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try response.data.write(to: path, options: .atomic)
                evict()
            } catch { /* Artwork storage is best effort; metadata errors are not. */ }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
    private static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 12 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 16_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private func evict() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > 150 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: entry.0); total -= entry.1
        }
    }
}
