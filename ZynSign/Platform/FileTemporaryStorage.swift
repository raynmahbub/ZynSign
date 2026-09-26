import Foundation

/// The platform implementation of `TemporaryDataCleaning` over the
/// directories ZynSign stages work in.
///
/// Those directories hold staging copies of imported packages, the working
/// copies signing operations are made from, and the containers operations
/// were still writing when they were interrupted. Three rules shape what this
/// type will and will not do:
///
/// - **It only looks inside the directories it was given.** An entry outside
///   them is never a candidate, and the managed directories themselves are
///   never removed — only their contents.
/// - **It only removes entries that are old enough.** An entry is old when
///   its newest content modification is older than the cutoff; that is what
///   keeps an operation that is running right now — which keeps writing files
///   — out of reach, and what makes recovery safe to run whenever the Export
///   Center appears.
/// - **It reports what it left alone.** An entry that is too young, or that
///   could not be removed, is counted as skipped rather than ignored, so a
///   cleanup's report is a complete account of what happened.
final class FileTemporaryStorage: TemporaryDataCleaning, Sendable {

    /// The directories whose contents this cleaner manages.
    let directories: [URL]

    init(directories: [URL]) {
        self.directories = directories
    }

    func temporaryDataUsage() throws -> (byteCount: Int, fileCount: Int) {
        var usage = FileSystemMeasurement.Usage.none
        for directory in directories {
            usage = usage + FileSystemMeasurement.usage(of: directory)
        }
        return (byteCount: usage.byteCount, fileCount: usage.fileCount)
    }

    func removeTemporaryData(olderThan cutoff: Date) throws -> TemporaryStorageCleanup {
        var removedFiles = 0
        var freedBytes = 0
        var skipped = 0

        for directory in directories {
            for entry in Self.contents(of: directory) {
                guard let newest = FileSystemMeasurement.newestModificationDate(of: entry) else {
                    // Nothing could be read about the entry, so nothing is
                    // claimed about its age: it is left alone and reported.
                    skipped += 1
                    continue
                }
                guard newest < cutoff else {
                    skipped += 1
                    continue
                }
                let entryUsage = FileSystemMeasurement.usage(of: entry)
                do {
                    try FileManager.default.removeItem(at: entry)
                    removedFiles += max(1, entryUsage.fileCount)
                    freedBytes += entryUsage.byteCount
                } catch {
                    skipped += 1
                }
            }
        }
        return TemporaryStorageCleanup(
            removedFileCount: removedFiles,
            freedByteCount: freedBytes,
            skippedItemCount: skipped
        )
    }

    /// The entries inside `directory` — never the directory itself.
    private static func contents(of directory: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
