import Foundation
import Combine
import SwiftUI

/// The Installation Workspace's model: the dashboard, the readiness
/// reports, the Installed Apps Library, the history, and the bulk
/// preparation queue, over one `InstallationWorkspace` use case.
///
/// **What it enforces on the interface's behalf:**
///
/// - A delivery action — starting an attempt, handing off — is offered
///   only when the app's readiness report is clear. An app that has not
///   passed readiness is never handed to the delivery flow.
/// - An attempt is never resolved by anything but the user. Loading,
///   relaunching, and notifications refresh the *display* of pending
///   attempts; they never confirm, complete, or discard one.
/// - A readiness report is recomputed only when the facts behind it
///   changed — the export's identity, its verification, or the library
///   record's update — so scrolling hundreds of rows never re-evaluates
///   anything.
/// - Filtering, ordering, and the history projection read what the model
///   already holds in memory. Loading reads the catalogs once; an
///   installed-applications change patches the installed rows
///   incrementally instead of rescanning the library.
@MainActor
final class InstallationWorkspaceModel: ObservableObject {

    /// What the workspace screen is doing.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// A transient message the screen shows once.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String

        /// Whether the message reports a failure, so the toast renders as
        /// one. A confirmation is not a success badge for a delivery — it
        /// says a record was written.
        var isError: Bool = false

