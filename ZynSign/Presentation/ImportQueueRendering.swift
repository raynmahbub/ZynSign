import Foundation

/// The words the import experience uses.
///
/// One place turns import outcomes and queue state into sentences, so the
/// same package outcome reads the same way wherever it is shown — a settled
/// row, a summary card, or an announcement — and so the mapping can be
/// tested without a running import.
///
/// Everything composed here describes what ZynSign *did*: what it stored,
/// what it recognised, what it refused. Nothing here claims a package is
/// signed, genuine, or installable, because no import establishes any of
/// those things.
enum ImportQueueRendering {

    // MARK: - One settled import

    /// The sentence explaining one settled job.
    static func message(for settlement: ImportSettlement) -> String {
        switch settlement.kind {
        case .imported:
            switch settlement.relation {
            case .some(.otherVersions(let others)):
                let count = others.count
                return count == 1
                    ? "Added to the library alongside one other version of this application."
                    : "Added to the library alongside \(count) other versions of this application."
            case .some(.sameDeclaredVersion):
                return "Added to the library. An earlier import declares the same version and build but has different content; both are kept."
            case .some(.unrelated), .none:
                return "Added to the library."
            }

        case .keptBoth:
            let count = settlement.duplicate?.report.matches.count ?? 0
            switch count {
            case 0:
                return "Added to the library alongside the entries already there."
            case 1:
                return "Added to the library alongside the entry it matches."
            default:
                return "Added to the library alongside the \(count) entries it matches."
            }

        case .replaced:
            let removed = settlement.replacedRecords.count
            let base = removed == 1
                ? "Added to the library and replaced the entry it matched."
                : "Added to the library and replaced the \(removed) entries it matched."
            guard !settlement.retainedRecords.isEmpty else { return base }
            let retained = settlement.retainedRecords.count
            let tail = retained == 1
                ? "One earlier entry could not be removed and remains in the library."
                : "\(retained) earlier entries could not be removed and remain in the library."
            return base + " " + tail

        case .alreadyHeld:
            return "This exact package is already in ZynSign's library, so it was not added again."

        case .rejected:
            return settlement.failure?.message ?? "The package was refused."

        case .failed:
            return settlement.failure?.message ?? "The import could not be completed."

        case .cancelled:
            return "Cancelled. Nothing was kept, and the file you chose was not changed."
        }
    }

    // MARK: - The batch

    /// The headline of the batch summary: what happened to the requests the
    /// user made.
    static func headline(for summary: ImportSummary) -> String {
        guard summary.hasWork else { return "No imports yet" }
        if summary.scheduledCount == 1 {
            return summary.settledCount == 0 ? "Importing one package" : "Import finished"
        }
        if summary.settledCount < summary.scheduledCount {
            return "Importing \(summary.settledCount) of \(summary.scheduledCount) packages"
        }
        return "Import finished — \(summary.scheduledCount) packages"
    }

    /// The supporting line of the batch summary: counts in the order a person
    /// reads them, and the total size actually copied.
    static func detail(for summary: ImportSummary) -> String {
        var parts: [String] = []
        if summary.addedCount > 0 {
            parts.append("\(summary.addedCount) added to the library")
        }
        if summary.alreadyHeldCount > 0 {
            parts.append("\(summary.alreadyHeldCount) already held")
        }
        if summary.rejectedCount > 0 {
            parts.append("\(summary.rejectedCount) refused")
        }
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) failed")
        }
        if summary.cancelledCount > 0 {
            parts.append("\(summary.cancelledCount) cancelled")
        }
        if summary.byteCount > 0 {
            // The sum of the sizes ZynSign measured for the files it was
            // given — a fact about the packages, not a claim about what was
            // stored from them.
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .file)) of packages")
        }
        return parts.isEmpty ? "Nothing was imported." : parts.joined(separator: " · ")
    }

    // MARK: - The picker

    /// Whether an error means the user closed a picker, which is an ordinary
    /// outcome rather than a failure worth announcing.
    ///
    /// Only the platform's own cancellation error, a cancelled task, and
    /// ZynSign's cancelled category qualify. Anything else is surfaced: a
    /// picker that failed to hand over a file the user tapped is not the same
    /// as a picker the user dismissed.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let zynSignError = error as? ZynSignError, zynSignError.category == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// The message shown when the picker itself failed.
    static func pickerFailureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The picker could not provide the selected file."
    }
}
