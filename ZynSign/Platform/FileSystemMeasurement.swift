import Foundation

/// Measures what locations hold, for storage reporting and cleanup.
///
/// Every measurement is bounded twice: by a maximum number of entries and by
/// a maximum depth. The bounds exist so a directory that was replaced by
/// something pathological cannot turn a storage screen into unbounded work.
/// Reaching a bound stops the walk and reports what was counted — a partial
/// count is reported as the count it is, never presented as the whole.
enum FileSystemMeasurement {

    /// How much one location holds.
    struct Usage: Equatable, Sendable {

        /// Bytes held by regular files at or beneath the location.
        let byteCount: Int

        /// How many regular files were counted.
        let fileCount: Int

        static let none = Usage(byteCount: 0, fileCount: 0)

        static func + (lhs: Usage, rhs: Usage) -> Usage {
            Usage(byteCount: lhs.byteCount + rhs.byteCount, fileCount: lhs.fileCount + rhs.fileCount)
        }
    }

    /// The greatest number of entries one walk visits.
    static let maximumEntryCount = 20_000

    /// The greatest depth one walk descends.
    static let maximumDepth = 8

    /// The bytes and file count `location` holds.
    ///
    /// A location that does not exist, or cannot be read, measures as nothing.
    /// Measuring is a report; refusing to produce one would leave the storage
    /// screen with no answer at all.
    static func usage(of location: URL) -> Usage {
        guard let values = try? location.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            return .none
        }
        if values.isRegularFile == true {
            return Usage(byteCount: max(0, values.fileSize ?? 0), fileCount: 1)
        }
        guard values.isDirectory == true else { return .none }
        guard let enumerator = enumerator(at: location) else { return .none }

        var usage = Usage.none
        var visited = 0
        for case let entry as URL in enumerator {
            visited += 1
            if visited > maximumEntryCount || enumerator.level > maximumDepth { break }
            guard let entryValues = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  entryValues.isRegularFile == true else { continue }
            usage = usage + Usage(byteCount: max(0, entryValues.fileSize ?? 0), fileCount: 1)
        }
        return usage
    }

    /// The most recent content modification date at or beneath `location`, or
    /// `nil` when nothing could be read.
    ///
    /// The newest date is what decides whether temporary data is still in use:
    /// an operation that is running keeps writing files, so the newest file
    /// under its directory is what says it is alive.
    static func newestModificationDate(of location: URL) -> Date? {
        guard let values = try? location.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            return nil
        }
        var newest = values.contentModificationDate
        guard values.isDirectory == true, let enumerator = enumerator(at: location) else { return newest }

        var visited = 0
        for case let entry as URL in enumerator {
            visited += 1
            if visited > maximumEntryCount || enumerator.level > maximumDepth { break }
            guard let entryValues = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = entryValues.contentModificationDate else { continue }
            if let currentNewest = newest {
                if date > currentNewest { newest = date }
            } else {
                newest = date
            }
        }
        return newest
    }

    /// The bytes `location` holds, removed or not. Used to report how much a
    /// cleanup freed, measured before the removal runs.
    static func byteCount(of location: URL) -> Int {
        usage(of: location).byteCount
    }

    private static func enumerator(at location: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(
            at: location,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, _ in true }
        )
    }
}
