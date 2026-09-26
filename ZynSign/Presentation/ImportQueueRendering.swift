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

        case .skipped:
            return "Skipped. Nothing was added, and the file you chose was not changed."
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
        if summary.skippedCount > 0 {
            parts.append("\(summary.skippedCount) skipped")
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

    // MARK: - Import Hub items

    /// The one-line status an item shows under its name.
    static func statusLine(for item: ImportHub.Item) -> String {
        switch item.phase {
        case .waiting:
            return item.staged == nil ? "Waiting" : "Waiting to resume"
        case .preparing:
            if let progress = item.progress, progress.stage == .copying, progress.isDeterminate {
                return "Preparing · \(bytes(progress.completedUnitCount)) of \(bytes(progress.totalUnitCount))"
            }
            return "Preparing"
        case .validating:
            return "Validating"
        case .analyzing:
            return "Analyzing"
        case .awaitingSelection(let candidates):
            return candidates.count == 1 ? "Contains 1 app" : "Contains \(candidates.count) apps"
        case .ready:
            return item.isSelected ? "Ready to import" : "Won't be imported"
        case .queuedForImport:
            return "Waiting to import"
        case .importing:
            return "Importing"
        case .unpacked(let count):
            return count == 1 ? "1 app extracted" : "\(count) apps extracted"
        case .settled(let settlement):
            switch settlement.kind {
            case .rejected, .failed:
                return settlement.failure?.title ?? settlement.kind.displayName
            default:
                return settlement.kind.displayName
            }
        }
    }

    /// The remaining-work line for an item that is still running, or `nil`
    /// when there is nothing honest to say.
    static func remainingText(for estimate: ImportRemainingEstimate) -> String? {
        var parts: [String] = []
        if let seconds = estimate.remainingSeconds {
            parts.append(duration(seconds))
        } else if let remainingBytes = estimate.remainingBytes, remainingBytes > 0 {
            parts.append("\(bytes(remainingBytes)) to copy")
        }
        switch estimate.remainingSteps {
        case 0: break
        case 1: parts.append("1 step left")
        default: parts.append("\(estimate.remainingSteps) steps left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A duration phrased as an estimate, never as a promise.
    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded < 60 {
            return "About \(rounded) s left"
        }
        let minutes = Int((Double(rounded) / 60).rounded(.up))
        return minutes == 1 ? "About 1 min left" : "About \(minutes) min left"
    }

    /// A byte count in the unit people expect for files.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
    }

    /// A declared version and build, as `1.3 (45)`, with em dashes for
    /// what is not declared.
    static func versionText(_ identity: ApplicationIdentity) -> String {
        let version = identity.shortVersionString ?? "\u{2014}"
        guard let build = identity.buildVersion else { return version }
        return "\(version) (\(build))"
    }

    /// The name an item shows: the application's once analyzed, the file's
    /// until then.
    static func title(for item: ImportHub.Item) -> String {
        item.identity?.displayName ?? item.fileName
    }

    /// The remark shown for an item's relation to other items.
    static func text(for note: ImportHub.Item.Note) -> String {
        switch note {
        case .sameContent(let other):
            return "Identical to \(other), so it's not selected."
        case .sameApplication(let other):
            return "Another version of this app (\(other)) is also in the preview. Both will be kept unless you deselect one."
        }
    }

    // MARK: - Conflicts

    /// The short headline of a conflict: how the incoming package relates
    /// to what the library holds.
    static func headline(for conflict: ImportConflict) -> String {
        let existing = versionText(conflict.comparedRecord.identity)
        let incoming = versionText(conflict.incomingIdentity)
        switch conflict.relation {
        case .identicalContent:
            return "Already in the library"
        case .sameVersion:
            return "Same version in library (\(existing))"
        case .newerVersion:
            return "Newer than library (\(existing) → \(incoming))"
        case .olderVersion:
            return "Older than library (\(existing) → \(incoming))"
        case .undeterminedVersion:
            return "Versions can't be compared (\(existing) vs \(incoming))"
        }
    }

    /// Why the rules suggest what they suggest, or why they suggest nothing.
    static func suggestionExplanation(for conflict: ImportConflict) -> String {
        switch conflict.relation {
        case .identicalContent:
            return "The library already holds these exact bytes. Skipping changes nothing."
        case .sameVersion:
            return "Same version and build, different content — a rebuild or modified copy. Choose what to keep."
        case .newerVersion:
            return "The incoming package declares a newer version. Replacing keeps only the newer one."
        case .olderVersion:
            return "The incoming package is older than what the library holds. Keeping both preserves the newer one."
        case .undeterminedVersion:
            return "ZynSign can't tell which version is newer. Choose what to keep."
        }
    }

    /// What “Replace Existing” would remove, stated before it is chosen.
    static func replacementScope(for conflict: ImportConflict) -> String {
        let count = conflict.existingRecords.count
        return count == 1
            ? "Replacing removes 1 existing entry after the new one is stored."
            : "Replacing removes \(count) existing entries after the new one is stored."
    }

    // MARK: - Archives

    /// What an archive holds, for the card offering to extract it.
    static func archiveOffer(for candidates: [NestedPackageCandidate]) -> String {
        candidates.count == 1
            ? "This archive contains one app package. ZynSign can extract it into its own working copy and import it — the archive is not changed."
            : "This archive contains \(candidates.count) app packages. Choose which to extract and import — the archive is not changed."
    }

    // MARK: - Summary and history

    /// The spoken summary of a finished batch.
    static func announcement(for entry: ImportHistoryEntry) -> String {
        let parts = ImportOutcomeBucket.allCases.compactMap { bucket -> String? in
            let count = entry.count(of: bucket)
            return count > 0 ? "\(count) \(bucket.displayName.lowercased())" : nil
        }
        return parts.isEmpty ? "Import finished." : "Import finished: " + parts.joined(separator: ", ") + "."
    }

    /// The title of a history entry.
    static func title(for entry: ImportHistoryEntry) -> String {
        let count = entry.items.count
        let noun = count == 1 ? "1 file" : "\(count) files"
        return "\(noun) · \(entry.origin.displayName)"
    }

    /// The counts line of a history entry, in summary-bucket order.
    static func counts(for entry: ImportHistoryEntry) -> String {
        let parts = ImportOutcomeBucket.allCases.compactMap { bucket -> String? in
            let count = entry.count(of: bucket)
            return count > 0 ? "\(count) \(bucket.displayName.lowercased())" : nil
        }
        return parts.isEmpty ? "Nothing imported" : parts.joined(separator: " · ")
    }

    // MARK: - Storage and background

    /// The free space line, or `nil` when the platform cannot say.
    static func storageText(available: Int?) -> String? {
        available.map { "\(bytes($0)) available on this device" }
    }

    /// What the hub promises about leaving ZynSign — exactly what the
    /// platform allows, and no more.
    static let backgroundExplanation = "Imports run while ZynSign is open. If you switch away, iOS gives ZynSign only a short time to finish; anything unfinished pauses and continues when you return. Originals are never changed."

    /// Shown while work is paused after the system's background time ran
    /// out.
    static let pausedExplanation = "Paused while ZynSign was in the background. Work continues now that ZynSign is open again."
}
