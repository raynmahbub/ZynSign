import Foundation

/// What the Storage Manager reports on.
///
/// Each category names one thing ZynSign keeps and says where it lives, so a
/// reported number can always be traced back to a location and an action can
/// always be traced back to what it removed. The categories are exhaustive
/// and non-overlapping: a byte ZynSign holds is counted exactly once, so the
/// total is the sum of the rows rather than an estimate.
enum StorageCategory: String, CaseIterable, Sendable {

    /// Packages the library holds, adopted into artifact storage.
    case importedApps

    /// Signed packages ZynSign produced and wrote to Documents.
    case signedArtifacts

    /// Scratch files: staged imports and working copies.
    case temporaryFiles

    /// Derived data the system may reclaim at any time.
    case cache

    /// Journals of what happened: signing history and the activity journal.
    case history

    /// Catalogs and preference documents: records, presets, profiles.
    case records

    /// The row title, as the Storage Manager shows it.
    var title: String {
        switch self {
        case .importedApps: return "Imported Apps"
        case .signedArtifacts: return "Signed Artifacts"
        case .temporaryFiles: return "Temporary Files"
        case .cache: return "Cache"
        case .history: return "History"
        case .records: return "Records"
        }
    }

    /// The SF Symbol for the row.
    var systemImage: String {
        switch self {
        case .importedApps: return "square.stack.3d.up.fill"
        case .signedArtifacts: return "signature"
        case .temporaryFiles: return "clock.arrow.circlepath"
        case .cache: return "internaldrive.fill"
        case .history: return "clock.fill"
        case .records: return "list.bullet.rectangle.fill"
        }
    }

    /// One sentence describing what the row counts.
    var explanation: String {
        switch self {
        case .importedApps:
            return "The packages ZynSign's library holds, one file per imported application."
        case .signedArtifacts:
            return "Signed packages ZynSign produced, in Documents/Signed."
        case .temporaryFiles:
            return "Staged imports and working copies in the system temporary directory."
        case .cache:
            return "Derived data — extracted application icons — the system may reclaim at any time."
        case .history:
            return "The signing history journal, the on-device activity journal, and the technical log."
        case .records:
            return "Catalogs and preference documents: library records, presets, and profiles."
        }
    }

    /// The locations this category occupies.
    func locations(in locations: StorageLocations) -> [URL] {
        switch self {
        case .importedApps: return [locations.libraryArtifacts]
        case .signedArtifacts: return [locations.signedArtifacts]
        case .temporaryFiles: return [locations.temporary]
        case .cache: return [locations.caches]
        case .history:
            return [
                locations.signingHistoryJournal,
                locations.analyticsJournal,
                locations.diagnosticsLog
            ]
        case .records:
            return [
                locations.libraryCatalog,
                locations.signingPresetsCatalog,
                locations.provisioningProfilesCatalog,
                locations.preferencesDocument
            ]
        }
    }

    /// Whether the category's locations are shared with the system, so that
    /// only ZynSign's own entries inside them may be counted or removed.
    var countsOnlyZynSignOwnedEntries: Bool {
        switch self {
        case .temporaryFiles, .cache: return true
        case .importedApps, .signedArtifacts, .history, .records: return false
        }
    }

    /// ZynSign-owned entry names this category never removes, even inside a
    /// shared directory.
    ///
    /// Exported reports and certificate backups are things the user asked
    /// ZynSign to write; clearing scratch is not permission to take them.
    var preservedEntryNames: Set<String> {
        switch self {
        case .temporaryFiles: return [ZynSignStorageLayout.exportDirectoryName.lowercased()]
        case .importedApps, .signedArtifacts, .cache, .history, .records: return []
        }
    }
}

/// Where each thing ZynSign keeps lives.
///
/// Resolved once and handed to the Storage Manager, so measurement, cleanup,
/// and the locations the Settings area displays all come from the same value.
struct StorageLocations: Sendable {

