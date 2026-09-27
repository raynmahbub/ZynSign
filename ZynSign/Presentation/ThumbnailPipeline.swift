import SwiftUI
import UIKit

/// The presentation side of the thumbnail cache: decoded images, ready to
/// draw, keyed by thumbnail.
///
/// `ThumbnailCache` holds encoded bytes; drawing needs a decoded bitmap,
/// and decoding is the expensive step SwiftUI would otherwise repeat every
/// time an `Image(uiImage:)` is created from `Data`. The pipeline decodes
/// each thumbnail once, off the main actor, keeps the `UIImage` in an
/// `NSCache` bounded by pixel cost, and hands rows a synchronous hit when
/// the image is already there — so a row scrolling back into view draws
/// its icon in the same frame, with no placeholder flash.
///
/// The pipeline is a memory participant: a warning halves its budget's
/// worth of images, critical empties it, and either way the encoded bytes
/// and the disk tier still make the next draw cheap.
final class ThumbnailPipeline: ObservableObject, MemoryTrimmable, @unchecked Sendable {

    /// The encoded-bytes tier, or `nil` when the composition has none — in
    /// which case rows fall back to the icon extraction directly.
    let cache: ThumbnailCache?

    /// The icon extraction the fallback path reads.
    let icons: AppIconExtraction?

    private let images = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [ThumbnailKey: Task<UIImage?, Never>] = [:]

    /// Decodes counted this launch, for the diagnostics table.
    private(set) var decodeCount = 0

    /// The default budget: roughly 600 small icons' worth of pixels.
    private let pixelBudget = 24 * 1_024 * 1_024

    init(cache: ThumbnailCache?, icons: AppIconExtraction?) {
        self.cache = cache
        self.icons = icons
        images.totalCostLimit = pixelBudget
        images.countLimit = 2_000
    }

    /// A pipeline over the engine's caches, registered with its memory
    /// manager.
    convenience init(engine: PerformanceEngine?, icons: AppIconExtraction?) {
        self.init(cache: engine?.thumbnails, icons: icons)
        if let engine {
            Task { await engine.memory.register(self) }
        }
    }

    // MARK: - Reading

    /// The decoded image if it is already in memory. Safe to call while a
    /// row is being laid out.
    func cachedImage(for key: ThumbnailKey) -> UIImage? {
        images.object(forKey: key.cacheName)
    }

    /// The decoded image, loading and decoding it if necessary. Concurrent
    /// requests for the same key share one load.
    func image(for key: ThumbnailKey) async -> UIImage? {
        if let cached = cachedImage(for: key) {
            return cached
        }
        let task: Task<UIImage?, Never>
        lock.lock()
        if let existing = inFlight[key] {
            task = existing
            lock.unlock()
        } else {
            task = Task<UIImage?, Never>(priority: .utility) { [weak self] in
                guard let self else { return nil }
                let data: Data?
                if let cache = self.cache {
                    data = await cache.thumbnail(for: key)
                } else if key.source == .icon, let icons = self.icons {
                    data = await icons.iconData(for: key.artifactID)
                } else {
                    data = nil
                }
                guard let data, let image = UIImage(data: data) else { return nil }
                let prepared = await image.byPreparingForDisplay() ?? image
                self.store(prepared, for: key)
                return prepared
            }
            inFlight[key] = task
            lock.unlock()
        }
        let image = await task.value
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
        return image
    }

    // MARK: - MemoryTrimmable

    var trimmableName: String { "Decoded thumbnails" }

    func trimMemory(level: MemoryPressureLevel) async {
        switch level {
        case .nominal:
            break
        case .warning:
            // NSCache has no partial trim; halving the limit evicts down to
            // it, and restoring the limit lets the cache refill.
            images.totalCostLimit = pixelBudget / 2
            images.totalCostLimit = pixelBudget
        case .critical:
            images.removeAllObjects()
        }
    }

    /// Forgets every decoded image of `artifactID`.
    func forget(artifactID: ArtifactIdentifier) {
        for source in ThumbnailSource.allSources {
            for variant in ThumbnailVariant.allCases {
                images.removeObject(forKey: ThumbnailKey(artifactID: artifactID, source: source, variant: variant).cacheName)
            }
        }
    }

    // MARK: - Private

    private func store(_ image: UIImage, for key: ThumbnailKey) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        images.setObject(image, forKey: key.cacheName, cost: max(1, cost))
        lock.lock()
        decodeCount += 1
        lock.unlock()
    }
}

private extension ThumbnailKey {
    var cacheName: NSString { fileName as NSString }
}

// MARK: - Environment

private struct ThumbnailPipelineKey: EnvironmentKey {
    static let defaultValue = ThumbnailPipeline(cache: nil, icons: nil)
}

extension EnvironmentValues {

    /// The decoded-thumbnail pipeline the rows and cards draw from. The
    /// shell installs one over the application's Performance Engine; the
    /// default draws nothing but placeholders, which is what a preview or a
    /// test wants.
    var thumbnailPipeline: ThumbnailPipeline {
        get { self[ThumbnailPipelineKey.self] }
        set { self[ThumbnailPipelineKey.self] = newValue }
    }
}
