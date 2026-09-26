import Foundation

/// One category of storage ZynSign accounts for.
///
/// The categories are the ones the user can reason about, and each maps to a
/// place ZynSign actually keeps bytes:
///
/// - imported applications — the packages the library adopted;
/// - exported artifacts — the signed output in export storage;
/// - temporary files — staging, working copies, and leftovers;
/// - history — the signing journal and the export catalog themselves.
///
/// Source applications are never a cleanup target. They are reported so the
/// user can see what the library costs, and the only way to remove one is the
/// library's own delete, one entry at a time, with its own confirmation.
enum StorageCategory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {

    case importedApplications
    case exportedArtifacts
    case temporaryFiles
    case history

    var id: Self { self }

    /// The category name shown in the storage breakdown.
    var displayName: String {
        switch self {
        case .importedApplications: return "Imported Apps"
        case .exportedArtifacts: return "Signed Artifacts"
        case .temporaryFiles: return "Temporary Files"
        case .history: return "History"
        }
    }

    /// What the category holds and what removing it means.
    var explanation: String {
        switch self {
        case .importedApplications:
            return "Packages the library adopted. Removed only from the Library, one application at a time — never by cleanup."
        case .exportedArtifacts:
            return "Signed output kept by the Export Center. Removing it deletes copies ZynSign produced; the imported applications it was signed from are untouched."
        case .temporaryFiles:
            return "Working copies, staging files, and leftovers from operations that were interrupted. Safe to remove when no operation is running."
        case .history:
            return "The signing journal and the export catalog. Removing old records keeps recent operations and never touches artifacts."
        }
    }

    /// Whether cleanup may remove bytes in this category.
    var isCleanable: Bool { self != .importedApplications }
}

/// How much one category holds.
struct StorageCategoryUsage: Equatable, Hashable, Sendable, Identifiable {

    let category: StorageCategory

    /// The bytes the category holds. Never negative.
    let byteCount: Int

    /// How many items the category holds.
    ///
    /// An item is a file for the byte-bearing categories — imported
    /// applications, exported artifacts, temporary files — and a record for
    /// the history, because records are what the history's cleanup removes and
    /// what a user can reason about. The byte count is always the real size of
    /// the storage that holds the category.
    let itemCount: Int

    var id: StorageCategory { category }

    init(category: StorageCategory, byteCount: Int, itemCount: Int) {
        self.category = category
        self.byteCount = max(0, byteCount)
        self.itemCount = max(0, itemCount)
    }
}

/// What ZynSign is using on disk, in the categories the user can act on.
///
/// The footprint is measured, never estimated: each category's bytes and
/// items are read from the storage that holds them at the moment it is asked
/// for. A category nothing could be measured for reports zero with a zero
/// item count, which is the honest reading of "there is nothing there" — and
/// the sum is always the sum of what was actually measured.
struct StorageFootprint: Equatable, Sendable {

    /// One usage per category, in the order the categories are declared.
    let usages: [StorageCategoryUsage]

    init(usages: [StorageCategoryUsage]) {
        var byCategory: [StorageCategory: StorageCategoryUsage] = [:]
        for usage in usages {
            byCategory[usage.category] = usage
        }
        self.usages = StorageCategory.allCases.map { category in
            byCategory[category] ?? StorageCategoryUsage(category: category, byteCount: 0, itemCount: 0)
        }
    }

    /// A footprint in which nothing was measured.
    static let empty = StorageFootprint(usages: [])

    /// The usage of one category. Always present.
    func usage(of category: StorageCategory) -> StorageCategoryUsage {
        usages.first { $0.category == category }
            ?? StorageCategoryUsage(category: category, byteCount: 0, itemCount: 0)
    }

    /// Every category except the imported applications, whose bytes cleanup
    /// never removes. The breakdown still lists them.
    var cleanableUsages: [StorageCategoryUsage] {
        usages.filter { $0.category.isCleanable }
    }

    /// The sum of every category.
    var totalByteCount: Int {
        usages.reduce(0) { $0 + $1.byteCount }
    }

    /// The sum of the cleanable categories.
    var cleanableByteCount: Int {
        cleanableUsages.reduce(0) { $0 + $1.byteCount }
    }

    /// The number of items across every category.
    var totalItemCount: Int {
        usages.reduce(0) { $0 + $1.itemCount }
    }
}

/// A kind of cleanup the storage screen can perform. Each kind names exactly
/// what it removes; none of them can reach an imported application.
enum StorageCleanupKind: String, CaseIterable, Hashable, Sendable, Identifiable {

    /// Remove exported artifacts and the records that describe them. The
    /// imported applications they were signed from are not touched, and the
    /// signing history records remain.
    case exportedArtifacts

    /// Remove temporary working data and leftovers from interrupted
    /// operations, skipping anything an operation currently running owns.
    case temporaryFiles

    /// Remove signing-history records older than the retention interval,
    /// keeping the most recent records regardless of age.
    case oldHistoryRecords

    var id: Self { self }

    var displayName: String {
        switch self {
        case .exportedArtifacts: return "Remove Exported Artifacts"
        case .temporaryFiles: return "Remove Temporary Files"
        case .oldHistoryRecords: return "Remove Old History Records"
        }
    }