    /// Adopted package artifacts.
    var libraryArtifacts: URL

    /// Signed packages ZynSign produced.
    var signedArtifacts: URL

    /// The system temporary directory.
    var temporary: URL

    /// The system caches directory.
    var caches: URL

    /// The root of durable library storage, holding catalogs and journals.
    var libraryMetadata: URL

    /// Exported reports and certificate backups.
    var export: URL

    /// The signing history journal.
    var signingHistoryJournal: URL

    /// The on-device activity journal.
    var analyticsJournal: URL

    /// The opt-in technical log.
    var diagnosticsLog: URL

    /// The library record catalog.
    var libraryCatalog: URL

    /// The signing preset catalog.
    var signingPresetsCatalog: URL

    /// The provisioning profile catalog.
    var provisioningProfilesCatalog: URL

    /// The preferences document.
    var preferencesDocument: URL

    /// Resolves the locations from the storage layout.
    static func resolve(fileManager: FileManager = .default) -> StorageLocations {
        StorageLocations(
            libraryArtifacts: ZynSignStorageLayout.artifactsDirectory(fileManager: fileManager),
            signedArtifacts: ZynSignStorageLayout.signedArtifactsDirectory(fileManager: fileManager),
            temporary: ZynSignStorageLayout.temporary(fileManager: fileManager),
            caches: ZynSignStorageLayout.caches(fileManager: fileManager),
            libraryMetadata: ZynSignStorageLayout.libraryRoot(fileManager: fileManager),
            export: ZynSignStorageLayout.exportDirectory(fileManager: fileManager),
            signingHistoryJournal: ZynSignStorageLayout.signingHistoryJournal(fileManager: fileManager),
            analyticsJournal: ZynSignStorageLayout.analyticsJournal(fileManager: fileManager),
            diagnosticsLog: ZynSignStorageLayout.diagnosticsLog(fileManager: fileManager),
            libraryCatalog: ZynSignStorageLayout.libraryCatalog(fileManager: fileManager),
            signingPresetsCatalog: ZynSignStorageLayout.signingPresetsCatalog(fileManager: fileManager),
            provisioningProfilesCatalog: ZynSignStorageLayout.provisioningProfilesCatalog(fileManager: fileManager),
            preferencesDocument: ZynSignStorageLayout.preferencesDocument(fileManager: fileManager)
        )
    }
}

/// What the Storage Manager measured.
struct StorageUsageReport: Equatable, Sendable {

    /// Allocated bytes per category.
    var usage: [StorageCategory: Int64]

    /// When the measurement was taken.
    var measuredAt: Date

    /// Everything ZynSign holds.
    var total: Int64 { usage.values.reduce(0, +) }

    /// Allocated bytes for `category`.
    func bytes(for category: StorageCategory) -> Int64 { usage[category] ?? 0 }

    /// `category`'s share of the total, 0…1.
    func fraction(for category: StorageCategory) -> Double {
        guard total > 0 else { return 0 }
        return Double(bytes(for: category)) / Double(total)
    }

    /// The categories in the order the Storage Manager lists them.
    var orderedCategories: [StorageCategory] { StorageCategory.allCases }
}

/// What one cleanup action did.
struct StorageCleanupOutcome: Equatable, Sendable {

    /// How many entries were removed.
    var removedItemCount: Int

    /// How many bytes were freed.
    var reclaimedBytes: Int64

    /// One presentation-safe sentence describing the outcome. Names no file,
    /// no path, and no application.
    var message: String

    /// Whether anything was actually removed.
    var removedAnything: Bool { removedItemCount > 0 }
}

/// One file the Storage Manager can show in "review large files".
struct StoredFileDescription: Identifiable, Equatable, Sendable {

    /// Where the file is.
    var url: URL

    /// How much space it takes.
    var byteCount: Int64

    /// When it was last written.
    var modifiedAt: Date

