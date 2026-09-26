import Foundation

/// The settled outcome of one import: what ZynSign did with the package, in
/// the terms the interface and the queue both read.
///
/// A settlement is derived from exactly one of two things — an import result
/// that came back, or an error that was thrown — so every import that ends
/// ends here, and there is no third way for a job to be described. The
/// vocabulary is deliberately small: each kind states what *ZynSign holds*
/// afterwards, never what the package is.
struct ImportSettlement: Equatable, Hashable, Sendable {

    /// What happened to one import.
    enum Kind: Equatable, Hashable, Sendable {

        /// A new library entry was created for this import.
        case imported

        /// The library already relates to this package and the import was
        /// stored as a further entry beside those records.
        case keptBoth

        /// The import was stored and the entries it matched were removed.
        /// `replacedRecords` names them, and `retainedRecords` names any that
        /// could not be removed.
        case replaced

        /// The library already holds byte-identical content, so nothing was
        /// stored again. The bytes are already there; this import added
        /// nothing and lost nothing.
        case alreadyHeld

        /// The package was refused by validation. Nothing was stored and
        /// nothing was changed.
        case rejected

        /// The import itself failed — the file could not be read, copied, or
        /// stored. Nothing was stored.
        case failed

        /// The user cancelled, or the surrounding work was cancelled.
        case cancelled

        /// The user chose not to import the package — they skipped it in
        /// the Duplicate Resolution Center, deselected it in the preview,
        /// or declined to extract it from an archive. Nothing was stored,
        /// and the file they chose was not changed.
        case skipped

        /// Whether ZynSign holds something for this import afterwards.
        var isAccepted: Bool {
            switch self {
            case .imported, .keptBoth, .replaced, .alreadyHeld: return true
            case .rejected, .failed, .cancelled, .skipped: return false
            }
        }

        /// The word shown on a settled row.
        var displayName: String {
            switch self {
            case .imported: return "Imported"
            case .keptBoth: return "Kept Both"
            case .replaced: return "Replaced"
            case .alreadyHeld: return "Already in Library"
            case .rejected: return "Refused"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .skipped: return "Skipped"
            }
        }

        /// The SF Symbol shown beside the settled row.
        var symbolName: String {
            switch self {
            case .imported: return "checkmark.circle.fill"
            case .keptBoth: return "plus.square.on.square"
            case .replaced: return "arrow.triangle.2.circlepath"
            case .alreadyHeld: return "equal.circle.fill"
            case .rejected: return "hand.raised.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .cancelled: return "xmark.circle"
            case .skipped: return "arrow.uturn.forward.circle"
            }
        }

        /// The Import Hub summary bucket the outcome counts toward.
        var bucket: ImportOutcomeBucket {
            switch self {
            case .imported, .keptBoth: return .imported
            case .replaced: return .replaced
            case .alreadyHeld, .cancelled, .skipped: return .skipped
            case .rejected, .failed: return .failed
            }
        }
    }

    /// What happened.
    let kind: Kind

    /// The record that now stands for this import, when one does: the new
    /// entry, or the existing entry byte-identical content was recognised
    /// against.
    let record: ApplicationRecord?

    /// The records a replacement removed.
    let replacedRecords: [ApplicationRecord]

    /// The records a replacement was asked to remove and could not. Reported
    /// so the interface can say so rather than implying a clean replacement.
    let retainedRecords: [ApplicationRecord]

    /// How the new record relates to the rest of the library, when the
    /// library reported it.
    let relation: ApplicationRecordRelation?

    /// The duplicate comparison behind the outcome, when there was one.
    let duplicate: DuplicateOutcome?

    /// The explanation of a failure or refusal, when the import did not
    /// succeed. Never carries diagnostic detail.
    let failure: ImportFailure?

