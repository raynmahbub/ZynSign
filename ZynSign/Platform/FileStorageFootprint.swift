import Foundation

/// The platform implementation of `StorageFootprintReporting`: it measures the
/// locations ZynSign keeps bytes in and reports them in the categories the
/// storage screen shows.
///
/// The locations are supplied by the composition root, so this type knows
/// where bytes live and nothing else. It never creates, repairs, or removes
/// anything: measuring is its whole job, and removal goes through the ports
/// that own each kind of storage. That separation is what makes it impossible
/// for a storage *report* to delete a file.
///
/// Two readings are deliberate:
///
/// - The exported-artifacts category measures the signed-output directory
///   itself, so it reports what that folder actually weighs — including a
///   package a person placed there by hand. The Export Center lists the
///   artifacts ZynSign produced and describes; the number here is storage,
///   not a count of rows.
/// - The history category measures the journal and catalog files. Those
///   files' records are what the history's own cleanup removes; the bytes are
///   the bytes those records occupy.
///
/// A location that cannot be read measures as nothing. The alternative — a
/// storage screen that refuses to open because one folder is unavailable —
/// would be worse than a number that is honest about what was measured.
struct FileStorageFootprint: StorageFootprintReporting, Sendable {

    /// The directory imported applications' packages are kept in.
    let importedApplicationsDirectory: URL

    /// The directory exported artifacts are kept in.
    let exportedArtifactsDirectory: URL

    /// The directories temporary data is staged in.
    let temporaryDirectories: [URL]

    /// The files the signing history and the export catalog live in.
    let historyFiles: [URL]

    init(
        importedApplicationsDirectory: URL,
        exportedArtifactsDirectory: URL,
        temporaryDirectories: [URL],
        historyFiles: [URL]
    ) {
        self.importedApplicationsDirectory = importedApplicationsDirectory
        self.exportedArtifactsDirectory = exportedArtifactsDirectory
        self.temporaryDirectories = temporaryDirectories
        self.historyFiles = historyFiles
    }

    func footprint() throws -> StorageFootprint {
        StorageFootprint(usages: [
            Self.usage(of: importedApplicationsDirectory, category: .importedApplications),
            Self.usage(of: exportedArtifactsDirectory, category: .exportedArtifacts),
            Self.usage(of: temporaryDirectories, category: .temporaryFiles),
            Self.usage(of: historyFiles, category: .history),
        ])
    }

    private static func usage(of directory: URL, category: StorageCategory) -> StorageCategoryUsage {
        let usage = FileSystemMeasurement.usage(of: directory)
        return StorageCategoryUsage(
            category: category,
            byteCount: usage.byteCount,
            itemCount: usage.fileCount
        )
    }

    private static func usage(of directories: [URL], category: StorageCategory) -> StorageCategoryUsage {
        var usage = FileSystemMeasurement.Usage.none
        for directory in directories {
            usage = usage + FileSystemMeasurement.usage(of: directory)
        }
        return StorageCategoryUsage(
            category: category,
            byteCount: usage.byteCount,
            itemCount: usage.fileCount
        )
    }

}