    /// Which category it belongs to.
    var category: StorageCategory

    var id: String { url.path }

    /// The file's name.
    var name: String { url.lastPathComponent }

    /// The size, formatted for display.
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// The last-written date, formatted for display.
    var formattedDate: String {
        modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Measures and tidies ZynSign's own storage.
///
/// The service is an actor because measuring means walking directories: the
/// walk runs off the main actor, so the Storage Manager stays responsive
/// while it reports, and nothing it returns is a partially measured total.
///
/// Two rules bound everything it does:
///
/// - **Only ZynSign's own files.** The temporary and caches directories are
///   shared with the system, so both measurement and removal are restricted
///   to entries ZynSign created, and the entries a category preserves are
///   never touched. No other application's data is read or removed.
/// - **Nothing is removed without being asked.** Every destructive action is
///   a separate call, made by a confirmed user action, and each reports
///   exactly what it removed and how much it reclaimed.
actor StorageUsageService {

    /// The locations being measured and tidied.
    private let locations: StorageLocations

    init(locations: StorageLocations = .resolve()) {
        self.locations = locations
    }

    /// Measures every category.
    func report() -> StorageUsageReport {
        var usage: [StorageCategory: Int64] = [:]
        for category in StorageCategory.allCases {
            usage[category] = allocatedBytes(for: category)
        }
        return StorageUsageReport(usage: usage, measuredAt: Date())
    }

    /// The largest files ZynSign holds, largest first.
    func largestFiles(limit: Int = 20) -> [StoredFileDescription] {
        var descriptions: [StoredFileDescription] = []
        for category in StorageCategory.allCases {
            for location in category.locations(in: locations) {
                for record in fileRecords(at: location, countsOnlyOwnedEntries: category.countsOnlyOwnedEntries) {
                    descriptions.append(StoredFileDescription(
                        url: record.url,
                        byteCount: record.byteCount,
                        modifiedAt: record.modifiedAt,
                        category: category
                    ))
                }
            }
        }
        descriptions.sort { $0.byteCount > $1.byteCount }
        return Array(descriptions.prefix(max(0, limit)))
    }

    /// Removes ZynSign's scratch files from the temporary directory.
    ///
    /// Exported reports and certificate backups are preserved: they are
    /// things the user asked ZynSign to write, not scratch.
    func clearTemporaryFiles() -> StorageCleanupOutcome {
        let removed = removeOwnedEntries(in: locations.temporary, preserving: StorageCategory.temporaryFiles.preservedEntryNames)
        return StorageCleanupOutcome(
            removedItemCount: removed.count,
            reclaimedBytes: removed.reclaimedBytes,
            message: Self.message(removedCount: removed.count, reclaimedBytes: removed.reclaimedBytes, subject: "temporary file")
        )
    }

    /// Removes the cached application icons. They are re-derived the next
    /// time a library card needs one, so nothing is lost by clearing them.
    func clearCache() -> StorageCleanupOutcome {
        let removed = removeOwnedEntries(in: locations.caches, preserving: StorageCategory.cache.preservedEntryNames)
        return StorageCleanupOutcome(
            removedItemCount: removed.count,
            reclaimedBytes: removed.reclaimedBytes,
            message: Self.message(removedCount: removed.count, reclaimedBytes: removed.reclaimedBytes, subject: "cached item")
        )
    }

    /// Removes signed packages written more than `olderThanDays` days ago.
    func removeExports(olderThanDays days: Int) -> StorageCleanupOutcome {
        let before = allocatedBytes(for: .signedArtifacts)
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86_400)
        var removedCount = 0
        for record in fileRecords(at: locations.signedArtifacts, countsOnlyOwnedEntries: false) {
            // A file whose date cannot be read is left alone rather than
            // guessed at.
            guard record.modifiedAt < cutoff else { continue }
            if remove(record.url) { removedCount += 1 }
        }
        let reclaimed = max(0, before - allocatedBytes(for: .signedArtifacts))
        return StorageCleanupOutcome(
            removedItemCount: removedCount,
            reclaimedBytes: reclaimed,
            message: Self.message(removedCount: removedCount, reclaimedBytes: reclaimed, subject: "signed package")
        )
    }

    /// Removes one file ZynSign holds.
    @discardableResult
    func removeFile(at url: URL) -> Bool {
        remove(url)
    }

    // MARK: - Measurement

    private struct FileRecord {
        let url: URL
        let byteCount: Int64
        let modifiedAt: Date
    }

    private struct RemovalResult {
        let count: Int
        let reclaimedBytes: Int64
    }

    private func allocatedBytes(for category: StorageCategory) -> Int64 {
        var total: Int64 = 0
        for location in category.locations(in: locations) {
            for record in fileRecords(at: location, countsOnlyOwnedEntries: category.countsOnlyOwnedEntries) {
                total += record.byteCount
            }
        }
        return total
    }

    /// Lists the regular files under `url`, honouring the ownership
    /// restriction a shared directory requires.
    private func fileRecords(at url: URL, countsOnlyOwnedEntries: Bool) -> [FileRecord] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return record(for: url).map { [$0] } ?? []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var records: [FileRecord] = []
        for case let candidate as URL in enumerator {
            if countsOnlyOwnedEntries, !isZynSignOwned(candidate, root: url) { continue }
            if let record = record(for: candidate) { records.append(record) }
        }
        return records
    }