    /// Records a settlement.
    init(
        kind: Kind,
        record: ApplicationRecord? = nil,
        replacedRecords: [ApplicationRecord] = [],
        retainedRecords: [ApplicationRecord] = [],
        relation: ApplicationRecordRelation? = nil,
        duplicate: DuplicateOutcome? = nil,
        failure: ImportFailure? = nil
    ) {
        self.kind = kind
        self.record = record
        self.replacedRecords = replacedRecords
        self.retainedRecords = retainedRecords
        self.relation = relation
        self.duplicate = duplicate
        self.failure = failure
    }

    /// A settlement for a job the user cancelled before it ran.
    static func cancelled() -> ImportSettlement {
        ImportSettlement(kind: .cancelled)
    }

    /// A settlement for a package the user chose not to import. `conflict`
    /// is the library relation they were shown, if any.
    static func skipped(duplicate: DuplicateOutcome? = nil) -> ImportSettlement {
        ImportSettlement(kind: .skipped, duplicate: duplicate)
    }

    /// Whether offering to attempt the same file again is honest.
    ///
    /// A cancellation may be repeated — the user may simply have changed
    /// their mind. A failure may be repeated exactly when its explanation
    /// says a later attempt can plausibly end differently. A refusal and a
    /// recognised duplicate may not: re-reading an unchanged file cannot
    /// change what the package declares, and re-importing content the library
    /// already holds cannot add anything the user was not already shown.
    var isRetryable: Bool {
        switch kind {
        case .failed:
            return failure?.isRetryable ?? false
        case .cancelled:
            return true
        case .imported, .keptBoth, .replaced, .alreadyHeld, .rejected, .skipped:
            return false
        }
    }

    // MARK: - Derivation

    /// Derives the settlement for an import that returned a result.
    static func from(_ result: PackageImportResult) -> ImportSettlement {
        guard let admission = result.admission else {
            return ImportSettlement(
                kind: .rejected,
                duplicate: result.duplicate,
                failure: ImportFailure.from(validation: result.artifact.validation)
            )
        }

        switch admission {
        case .alreadyRecorded(let existing):
            return ImportSettlement(
                kind: .alreadyHeld,
                record: existing,
                duplicate: result.duplicate
            )

        case .recorded(let record, let relation):
            let kind: Kind
            switch result.duplicate?.resolution {
            case .some(.keepBoth):
                kind = .keptBoth
            case .some(.replaceExisting):
                kind = .replaced
            case .some(.cancel), .none:
                // A cancelled duplicate never reaches a result: the import
                // throws instead. Anything else that got recorded with no
                // decision is an ordinary import.
                kind = .imported
            }
            return ImportSettlement(
                kind: kind,
                record: record,
                replacedRecords: result.duplicate?.replacedRecords ?? [],
                retainedRecords: result.duplicate?.retainedRecords ?? [],
                relation: relation,
                duplicate: result.duplicate
            )
        }
    }

    /// Derives the settlement for an import that ended by throwing.
    ///
    /// Cancellation is an ordinary outcome, not a failure, and is reported as
    /// such — both when the task was cancelled and when the import reports a
    /// cancelled error of its own. A refusal of the selected input is a
    /// refusal rather than a failure: pre-import validation throws its
    /// verdicts, and calling a file ZynSign would not accept a "failed
    /// import" would misdescribe what happened.
    static func from(error: any Error) -> ImportSettlement {
        if error is CancellationError {
            return ImportSettlement(kind: .cancelled)
        }
        let failure = ImportFailure.from(error: error)
        switch failure.category {
        case .cancelled:
            return ImportSettlement(kind: .cancelled)
        case .invalidInput, .unsupportedInput, .ambiguousInput:
            return ImportSettlement(kind: .rejected, failure: failure)
        case .capabilityUnavailable, .storageFailure, .internalFailure:
            return ImportSettlement(kind: .failed, failure: failure)
        }
    }
}

/// The summary of the imports the queue is holding: how many packages were
/// scheduled, how each one ended, and how much content passed through.
///
/// A summary counts settlements and adds nothing: it is a projection of what
/// already happened, so it can never disagree with the rows it summarizes.
struct ImportSummary: Equatable, Hashable, Sendable {