        init(title: String, message: String, isError: Bool = false) {
            self.title = title
            self.message = message
            self.isError = isError
        }
    }

    /// One row of the dashboard's "Ready to Install" and candidates lists.
    struct CandidateRow: Identifiable, Equatable {

        /// The joined library, signing, and export facts.
        let candidate: InstallationCandidate

        /// What readiness evaluation concluded, as of `reportDate`.
        let report: InstallationReadinessReport

        /// When the report was evaluated, so a stale row can be refreshed.
        let reportDate: Date

        /// The installed record for the same bundle identifier, when the
        /// user has recorded installations for this app.
        let installedRecord: InstalledApplicationRecord?

        var id: ApplicationRecordIdentifier { candidate.entry.record.id }

        static func == (lhs: CandidateRow, rhs: CandidateRow) -> Bool {
            lhs.candidate == rhs.candidate
                && lhs.report == rhs.report
                && lhs.installedRecord == rhs.installedRecord
        }
    }

    /// One row of the Installed Apps Library.
    struct InstalledRow: Identifiable, Equatable {

        /// The persisted record.
        let record: InstalledApplicationRecord

        /// Whether ZynSign holds a newer signed output than the one
        /// recorded as installed.
        let updateState: InstallationUpdateState

        /// The export behind the latest event, when it is still held.
        let latestExportEntry: ExportEntry?

        /// Whether the artifact behind the latest event is still held.
        var isArtifactHeld: Bool { latestExportEntry?.isAvailable ?? false }

        var id: InstalledApplicationIdentifier { record.id }

        /// The VoiceOver summary the card reads as one sentence.
        var spokenSummary: String {
            var parts = ["\(record.displayOrIdentifier), \(record.installedVersionDisplay)"]
            parts.append("last \(record.latestEvent?.kind.displayName.lowercased() ?? "recorded")")
            switch updateState {
            case .upToDate: parts.append("up to date")
            case .updateAvailable(let candidate): parts.append("update available to \(candidate.versionDisplay)")
            case .unknown: break
            }
            if !isArtifactHeld { parts.append("signed artifact no longer held") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// The storage rows the workspace reports.
    struct StorageSummary: Equatable {

        /// The installed-records catalog's size, when measured.
        let installedRecordsBytes: Int?

        /// The exported artifacts' total size, when measured.
        let exportedArtifactsBytes: Int?

        /// The temporary data's size, when measured.
        let temporaryBytes: Int?
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var candidateRows: [CandidateRow] = []
    @Published private(set) var installedRows: [InstalledRow] = []
    @Published private(set) var attempts: [PendingInstallationAttempt] = []
    @Published private(set) var historyEntries: [InstallationHistoryEntry] = []
    @Published private(set) var storageSummary = StorageSummary(
        installedRecordsBytes: nil, exportedArtifactsBytes: nil, temporaryBytes: nil
    )
    @Published var query = InstallationWorkspaceQuery()
    @Published var notice: Notice?
    @Published var selection: Set<InstalledApplicationIdentifier> = []

    /// The rows the Installed Apps Library shows, after the query.
    var visibleInstalledRows: [InstalledRow] {
        let facts = Dictionary(uniqueKeysWithValues: installedRows.map { row in
            (row.id, InstallationWorkspaceQuery.Facts(
                updateState: row.updateState,
                artifactHeld: row.isArtifactHeld
            ))
        })
        return query.apply(to: installedRows, facts: facts, now: now())
    }

    /// The candidate rows whose readiness is clear, dashboard order:
    /// ready first, then most recently signed.
    var readyCandidateRows: [CandidateRow] {
        candidateRows
            .filter { $0.report.isReady }
            .sorted {
                ($0.candidate.signingRecord?.startedAt ?? .distantPast)
                    > ($1.candidate.signingRecord?.startedAt ?? .distantPast)
            }
    }

    /// The candidate rows that are signed but not ready, dashboard order.
    var blockedCandidateRows: [CandidateRow] {
        candidateRows
            .filter { !$0.report.isReady && $0.candidate.signingRecord != nil }
            .sorted {
                ($0.candidate.signingRecord?.startedAt ?? .distantPast)
                    > ($1.candidate.signingRecord?.startedAt ?? .distantPast)
            }
    }

    /// The dashboard's headline counts, derived from loaded state.
    var counts: DashboardCounts {
        DashboardCounts(
            readyToInstall: candidateRows.filter(\.report.isReady).count,
            signed: candidateRows.filter { $0.candidate.signingRecord != nil }.count,
            installed: installedRows.count,
            updatesAvailable: installedRows.filter { $0.updateState.offersUpdate }.count,
            pendingAttempts: attempts.count
        )
    }

    /// The most recent events across all records, newest first.
    var recentInstalls: [InstallationHistoryEntry] {
        Array(historyEntries.prefix(5))
    }

    /// How many history entries load first, and how many more load when
    /// asked. History is derived in memory, so paging is presentation
    /// pacing, not storage work.
    static let defaultHistoryLimit = 25
    static let historyPageSize = 25

    private var historyLimit = InstallationWorkspaceModel.defaultHistoryLimit

    /// Whether the history shows everything the records hold.
    var showsAllHistory: Bool { historyEntries.count < historyLimit }

    /// Whether anything can be selected for bulk actions.
    var canSelect: Bool { !installedRows.isEmpty }

    /// The selected rows, in display order.
    var selectedRows: [InstalledRow] {
        installedRows.filter { selection.contains($0.id) }
    }

    // MARK: - Dependencies

    private let workspace: InstallationWorkspace?
    private let storage: StorageManagement?
    private let queue: InstallationPreparationQueue
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var exportEntriesByID: [ExportIdentifier: ExportEntry] = [:]

    /// The workspace's preparation queue, exposed for the bulk bar.
    var preparationQueue: InstallationPreparationQueue { queue }

    init(
        workspace: InstallationWorkspace?,
        storage: StorageManagement? = nil,
        queue: InstallationPreparationQueue? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.workspace = workspace
        self.storage = storage
        self.now = now
        if let queue {
            self.queue = queue
        } else if let workspace {
            self.queue = InstallationPreparationQueue(work: Self.makeRunner(workspace: workspace))
        } else {
            self.queue = InstallationPreparationQueue(work: Self.makeRunnerDisabled())
        }

        // An installed-applications change anywhere — a confirmation here,
        // a cleanup in Settings, a future synchronized store — patches the
        // installed rows without rescanning the library.
        NotificationCenter.default.publisher(for: .installedApplicationsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.reloadInstalledState()
                }
            }
            .store(in: &cancellables)

        // A settled preparation job changes the facts a readiness report
        // reads (verification ran; a report was recomputed), so the row's
        // report is refreshed — once per job, never per render.
        self.queue.$jobs
            .sink { [weak self] jobs in
                Task { @MainActor in
                    self?.refreshReportsForSettledJobs(jobs)
                }
            }
            .store(in: &cancellables)
    }

    /// Refreshes readiness for candidates whose preparation jobs settled
    /// since the last look.
    private func refreshReportsForSettledJobs(_ jobs: [InstallationPreparationQueue.Job]) {
        guard phase == .ready else { return }
        for job in jobs where job.state == .completed {
            guard processedJobIDs.insert(job.id).inserted else { continue }
            Task {
                await refreshReadiness(for: job.recordID)
            }
        }
    }

    /// The preparation jobs whose settlement has already been folded into
    /// the dashboard's reports.
    private var processedJobIDs: Set<UUID> = []

    /// Builds the real runner: readiness re-evaluation plus, when the job
    /// asks for it, independent verification through the workspace.
    private static func makeRunner(workspace: InstallationWorkspace) -> InstallationPreparationQueue.Work {
        { job in
            var notes: [String] = []
            var ready = false
            if let report = try? await workspace.readinessReport(forRecordID: job.recordID) {
                ready = report.isReady
                notes.append(report.summary)
            }
            if job.kind == .fullVerification {
                guard let exportID = job.exportID else {
                    return Outcome(
                        summary: "No export is linked to this application, so there is nothing to verify.",
                        isReady: false
                    )
                }
                let record = try await workspace.verifyExport(exportID)
                notes.append("Verification: \(record.verificationStatus.displayName).")
                ready = record.verificationStatus.isPassing && ready
            }
            return Outcome(summary: notes.joined(separator: " "), isReady: ready)
        }
    }

    /// The runner used when no workspace is composed: every job completes
    /// honestly with "nothing to prepare".
    private static func makeRunnerDisabled() -> InstallationPreparationQueue.Work {
        { _ in
            Outcome(summary: "The workspace is not available in this build.", isReady: false)
        }
    }

    // MARK: - Loading

    /// Loads everything the dashboard shows: candidates with readiness,
    /// installed rows with update states, attempts, and the history page.
    func load() async {
        guard let workspace else {
            phase = .failed("The Installation Workspace is not available in this build.")
            return
        }
        do {
            let candidates = try await workspace.candidates()
            let installed = try await workspace.installedRecords()
            let pending = try await workspace.pendingAttempts()
            let updateStates = await workspace.updateStates(for: installed)

            exportEntriesByID = Dictionary(
                uniqueKeysWithValues: candidates.compactMap { candidate in
                    candidate.exportEntry.map { ($0.record.id, $0) }
                }
            )
            let latestExports = await latestExportEntries(for: installed)

            candidateRows = candidates.map { candidate in
                CandidateRow(
                    candidate: candidate,
                    report: workspace.readinessReport(for: candidate),
                    reportDate: now(),
                    installedRecord: installed.first { $0.bundleIdentifier == candidate.bundleIdentifier }
                )
            }
            installedRows = installed.map { record in
                InstalledRow(
                    record: record,
                    updateState: updateStates[record.id] ?? .unknown,
                    latestExportEntry: latestExports[record.id]
                )
            }
            attempts = pending
            selection = selection.filter { id in installed.contains { $0.id == id } }
            await reloadHistory()
            await reloadStorage()
            phase = .ready
        } catch {
            phase = .failed((error as? ZynSignError)?.userMessage
                ?? "The Installation Workspace could not be read.")
        }
    }

    /// Patches the installed rows, attempts, and history after the records
    /// store changed — without rescanning the library. Candidates keep
    /// their cached reports; only the link from a candidate to its
    /// installed record is refreshed.
    private func reloadInstalledState() {
        guard phase == .ready, let workspace else { return }
        Task {
            do {
                let installed = try await workspace.installedRecords()
                let pending = try await workspace.pendingAttempts()
                let updateStates = await workspace.updateStates(for: installed)
                let latestExports = await latestExportEntries(for: installed)
                installedRows = installed.map { record in
                    InstalledRow(
                        record: record,
                        updateState: updateStates[record.id] ?? .unknown,
                        latestExportEntry: latestExports[record.id]
                    )
                }
                attempts = pending
                candidateRows = candidateRows.map { row in
                    CandidateRow(
                        candidate: row.candidate,
                        report: row.report,
                        reportDate: row.reportDate,
                        installedRecord: installed.first {
                            $0.bundleIdentifier == row.candidate.bundleIdentifier
                        }
                    )
                }
                selection = selection.filter { id in installed.contains { $0.id == id } }
                await reloadHistory()
                await reloadStorage()
            } catch {
                notice = Notice(
                    title: "Records unavailable",
                    message: (error as? ZynSignError)?.userMessage
                        ?? "The installed-applications records could not be read."
                )
            }
        }
    }

    /// The export entry behind each record's latest event, resolved with
    /// one pass over the export catalog.
    private func latestExportEntries(
        for records: [InstalledApplicationRecord]
    ) async -> [InstalledApplicationIdentifier: ExportEntry] {
        var result: [InstalledApplicationIdentifier: ExportEntry] = [:]
        for record in records {
            guard let raw = record.latestEvent?.exportIdentifier else { continue }
            let id = ExportIdentifier(rawValue: raw)
            if let cached = exportEntriesByID[id] {
                result[record.id] = cached
            } else if let entry = await workspace?.exportEntry(withID: id) {
                exportEntriesByID[id] = entry
                result[record.id] = entry
            }
        }
        return result
    }

    /// Recomputes one candidate's readiness — after verification or a
    /// changed export — and patches the row.
    func refreshReadiness(for recordID: ApplicationRecordIdentifier) async {
        guard let workspace,
              let index = candidateRows.firstIndex(where: { $0.id == recordID }) else { return }
        guard let fresh = try? await workspace.candidate(for: recordID) else { return }
        let report = workspace.readinessReport(for: fresh)
        if let exportEntry = fresh.exportEntry {
            exportEntriesByID[exportEntry.record.id] = exportEntry
        }
        candidateRows[index] = CandidateRow(
            candidate: fresh,
            report: report,
            reportDate: now(),
            installedRecord: candidateRows[index].installedRecord
        )
    }

    // MARK: - History and storage

    private func reloadHistory() async {
        guard let workspace else {
            historyEntries = []
            return
        }
        historyEntries = (try? await workspace.history(limit: historyLimit)) ?? []
    }

    /// Shows one more page of history.
    func loadMoreHistory() async {
        guard !showsAllHistory, let workspace else { return }
        historyLimit += Self.historyPageSize
        historyEntries = (try? await workspace.history(limit: historyLimit)) ?? []
    }

    private func reloadStorage() async {
        guard let storage else { return }
        let installedBytes = await workspace?.installedRecordsByteCount() ?? nil
        var exportedBytes: Int?
        var temporary: Int?
        if let footprint = try? await storage.footprint() {
            for usage in footprint.usages {
                switch usage.category {
                case .exportedArtifacts: exportedBytes = usage.byteCount
                case .temporaryFiles: temporary = usage.byteCount
                case .importedApplications, .history: continue
                }
            }
        }
        storageSummary = StorageSummary(
            installedRecordsBytes: installedBytes,
            exportedArtifactsBytes: exportedBytes,
            temporaryBytes: temporary
        )
    }

    // MARK: - Delivery and recording

    /// Whether the delivery flow may start for `row`. Readiness gates the
    /// delivery, not preparation.
    func canDeliver(_ row: CandidateRow) -> Bool {
        row.report.isReady
    }

    /// Starts a delivery attempt for a candidate and returns the delivery
    /// package to hand off — or `nil` when the artifact is gone or
    /// readiness does not permit delivery.
    ///
    /// Starting an attempt records only that the user committed to
    /// delivering. Confirming what happened is always a later, explicit
    /// action.
    func startDelivery(
        _ row: CandidateRow,
        intent: InstallationEventKind,
        channel: InstallationChannel
    ) async -> PendingInstallationAttempt? {
        guard let workspace, canDeliver(row) else { return nil }
        do {
            let attempt = try await workspace.startAttempt(
                intent: intent,
                candidate: row.candidate,
                channel: channel,
                now: now()
            )
            attempts = (try? await workspace.pendingAttempts()) ?? attempts
            return attempt
        } catch {
            notice = Notice(
                title: "Could not start the delivery",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The attempt could not be recorded."
            )
            return nil
        }
    }

    /// The delivery package for an attempt's artifact, when the artifact is
    /// still held.
    func deliveryPackage(for attempt: PendingInstallationAttempt) async -> InstallationDeliveryPackage? {
        guard let workspace else { return nil }
        guard let raw = attempt.exportIdentifier else { return nil }
        guard let entry = await workspace.exportEntry(withID: ExportIdentifier(rawValue: raw)),
              entry.isAvailable, let fileURL = entry.fileURL else { return nil }
        return InstallationDeliveryPackage(export: entry.record, fileURL: fileURL)
    }

    /// The delivery package for a candidate's export, when the artifact is
    /// still held.
    func deliveryPackage(for row: CandidateRow) -> InstallationDeliveryPackage? {
        guard let entry = row.candidate.exportEntry,
              entry.isAvailable, let fileURL = entry.fileURL else { return nil }
        return InstallationDeliveryPackage(export: entry.record, fileURL: fileURL)
    }

    /// Confirms an attempt: the user says the delivery happened.
    func confirm(attempt: PendingInstallationAttempt) async {
        guard let workspace else { return }
        do {
            let record = try await workspace.confirmAttempt(withID: attempt.id, now: now())
            notice = Notice(
                title: attempt.intent.displayName,
                message: "\(record.displayOrIdentifier) recorded. ZynSign did not observe the delivery."
            )
            AccessibilityNotification.Announcement(
                InstallationPresentation.confirmationAnnouncement(
                    appName: record.displayOrIdentifier,
                    kind: attempt.intent
                )
            ).post()
            // Patch the dashboard now. A notifying store also announces the
            // change; the patch is idempotent, and stores without
            // notifications still get a fresh read.
            reloadInstalledState()
        } catch {
            notice = Notice(
                title: "Could not confirm",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The attempt could not be confirmed."
            )
        }
    }

    /// Abandons an attempt: the delivery did not happen, or is no longer
    /// intended. The history gains nothing; the artifact stays.
    func abandon(attempt: PendingInstallationAttempt) async {
        guard let workspace else { return }
        do {
            try await workspace.abandonAttempt(withID: attempt.id)
            reloadInstalledState()
        } catch {
            notice = Notice(
                title: "Could not resolve the attempt",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The attempt could not be resolved."
            )
        }
    }

    /// Records an installation after the fact, without an attempt — the
    /// user telling ZynSign what already happened on the device.
    func recordAfterTheFact(
        _ row: CandidateRow,
        intent: InstallationEventKind,
        channel: InstallationChannel = .reportedAfterTheFact
    ) async {
        guard let workspace else { return }
        do {
            let record = try await workspace.recordInstallation(
                intent: intent,
                bundleIdentifier: row.candidate.bundleIdentifier,
                displayName: row.candidate.displayName,
                libraryRecordIdentifier: row.candidate.entry.record.id.rawValue,
                export: row.candidate.exportEntry?.record,
                signingRecord: row.candidate.signingRecord,
                channel: channel,
                now: now()
            )
            notice = Notice(
                title: "Recorded",
                message: "\(record.displayOrIdentifier) is recorded as \(intent.displayName.lowercased())."
            )
            reloadInstalledState()
        } catch {
            notice = Notice(
                title: "Could not record",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The installation could not be recorded."
            )
        }
    }

    // MARK: - Verification

    /// Runs Verify Again for a candidate and refreshes its report with the
    /// fresh verdict.
    func verifyAgain(_ row: CandidateRow) async {
        guard let workspace else { return }
        guard let exportID = row.candidate.exportEntry?.record.id else {
            notice = Notice(
                title: "Nothing to verify",
                message: "No export is linked to this application, so there is no artifact to verify."
            )
            return
        }
        do {
            _ = try await workspace.verifyExport(exportID)
            await refreshReadiness(for: row.id)
            if let refreshed = candidateRows.first(where: { $0.id == row.id }) {
                AccessibilityNotification.Announcement(refreshed.report.spokenSummary).post()
            }
        } catch let error as ZynSignError {
            notice = Notice(title: "Verification unavailable", message: error.userMessage)
        } catch {
            notice = Notice(title: "Verification unavailable", message: "The artifact could not be verified.")
        }
    }

    // MARK: - Records management

    /// Removes one installed record. The exports and the library are
    /// untouched.
    func removeInstalledRecord(_ row: InstalledRow) async {
        guard let workspace else { return }
        do {
            try await workspace.removeInstalledRecord(row.record.id)
            selection.remove(row.id)
            reloadInstalledState()
        } catch {
            notice = Notice(
                title: "Could not remove",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The record could not be removed."
            )
        }
    }

    /// Removes every installed record, after the caller's confirmation.
    /// The exports and the library are untouched.
    func clearAllInstalledRecords() async {
        guard let workspace else { return }
        do {
            try await workspace.removeAllInstalledRecords()
            selection = []
            notice = Notice(
                title: "Records cleared",
                message: "Every installed-application record was removed. Signed artifacts and exports were not touched."
            )
            reloadInstalledState()
        } catch {
            notice = Notice(
                title: "Could not clear",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The records could not be cleared."
            )
        }
    }

    // MARK: - Bulk actions

    /// Queues full verification for every candidate whose artifact is
    /// held. Candidates without a held export get a readiness job instead,
    /// so the queue still reports why they are not ready.
    func verifyAll() {
        let requests = candidateRows.map { row in
            InstallationPreparationQueue.Request(
                kind: .fullVerification,
                recordID: row.id,
                exportID: row.candidate.exportEntry?.record.id,
                applicationName: row.candidate.displayName,
                bundleIdentifier: row.candidate.bundleIdentifier
            )
        }
        queue.enqueueAll(requests)
    }

    /// Queues preparation for every signed candidate: a readiness
    /// re-check for all, plus full verification where an artifact is held.
    /// Only this — preparation — is bulk-queued; delivery is never
    /// bulk-started, because each delivery is a deliberate,
    /// readiness-gated act.
    func prepareAll() {
        let requests = candidateRows.flatMap { row -> [InstallationPreparationQueue.Request] in
            var requests = [
                InstallationPreparationQueue.Request(
                    kind: .readiness,
                    recordID: row.id,
                    exportID: row.candidate.exportEntry?.record.id,
                    applicationName: row.candidate.displayName,
                    bundleIdentifier: row.candidate.bundleIdentifier
                )
            ]
            if row.candidate.exportEntry?.isAvailable == true {
                requests.append(InstallationPreparationQueue.Request(
                    kind: .fullVerification,
                    recordID: row.id,
                    exportID: row.candidate.exportEntry?.record.id,
                    applicationName: row.candidate.displayName,
                    bundleIdentifier: row.candidate.bundleIdentifier
                ))
            }
            return requests
        }
        queue.enqueueAll(requests)
    }

    /// Queues preparation for the selected installed rows' linked
    /// candidates, when the library still holds them.
    func queueSelected() {
        let requests = selectedRows.compactMap { row -> InstallationPreparationQueue.Request? in
            guard let candidate = candidateRows.first(where: {
                $0.candidate.bundleIdentifier == row.record.bundleIdentifier
            }) else { return nil }
            return InstallationPreparationQueue.Request(
                kind: row.latestExportEntry?.isAvailable == true ? .fullVerification : .readiness,
                recordID: candidate.id,
                exportID: candidate.exportEntry?.record.id,
                applicationName: candidate.displayName,
                bundleIdentifier: candidate.bundleIdentifier
            )
        }
        queue.enqueueAll(requests)
    }

    /// Runs the queue's Retry Failed.
    func retryFailedPreparations() {
        queue.retryFailed()
    }

    /// Runs the queue's Clear Completed.
    func clearCompletedPreparations() {
        queue.clearSettled()
    }

    /// Removes the selected installed records. The caller asks first.
    func removeSelectedRecords() async {
        for row in selectedRows {
            await removeInstalledRecord(row)
        }
    }
}

/// The dashboard's headline counts.
extension InstallationWorkspaceModel {

    struct DashboardCounts: Equatable {
        /// Candidates whose readiness report is clear.
        let readyToInstall: Int

        /// Candidates the journal shows as signed, ready or not.
        let signed: Int

        /// Records in the Installed Apps Library.
        let installed: Int

        /// Installed records with a newer held export.
        let updatesAvailable: Int

        /// Attempts awaiting the user's confirmation.
        let pendingAttempts: Int
    }
}
