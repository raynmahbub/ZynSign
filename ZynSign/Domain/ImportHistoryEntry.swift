import Foundation

/// Identifies one batch of imports: everything that arrived together from
/// one entry point, plus any packages the user extracted from archives in
/// it.
struct ImportBatchIdentifier: Equatable, Hashable, CustomStringConvertible, Sendable, Codable {

    let uuid: UUID

    init() {
        self.uuid = UUID()
    }

    init(uuid: UUID) {
        self.uuid = uuid
    }

    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}

/// The four ways the Import Hub's summary and history count an import.
enum ImportOutcomeBucket: String, CaseIterable, Hashable, Sendable, Codable {

    /// Added to the library (including as an additional copy).
    case imported

    /// Nothing was added: skipped by the user, already in the library, or
    /// cancelled.
    case skipped

    /// Added to the library in place of existing entries.
    case replaced

    /// Refused or failed, with a reason.
    case failed

    /// The label shown for the bucket.
    var displayName: String {
        switch self {
        case .imported: return "Imported"
        case .skipped: return "Skipped"
        case .replaced: return "Replaced"
        case .failed: return "Failed"
        }
    }

    /// The SF Symbol shown for the bucket.
    var symbolName: String {
        switch self {
        case .imported: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .replaced: return "arrow.triangle.2.circlepath.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// A lightweight record of one finished import batch, kept so the user can
/// see what arrived when, and reopen what was imported.
///
/// The history stores names the user already saw — file names, application
/// names, bundle identifiers, and versions — and the identifiers of the
/// library entries imports created, never file locations, bookmarks, or
/// package content. It lives only on this device and can be cleared.
struct ImportHistoryEntry: Equatable, Hashable, Identifiable, Sendable, Codable {

    /// How one item in the batch ended.
    enum Outcome: String, Equatable, Hashable, Sendable, Codable {
        case imported
        case keptBoth
        case replaced
        case skipped
        case alreadyInLibrary
        case cancelled
        case refused
        case failed

        /// The summary bucket the outcome counts toward.
        var bucket: ImportOutcomeBucket {
            switch self {
            case .imported, .keptBoth: return .imported
            case .replaced: return .replaced
            case .skipped, .alreadyInLibrary, .cancelled: return .skipped
            case .refused, .failed: return .failed
            }
        }

        /// The label shown for the outcome.
        var displayName: String {
            switch self {
            case .imported: return "Imported"
            case .keptBoth: return "Kept Both"
            case .replaced: return "Replaced"
            case .skipped: return "Skipped"
            case .alreadyInLibrary: return "Already in Library"
            case .cancelled: return "Cancelled"
            case .refused: return "Refused"
            case .failed: return "Failed"
            }
        }
    }

    /// One item of a finished batch.
    struct Item: Equatable, Hashable, Identifiable, Sendable, Codable {

        /// The item's identifier while it was in the Import Hub.
        let id: UUID

        /// The name of the file (or archive entry) the item imported.
        let fileName: String

        /// How the item ended.
        let outcome: Outcome

        /// The application's name, when the package was analyzed.
        let applicationName: String?

        /// The application's bundle identifier, when the package was
        /// analyzed.
        let bundleIdentifier: String?

        /// The application's declared version, when there is one.
        let version: String?

        /// The library entry the import created or matched, for reopening.
        let recordID: String?

        /// How many existing entries the import replaced.
        let replacedCount: Int

        /// Why the item was refused or failed, in the words shown to the
        /// user at the time.
        let failureMessage: String?

        init(
            id: UUID,
            fileName: String,
            outcome: Outcome,
            applicationName: String? = nil,
            bundleIdentifier: String? = nil,
            version: String? = nil,
            recordID: String? = nil,
            replacedCount: Int = 0,
            failureMessage: String? = nil
        ) {
            self.id = id
            self.fileName = fileName
            self.outcome = outcome
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.recordID = recordID
            self.replacedCount = max(0, replacedCount)
            self.failureMessage = failureMessage
        }
    }

    let id: ImportBatchIdentifier

    /// When the batch's first item arrived.
    let startedAt: Date

    /// When the batch's last item finished.
    let finishedAt: Date

    /// Where the batch came from.
    let origin: ImportOrigin

    /// The batch's items, in arrival order.
    let items: [Item]

    /// How many items ended in `bucket`.
    func count(of bucket: ImportOutcomeBucket) -> Int {
        items.filter { $0.outcome.bucket == bucket }.count
    }

    /// The items that reached the library and can be reopened.
    var reopenableItems: [Item] {
        items.filter { $0.recordID != nil && ($0.outcome.bucket == .imported || $0.outcome.bucket == .replaced) }
    }
}
