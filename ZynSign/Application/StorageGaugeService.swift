import Foundation

/// Measures the volume the application lives on and the application's own
/// footprint, and classifies the result.
///
/// The service is a thin, testable boundary over the platform's volume
/// query: the facts-gathering closure is injectable, and everything after
/// the facts is pure classification in `StorageGaugeReading`.
struct StorageGaugeService: Sendable {

    /// Supplies the raw volume facts. The production implementation asks the
    /// file system; tests substitute canned numbers.
    private let gather: @Sendable (URL) -> VolumeCapacityFacts

    init(gather: @escaping @Sendable (URL) -> VolumeCapacityFacts = { directory in
        StorageGaugeService.gatherFacts(at: directory)
    }) {
        self.gather = gather
    }

    /// Reads and classifies the storage situation for the volume holding
    /// `directory`.
    func reading(for directory: URL) -> StorageGaugeReading {
        StorageGaugeReading(facts: gather(directory))
    }

    /// The production facts gatherer: total and available capacity from the
    /// volume, plus the application container's own size, each independently
    /// optional because any one query can fail without sinking the others.
    static func gatherFacts(at directory: URL) -> VolumeCapacityFacts {
        let keys: [URLResourceKey] = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try? directory.resourceValues(forKeys: Set(keys))
        let total = values?.volumeTotalCapacity
        let available = values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
        return VolumeCapacityFacts(
            totalBytes: total,
            availableBytes: available,
            appUsageBytes: containerUsage(at: directory)
        )
    }

    /// Walks the container directory once, bounded, to measure how much of
    /// the volume the application itself occupies. The walk stops at the
    /// entry bound rather than running away on a pathological tree.
    static func containerUsage(at root: URL) -> Int? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total = 0
        var visited = 0
        let entryBound = 50_000
        for case let url as URL in enumerator {
            visited += 1
            if visited > entryBound { break }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += size
        }
        return total
    }
}