    /// What the action does, in the words the confirmation shows.
    var confirmationMessage: String {
        switch self {
        case .exportedArtifacts:
            return "Every signed artifact ZynSign produced will be deleted, together with the Export Center records that describe them. The imported applications you signed are not deleted, and the signing history stays."
        case .temporaryFiles:
            return "Working copies and staging files left behind by finished or interrupted operations will be deleted. Operations running right now are left alone."
        case .oldHistoryRecords:
            return "Signing history records older than \(StorageCleanupPolicy.historyRetentionDays) days will be deleted, keeping the most recent \(StorageCleanupPolicy.minimumRetainedHistoryRecords) records whatever their age."
        }
    }

    /// Whether the action is destructive enough to require confirmation.
    var requiresConfirmation: Bool { true }
}

/// The retention rules cleanup applies.
enum StorageCleanupPolicy {

    /// How long a signing-history record is kept by default.
    static let historyRetentionDays = 30

    /// How many history records are always kept, however old they are.
    static let minimumRetainedHistoryRecords = 20

    /// How long temporary data is left alone before cleanup may remove it.
    ///
    /// An hour is deliberately longer than any signing operation ZynSign runs
    /// on an ordinary package: data younger than this may belong to an
    /// operation that is still running, so it is left alone and counted as
    /// skipped rather than removed. Recovery therefore never races an
    /// operation in flight, and an operation interrupted by a crash leaves its
    /// working copy recoverable an hour later.
    static let temporaryDataMinimumAge: TimeInterval = 60 * 60

    /// The oldest instant temporary data may carry and still be removed.
    static func temporaryDataCutoff(now: Date) -> Date {
        now.addingTimeInterval(-temporaryDataMinimumAge)
    }

    /// The oldest instant a history record may carry and still be removed.
    static func historyCutoff(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -historyRetentionDays, to: now) ?? now
    }

    /// The records an old-history cleanup removes.
    ///
    /// A record is a candidate when it is older than the retention interval,
    /// and candidates are taken oldest first so that what remains is always the
    /// most recent history. The most recent `minimumRetained` records are kept
    /// whatever their age, which is what stops cleanup from emptying a journal
    /// that has not been used for a while.
    ///
    /// The rule is a pure function so the storage screen's destructive action
    /// is testable without a store, and so the same answer is given wherever
    /// the question is asked.
    static func historyRecordIdentifiersToRemove(
        from records: [SigningRecord],
        now: Date,
        calendar: Calendar = .current,
        retentionDays: Int = StorageCleanupPolicy.historyRetentionDays,
        minimumRetained: Int = StorageCleanupPolicy.minimumRetainedHistoryRecords
    ) -> [SigningRecordIdentifier] {
        let days = max(0, retentionDays)
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        let candidates = records
            .filter { $0.startedAt < cutoff }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        let removableCount = max(0, records.count - max(0, minimumRetained))
        return candidates.prefix(removableCount).map(\.id)
    }
}

/// What one cleanup removed.
///
/// The report separates artifacts from history records from files, and counts
/// what was skipped, so the interface can say exactly what happened instead of
/// a single unqualified "freed X".
struct StorageCleanupReport: Equatable, Sendable {

    /// The cleanup that produced this report.
    let kind: StorageCleanupKind

    /// Exported artifacts removed, with the records that described them.
    let removedArtifactCount: Int

    /// Files removed from temporary storage.
    let removedTemporaryFileCount: Int

    /// Signing-history records removed.
    let removedHistoryRecordCount: Int

    /// Bytes freed. Counted from files actually removed; a record carries no
    /// bytes of its own.
    let freedByteCount: Int

    /// Items left alone because they were in use, unreadable, or younger than
    /// the retention interval. Never a failure: skipped work is reported.
    let skippedItemCount: Int

    init(
        kind: StorageCleanupKind,
        removedArtifactCount: Int = 0,
        removedTemporaryFileCount: Int = 0,
        removedHistoryRecordCount: Int = 0,
        freedByteCount: Int = 0,
        skippedItemCount: Int = 0
    ) {
        self.kind = kind
        self.removedArtifactCount = max(0, removedArtifactCount)
        self.removedTemporaryFileCount = max(0, removedTemporaryFileCount)
        self.removedHistoryRecordCount = max(0, removedHistoryRecordCount)
        self.freedByteCount = max(0, freedByteCount)
        self.skippedItemCount = max(0, skippedItemCount)
    }

    /// Whether the cleanup found nothing to do.
    var removedNothing: Bool {
        removedArtifactCount == 0 && removedTemporaryFileCount == 0 && removedHistoryRecordCount == 0
    }

    /// The sentence the interface shows after a cleanup.
    var summary: String {
        var parts: [String] = []
        if removedArtifactCount > 0 {
            parts.append("\(removedArtifactCount) exported artifact\(removedArtifactCount == 1 ? "" : "s")")
        }
        if removedTemporaryFileCount > 0 {
            parts.append("\(removedTemporaryFileCount) temporary file\(removedTemporaryFileCount == 1 ? "" : "s")")
        }
        if removedHistoryRecordCount > 0 {
            parts.append("\(removedHistoryRecordCount) history record\(removedHistoryRecordCount == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else {
            return "Nothing needed to be removed."
        }
        var summary = "Removed \(parts.joined(separator: ", "))."
        if freedByteCount > 0 {
            summary += " Freed \(ByteCountFormatter.string(fromByteCount: Int64(freedByteCount), countStyle: .file))."
        }
        if skippedItemCount > 0 {
            summary += " \(skippedItemCount) item\(skippedItemCount == 1 ? " was" : "s were") left alone."
        }
        return summary
    }
}