    private func record(for url: URL) -> FileRecord? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]) else {
            return nil
        }
        guard values.isRegularFile == true else { return nil }
        return FileRecord(
            url: url,
            byteCount: Int64(values.totalFileAllocatedSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    /// Whether `url` sits inside a ZynSign-owned entry of `root`.
    private func isZynSignOwned(_ url: URL, root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relative: String
        if url.path.hasPrefix(rootPrefix) {
            relative = String(url.path.dropFirst(rootPrefix.count))
        } else {
            relative = url.lastPathComponent
        }
        let firstComponent = relative.split(separator: "/").first.map(String.init) ?? relative
        return ZynSignStorageLayout.isZynSignOwnedEntry(firstComponent)
    }

    // MARK: - Cleanup

    private func removeOwnedEntries(in root: URL, preserving: Set<String>) -> RemovalResult {
        let before = allocatedBytesOfOwnedEntries(in: root, preserving: preserving)
        var count = 0
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return RemovalResult(count: 0, reclaimedBytes: 0)
        }
        for entry in contents where ZynSignStorageLayout.isZynSignOwnedEntry(entry.lastPathComponent)
            && !preserving.contains(entry.lastPathComponent.lowercased()) {
            if remove(entry) { count += 1 }
        }
        let after = allocatedBytesOfOwnedEntries(in: root, preserving: preserving)
        return RemovalResult(count: count, reclaimedBytes: max(0, before - after))
    }

    private func allocatedBytesOfOwnedEntries(in root: URL, preserving: Set<String>) -> Int64 {
        var total: Int64 = 0
        for record in fileRecords(at: root, countsOnlyOwnedEntries: true) {
            let firstComponent = firstOwnedComponent(of: record.url, root: root)
            if preserving.contains(firstComponent.lowercased()) { continue }
            total += record.byteCount
        }
        return total
    }

    private func firstOwnedComponent(of url: URL, root: URL) -> String {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relative = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
        return relative.split(separator: "/").first.map(String.init) ?? relative
    }

    @discardableResult
    private func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func message(removedCount: Int, reclaimedBytes: Int64, subject: String) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: reclaimedBytes)
        if removedCount == 0 {
            return "Nothing to remove — no \(subject)s were left."
        }
        let plural = removedCount == 1 ? subject : "\(subject)s"
        return "Removed \(removedCount) \(plural) and reclaimed \(size)."
    }
}
