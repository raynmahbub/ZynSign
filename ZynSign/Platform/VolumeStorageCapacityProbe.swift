import Foundation

/// The platform implementation of `StorageCapacityProbe`: asks the volume
/// holding `volume` how much space is available.
///
/// It prefers the capacity for "important" usage — the figure the system
/// intends for storage the user explicitly asked for, which counts space it
/// can reclaim from purgeable caches — and falls back to the plain available
/// capacity. When neither can be read the answer is `nil`, which the import
/// policy treats as unknown rather than as a shortage.
struct VolumeStorageCapacityProbe: StorageCapacityProbe {

    /// Any existing location on the volume to measure.
    let volume: URL

    func availableCapacity() -> Int? {
        if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            return Int(clamping: important)
        }
        if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            return available
        }
        return nil
    }
}