    /// How many jobs the queue is holding.
    let scheduledCount: Int

    /// How many of them have settled.
    let settledCount: Int

    let importedCount: Int
    let keptBothCount: Int
    let replacedCount: Int
    let alreadyHeldCount: Int
    let rejectedCount: Int
    let failedCount: Int
    let cancelledCount: Int

    /// Packages the user chose not to import.
    let skippedCount: Int

    /// The total size of the packages the queue has seen, in bytes, summed
    /// from what each import measured while copying. Zero when nothing has
    /// been measured yet — never an estimate.
    let byteCount: Int

    /// A summary with nothing in it.
    static let empty = ImportSummary(
        scheduledCount: 0,
        settledCount: 0,
        importedCount: 0,
        keptBothCount: 0,
        replacedCount: 0,
        alreadyHeldCount: 0,
        rejectedCount: 0,
        failedCount: 0,
        cancelledCount: 0,
        byteCount: 0
    )

    /// Counts the settlements the queue holds.
    init(settlements: [ImportSettlement], scheduledCount: Int, byteCount: Int) {
        func count(_ kind: ImportSettlement.Kind) -> Int {
            settlements.filter { $0.kind == kind }.count
        }
        self.scheduledCount = max(0, scheduledCount)
        self.settledCount = settlements.count
        self.importedCount = count(.imported)
        self.keptBothCount = count(.keptBoth)
        self.replacedCount = count(.replaced)
        self.alreadyHeldCount = count(.alreadyHeld)
        self.rejectedCount = count(.rejected)
        self.failedCount = count(.failed)
        self.cancelledCount = count(.cancelled)
        self.skippedCount = count(.skipped)
        self.byteCount = max(0, byteCount)
    }

    /// Records counts directly. Only for the empty summary and for tests.
    init(
        scheduledCount: Int,
        settledCount: Int,
        importedCount: Int,
        keptBothCount: Int,
        replacedCount: Int,
        alreadyHeldCount: Int,
        rejectedCount: Int,
        failedCount: Int,
        cancelledCount: Int,
        byteCount: Int,
        skippedCount: Int = 0
    ) {
        self.scheduledCount = scheduledCount
        self.settledCount = settledCount
        self.importedCount = importedCount
        self.keptBothCount = keptBothCount
        self.replacedCount = replacedCount
        self.alreadyHeldCount = alreadyHeldCount
        self.rejectedCount = rejectedCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.byteCount = byteCount
        self.skippedCount = skippedCount
    }

    /// How many settled imports count toward `bucket` — the four numbers
    /// the Import Hub's summary shows.
    ///
    /// - Imported: stored as a new entry, including kept-both copies.
    /// - Replaced: stored in place of existing entries.
    /// - Skipped: nothing added — skipped, already in the library, or
    ///   cancelled.
    /// - Failed: refused or failed, each with its reason.
    func count(of bucket: ImportOutcomeBucket) -> Int {
        switch bucket {
        case .imported: return importedCount + keptBothCount
        case .replaced: return replacedCount
        case .skipped: return skippedCount + alreadyHeldCount + cancelledCount
        case .failed: return rejectedCount + failedCount
        }
    }

    /// How many packages the library gained: imports stored, whether they
    /// were kept beside other records or replaced them. Content recognised as
    /// already held is deliberately not counted — nothing was added.
    var addedCount: Int {
        importedCount + keptBothCount + replacedCount
    }

    /// How many packages did not end in the library.
    var unsuccessfulCount: Int {
        rejectedCount + failedCount + cancelledCount
    }

    /// Whether every scheduled job has settled.
    var isComplete: Bool {
        scheduledCount > 0 && settledCount >= scheduledCount
    }

    /// Whether there is anything worth summarizing.
    var hasWork: Bool {
        scheduledCount > 0
    }
}
