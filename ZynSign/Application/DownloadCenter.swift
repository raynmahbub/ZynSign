import Foundation

/// The Download Center: ZynSign's job queue for package transfers.
///
/// Every download is a job with its own progress, its own file, and its own
/// outcome. The center — not a screen — owns the work, so leaving the
/// dashboard does not cancel a transfer. Waiting jobs run in list order.
/// Priority decides where a new waiting job is inserted; a transfer that has
/// started is never preempted. Several transfers may run together, up to
/// `maximumConcurrentTransfers`. Raising that bound is a policy change.
///
/// A file is not importable because a repository listed it or because the
/// transfer finished. It becomes Import Ready only after archive, layout,
/// extraction-readiness, and metadata checks pass, and after a declared
/// checksum matches when one was declared. A failed check keeps the original
/// file isolated and does not import it.
///
/// Resume is reported only when the platform actually captured resume data.
/// That data is not a promise the server will accept it. This center does not
/// claim a download survives process death unless that resume data was saved,
/// and a job that was transferring when the process died is restored as
/// failed — never as completed.
///
/// Storage actions delete only the center's own files. They cannot reach
/// imported applications.
@MainActor
final class DownloadCenter: ObservableObject, DownloadTransferObserver {

    /// One download, as the interface sees it.
    struct Job: Identifiable, Equatable {
        let id: DownloadJobIdentifier
        var request: DownloadRequest
        var priority: DownloadJobPriority
        var state: State
        var progress: DownloadTransferProgressFacts
        var enqueuedAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var attemptCount: Int
        var resumeFact: DownloadResumeFact
        var validation: DownloadArtifactValidation?
        var handoff: DownloadHandoff?
        var importJobIDs: [String]
        var replacesJobIDs: [DownloadJobIdentifier]
        var duplicateChoice: DownloadDuplicateChoice?
        var controlRequest: ControlRequest?
        var log: [DownloadLogEntry]

        enum State: Equatable {
            case queued
            case connecting
            case downloading
            case paused
            case validating
            case importReady
            case failed(DownloadJobFailure)
            case cancelled
        }

        enum ControlRequest: Equatable {
            case pause
            case cancel
        }

        var isQueued: Bool { if case .queued = state { return true }; return false }
        var isPaused: Bool { if case .paused = state { return true }; return false }
        var isImportReady: Bool { if case .importReady = state { return true }; return false }
        var isCancelled: Bool { if case .cancelled = state { return true }; return false }
        var isFailed: Bool { if case .failed = state { return true }; return false }
        var isTransferring: Bool {
            switch state {
            case .connecting, .downloading, .validating: return true
            default: return false
            }
        }

        var failure: DownloadJobFailure? {
            if case let .failed(failure) = state { return failure }
            return nil
        }

        var isRetryable: Bool {
            switch state {
            case .failed(let failure): return failure.isRetryable
            case .cancelled: return true
            default: return false
            }
        }

        var stage: DownloadJobStage {
            switch state {
            case .queued: return .queued
            case .connecting: return .connecting
            case .downloading, .paused: return .downloading
            case .validating: return .validating
            case .importReady: return .importReady
            case .failed(let failure): return failure.stage
            case .cancelled: return .queued
            }
        }

        var statusText: String {
            if controlRequest == .cancel { return "Cancelling…" }
            if controlRequest == .pause { return "Pausing…" }
            switch state {
            case .queued: return "Waiting"
            case .connecting: return "Connecting"
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .validating: return "Validating"
            case .importReady: return "Import Ready"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var sourceText: String { request.sourceName }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var pendingNotices: [DownloadNotice] = []
    @Published private(set) var pendingDecisions: [DownloadDuplicatePrompt] = []
    @Published private(set) var updates: [AppUpdateCandidate] = []
    @Published private(set) var history: [DownloadHistoryEntry] = []
    @Published private(set) var ignoredVersions: [IgnoredAppVersion] = []
    @Published private(set) var isRestoring = false

    let maximumConcurrentTransfers: Int

    private let transfer: any DownloadTransferring
    private let validator: any DownloadValidating
    private let store: (any DownloadCenterStoring)?
    private let importer: (any DownloadImporting)?
    private let notifier: (any DownloadNotifying)?
    private let installedApplications: @MainActor () async -> [InstalledApplication]
    private let catalogs: @MainActor () -> [RepositoryCatalog]
    private let manifestResolver: (any InstallManifestResolving)?
    private let now: () -> Date
    private var revision = 0
    private var restoreState: RestoreState = .notStarted
    private var speedSamples: [DownloadJobIdentifier: [SpeedSample]] = [:]
    private var runsSettledSinceIdle = 0
    private var announcedUpdates: [IgnoredAppVersion] = []
    private var reportedSaveFailure = false
    private var isObservingTransfers = false
    private var saveTask: Task<Void, Never>?

    private enum RestoreState { case notStarted, running, finished }

    private static let noticeCapacity = 20
    private static let logCapacity = 48
    private static let estimateMinimumSeconds: TimeInterval = 3
    private static let estimateMinimumFraction = 0.03

    nonisolated init(
        transfer: any DownloadTransferring,
        validator: any DownloadValidating,
        store: (any DownloadCenterStoring)? = nil,
        importer: (any DownloadImporting)? = nil,
        notifier: (any DownloadNotifying)? = nil,
        manifestResolver: (any InstallManifestResolving)? = nil,
        installedApplications: @escaping @MainActor () async -> [InstalledApplication] = { @MainActor in [] },
        catalogs: @escaping @MainActor () -> [RepositoryCatalog] = { @MainActor in [] },
        maximumConcurrentTransfers: Int = 2,
        now: @escaping () -> Date = { Date() }
    ) {
        self.transfer = transfer
        self.validator = validator
        self.store = store
        self.importer = importer
        self.notifier = notifier
        self.manifestResolver = manifestResolver
        self.installedApplications = installedApplications
        self.catalogs = catalogs
        self.now = now
        self.maximumConcurrentTransfers = min(4, max(1, maximumConcurrentTransfers))
    }

    /// Attaches this center as the transfer observer. Called once after init
    /// because the observer relationship cannot be formed from a nonisolated
    /// initializer without capturing `self` early.
    func startObservingTransfers() {
        ensureObserving()
    }

    private func ensureObserving() {
        guard !isObservingTransfers else { return }
        isObservingTransfers = true
        transfer.setObserver(self)
    }

    var activeJobs: [Job] { jobs.filter(\.isTransferring) }
    var queuedJobs: [Job] { jobs.filter(\.isQueued) }
    var pausedJobs: [Job] { jobs.filter(\.isPaused) }
    var completedJobs: [Job] { jobs.filter(\.isImportReady) }
    var failedJobs: [Job] { jobs.filter(\.isFailed) }
    var cancelledJobs: [Job] { jobs.filter(\.isCancelled) }

    func job(withID id: DownloadJobIdentifier) -> Job? {
        jobs.first { $0.id == id }
    }

    // MARK: - Restore

    /// Restores the persisted queue once. Settled jobs return as they settled.
    /// A job that was transferring is failed as interrupted and is never
    /// marked complete. Queued jobs stay queued and may start after restore.
    func restore() async {
        switch restoreState {
        case .finished:
            return
        case .running:
            while restoreState == .running {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return
        case .notStarted:
            restoreState = .running
            isRestoring = true
            await performRestore()
            isRestoring = false
            restoreState = .finished
            scheduleNextJobs()
        }
    }

    private func performRestore() async {
        guard let store else { return }
        let snapshot: DownloadCenterSnapshot?
        do {
            snapshot = try await store.load()
        } catch {
            postNotice(kind: .validationFailed, title: "Downloads not restored", message: "The saved download queue could not be read. Nothing was imported.", jobID: nil)
            return
        }
        guard let snapshot else { return }
        revision = max(revision, snapshot.revision)
        history = snapshot.history
        ignoredVersions = snapshot.ignoredVersions
        announcedUpdates = snapshot.announcedUpdates
        var restored: [Job] = []
        for record in snapshot.jobs {
            if let job = await restore(record) {
                restored.append(job)
            }
        }
        jobs = restored
        let referenced = Set(jobs.map(\.id))
        await store.recoverUnreferencedFiles(referencedJobIDs: referenced)
    }

    private func restore(_ record: DownloadJobRecord) async -> Job? {
        guard let id = DownloadJobIdentifier(rawValue: record.id), let remote = URL(string: record.remoteURL) else {
            return nil
        }
        let priority = DownloadJobPriority(rawValue: record.priority) ?? .normal
        var state = Self.state(from: record)
        var resumeFact = DownloadResumeFact(rawValue: record.resumeFact) ?? .notCaptured
        var log = record.log
        switch state {
        case .connecting, .downloading, .validating:
            let stage: DownloadJobStage = {
                switch state {
                case .validating: return .validating
                case .downloading: return .downloading
                default: return .connecting
                }
            }()
            if resumeFact == .held, let store, await store.loadResumeData(jobID: id) != nil {
                resumeFact = .held
            } else {
                resumeFact = .notCaptured
            }
            state = .failed(DownloadJobFailure(
                stage: stage,
                summary: "The download was interrupted. It was not completed.",
                detail: resumeFact.explanation,
                isRetryable: true,
                occurredAt: now()
            ))
            log.append(DownloadLogEntry(timestamp: now(), message: "Restored as interrupted. Not marked complete."))
        case .paused:
            if resumeFact == .held, let store, await store.loadResumeData(jobID: id) == nil {
                resumeFact = .notCaptured
                log.append(DownloadLogEntry(timestamp: now(), message: resumeFact.explanation))
            }
        default:
            break
        }
        return Job(
            id: id,
            request: Self.request(from: record, remoteURL: remote),
            priority: priority,
            state: state,
            progress: DownloadTransferProgressFacts(
                receivedBytes: record.receivedBytes,
                expectedBytes: record.expectedTransferBytes,
                bytesPerSecond: nil,
                estimatedRemainingSeconds: nil
            ),
            enqueuedAt: record.enqueuedAt,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            attemptCount: record.attemptCount,
            resumeFact: resumeFact,
            validation: record.validation,
            handoff: record.handoff.flatMap(DownloadHandoff.init(rawValue:)),
            importJobIDs: record.importJobIDs,
            replacesJobIDs: record.replacesJobIDs.compactMap(DownloadJobIdentifier.init(rawValue:)),
            duplicateChoice: record.duplicateChoice.flatMap(DownloadDuplicateChoice.init(rawValue:)),
            controlRequest: nil,
            log: log
        )
    }

    // MARK: - Enqueue

    /// Queues a user-supplied link. Install manifests are resolved before a
    /// package job exists. A manifest that does not name an https package
    /// downloads nothing.
    func enqueueUserLink(_ raw: String, priority: DownloadJobPriority = .normal) async -> DownloadEnqueueResult {
        switch DownloadURLPolicy.classifyUserLink(raw) {
        case let .failure(rejection):
            return .rejected(rejection.userMessage)
        case let .success(.artifact(url)):
            let name = url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent
            let request = DownloadRequest(
                displayName: name,
                bundleIdentifier: nil,
                version: nil,
                build: nil,
                sourceName: url.host ?? "Direct link",
                sourceKind: DownloadRequest.kindDirectLink,
                sourceIdentifier: nil,
                remoteURL: url,
                iconURL: nil,
                expectedSHA256: nil,
                expectedByteCount: nil,
                releaseNotes: nil,
                releaseDate: nil,
                versionHistory: []
            )
            return await enqueue(request, priority: priority)
        case let .success(.installManifest(url)):
            guard let manifestResolver else {
                return .rejected("Install manifests cannot be read in this build. Nothing was downloaded.")
            }
            guard let packageURL = await manifestResolver.resolveInstallManifest(at: url) else {
                return .rejected("The install manifest did not contain an https app package address. Nothing was downloaded.")
            }
            let name = packageURL.lastPathComponent.isEmpty ? "Download" : packageURL.lastPathComponent
            let request = DownloadRequest(
                displayName: name,
                bundleIdentifier: nil,
                version: nil,
                build: nil,
                sourceName: "Install manifest",
                sourceKind: DownloadRequest.kindDirectLink,
                sourceIdentifier: nil,
                remoteURL: packageURL,
                iconURL: nil,
                expectedSHA256: nil,
                expectedByteCount: nil,
                releaseNotes: nil,
                releaseDate: nil,
                versionHistory: []
            )
            return await enqueue(request, priority: priority)
        }
    }

    /// Queues a request, or asks the user to decide when it collides with
    /// something already held. Repository-backed addresses must appear in a
    /// configured, already-validated catalog.
    func enqueue(
        _ request: DownloadRequest,
        priority: DownloadJobPriority = .normal,
        resolution: DownloadDuplicateChoice? = nil
    ) async -> DownloadEnqueueResult {
        guard case .success = DownloadURLPolicy.validateHTTPS(request.remoteURL) else {
            return .rejected(DownloadURLRejection.unsupportedScheme.userMessage)
        }
        if request.isRepositoryBacked && !urlIsInConfiguredCatalogs(request.remoteURL) {
            return .rejected("Refresh the source before downloading. ZynSign has not validated this address in a configured repository.")
        }
        if jobs.contains(where: { $0.request.remoteURL == request.remoteURL && ($0.isQueued || $0.isTransferring || $0.isPaused) }) {
            return .rejected("This download is already in the queue.")
        }
        let conflicts = await conflicts(for: request)
        if !conflicts.isEmpty && resolution == nil {
            let prompt = DownloadDuplicatePrompt(id: UUID(), request: request, priority: priority, conflicts: conflicts)
            pendingDecisions.append(prompt)
            return .needsDecision(prompt.id)
        }
        if resolution == .skip {
            return .skipped
        }
        let id = DownloadJobIdentifier()
        let replaces = resolution == .replace ? conflicts.compactMap { $0.downloadJobID.flatMap(DownloadJobIdentifier.init(rawValue:)) } : []
        var job = Job(
            id: id,
            request: request,
            priority: priority,
            state: .queued,
            progress: .empty,
            enqueuedAt: now(),
            startedAt: nil,
            finishedAt: nil,
            attemptCount: 0,
            resumeFact: .notCaptured,
            validation: nil,
            handoff: nil,
            importJobIDs: [],
            replacesJobIDs: replaces,
            duplicateChoice: resolution,
            controlRequest: nil,
            log: [DownloadLogEntry(timestamp: now(), message: "Queued · \(priority.displayName) priority.")]
        )
        if resolution == .replace {
            appendLog(to: &job, "Will replace a previous download after validation. Imported apps are not deleted.")
        }
        jobs.insert(job, at: insertionIndex(for: priority))
        persist()
        scheduleNextJobs()
        return .queued(id)
    }

    func resolveDuplicate(_ promptID: UUID, choice: DownloadDuplicateChoice) async -> DownloadEnqueueResult {
        guard let prompt = pendingDecisions.first(where: { $0.id == promptID }) else {
            return .rejected("That decision is no longer waiting.")
        }
        pendingDecisions.removeAll { $0.id == promptID }
        if choice == .skip { return .skipped }
        return await enqueue(prompt.request, priority: prompt.priority, resolution: choice)
    }

    func dismissDuplicate(_ promptID: UUID) {
        pendingDecisions.removeAll { $0.id == promptID }
    }

    // MARK: - Controls

    func setPriority(_ priority: DownloadJobPriority, on id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isQueued, jobs[index].priority != priority else { return }
        var job = jobs.remove(at: index)
        job.priority = priority
        appendLog(to: &job, "Priority set to \(priority.displayName).")
        jobs.insert(job, at: insertionIndex(for: priority))
        persist()
        scheduleNextJobs()
    }

    func move(_ id: DownloadJobIdentifier, up: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isQueued else { return }
        let waiting = jobs.indices.filter { jobs[$0].isQueued }
        guard let position = waiting.firstIndex(of: index) else { return }
        let target = up ? position - 1 : position + 1
        guard waiting.indices.contains(target) else { return }
        jobs.swapAt(index, waiting[target])
        persist()
    }

    func sendToTop(_ id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isQueued else { return }
        let waiting = jobs.indices.filter { jobs[$0].isQueued }
        guard let top = waiting.first, top != index else { return }
        let topID = jobs[top].id
        var job = jobs.remove(at: index)
        appendLog(to: &job, "Sent to the top of the queue.")
        guard let topIndex = jobs.firstIndex(where: { $0.id == topID }) else {
            jobs.append(job)
            persist()
            return
        }
        jobs.insert(job, at: topIndex)
        persist()
    }

    func pause(_ id: DownloadJobIdentifier) {
        ensureObserving()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .connecting || jobs[index].state == .downloading else { return }
        jobs[index].controlRequest = .pause
        appendLog(to: &jobs[index], "Pause requested.")
        transfer.pause(jobID: id)
    }

    func resume(_ id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isPaused else { return }
        let fact = jobs[index].resumeFact
        jobs[index].state = .queued
        jobs[index].controlRequest = nil
        appendLog(to: &jobs[index], fact == .held
            ? "Resume requested. \(fact.explanation)"
            : "Resume requested. \(DownloadResumeFact.notCaptured.explanation)")
        persist()
        scheduleNextJobs()
    }

    func cancel(_ id: DownloadJobIdentifier) {
        ensureObserving()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            settleCancelled(at: index, message: "Cancelled before it started.")
        case .connecting, .downloading, .validating:
            jobs[index].controlRequest = .cancel
            appendLog(to: &jobs[index], "Cancel requested.")
            transfer.cancel(jobID: id)
        case .paused:
            settleCancelled(at: index, message: "Cancelled while paused.")
            let jobID = jobs[index].id
            Task { await self.store?.removeJobFiles(jobID: jobID, includingArtifact: false) }
        default:
            break
        }
    }

    func cancelAllWaiting() {
        for id in jobs.filter(\.isQueued).map(\.id) { cancel(id) }
    }

    func retry(_ id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isRetryable else { return }
        var job = jobs.remove(at: index)
        if job.resumeFact != .held {
            job.progress = .empty
            job.resumeFact = .notCaptured
        }
        job.state = .queued
        job.finishedAt = nil
        job.controlRequest = nil
        job.validation = nil
        appendLog(to: &job, job.resumeFact == .held
            ? "Retry will try the saved resume data. \(job.resumeFact.explanation)"
            : "Retry starts the download again.")
        jobs.insert(job, at: insertionIndex(for: job.priority))
        persist()
        scheduleNextJobs()
    }

    func retryAllFailed() {
        for id in jobs.filter(\.isRetryable).map(\.id) { retry(id) }
    }

    /// Removes completed downloads from the list and deletes their files.
    /// History remains. Imported applications are not touched.
    func clearCompleted() {
        let ids = jobs.filter(\.isImportReady).map(\.id)
        guard !ids.isEmpty else { return }
        jobs.removeAll { $0.isImportReady }
        for index in history.indices where ids.map(\.rawValue).contains(history[index].jobID ?? "") {
            history[index].fileRetained = false
        }
        persist()
        Task {
            for id in ids {
                await self.store?.removeJobFiles(jobID: id, includingArtifact: true)
            }
        }
    }

    func clearCancelled() {
        jobs.removeAll(\.isCancelled)
        persist()
    }

    /// Removes one download and its center-owned files. Never a library app.
    func removeDownload(_ id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].isTransferring {
            cancel(id)
        }
        jobs.removeAll { $0.id == id }
        for historyIndex in history.indices where history[historyIndex].jobID == id.rawValue {
            history[historyIndex].fileRetained = false
        }
        persist()
        Task { await self.store?.removeJobFiles(jobID: id, includingArtifact: true) }
    }

    /// Deletes partials, isolated rejects, and resume data that no paused job
    /// still needs. Validated packages and imported apps are kept.
    @discardableResult
    func clearTemporaryData() async -> Int {
        let preserve = Set(jobs.filter { $0.isTransferring || ($0.isPaused && $0.resumeFact == .held) }.map(\.id))
        let removed = await store?.clearTemporaryData(keepingResumeFor: preserve) ?? 0
        appendSessionLog("Cleared temporary download data. Imported apps were not touched.")
        return removed
    }

    func storageReport() async -> DownloadStorageReport {
        let completed = Set(jobs.filter(\.isImportReady).map(\.id))
        return await store?.storageReport(completedJobIDs: completed) ?? .empty
    }

    // MARK: - Handoff

    /// Imports a validated file through the Import Hub. Does nothing when
    /// validation has not passed. Does not delete the download, and does not sign.
    func importNow(_ id: DownloadJobIdentifier) async -> String? {
        guard jobs.contains(where: { $0.id == id && $0.isImportReady }) else {
            return "This download is not ready to import."
        }
        guard let importer else { return "Import is not available in this build." }
        guard let store, let fileURL = await store.artifactURL(jobID: id) else {
            return "The downloaded file is no longer in the Download Center."
        }
        let identifiers = await importer.importDownloadedPackage(at: fileURL)
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return "That download is no longer listed."
        }
        jobs[index].handoff = .imported
        jobs[index].importJobIDs = identifiers.map(\.rawValue)
        appendLog(to: &jobs[index], "Handed to Import. Signing was not started.")
        persist()
        return nil
    }

    /// Imports the file and records that the user wants to sign it later.
    /// Signing is not queued and not started: a certificate and profile still
    /// have to be confirmed in the signing flow.
    func requestSigningHandoff(_ id: DownloadJobIdentifier) async -> String? {
        if let message = await importNow(id) { return message }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return "That download is no longer listed." }
        jobs[index].handoff = .signingRequested
        appendLog(to: &jobs[index], "Import started. Signing has not started and was not queued automatically.")
        persist()
        return nil
    }

    /// Records that the user wants to keep the file without importing it.
    func keepDownloaded(_ id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isImportReady else { return }
        jobs[index].handoff = .kept
        appendLog(to: &jobs[index], "Kept in Downloads. Nothing was imported.")
        persist()
    }

    func artifactURL(for id: DownloadJobIdentifier) async -> URL? {
        await store?.artifactURL(jobID: id)
    }

    // MARK: - Updates

    /// Recomputes updates from the catalogs and installed applications the
    /// composition root supplied. Only those catalogs are considered.
    func refreshUpdates() async {
        let installed = await installedApplications()
        let next = UpdatePlanner.candidates(installed: installed, catalogs: catalogs(), ignored: ignoredVersions)
        let previous = Set(announcedUpdates.map { $0.bundleIdentifier + "|" + $0.version })
        updates = next
        for candidate in next {
            let key = candidate.bundleIdentifier + "|" + candidate.latestVersion
            guard !previous.contains(key) else { continue }
            announcedUpdates.append(IgnoredAppVersion(bundleIdentifier: candidate.bundleIdentifier, version: candidate.latestVersion))
            postNotice(
                kind: .updateAvailable,
                title: "Update available",
                message: "\(candidate.name) \(candidate.comparisonText) from \(candidate.sourceName).",
                jobID: nil
            )
        }
        persist()
    }

    func ignore(_ candidate: AppUpdateCandidate) {
        let ignored = IgnoredAppVersion(bundleIdentifier: candidate.bundleIdentifier, version: candidate.latestVersion)
        guard !ignoredVersions.contains(ignored) else { return }
        ignoredVersions.append(ignored)
        updates.removeAll { $0.id == candidate.id }
        persist()
    }

    func update(_ candidate: AppUpdateCandidate, priority: DownloadJobPriority = .normal) async -> DownloadEnqueueResult {
        await enqueue(candidate.downloadRequest, priority: priority)
    }

    /// Queues every current update. Collisions become decisions instead of
    /// silent overwrites. Returns how many were queued and how many need a decision.
    func updateAll(priority: DownloadJobPriority = .normal) async -> (queued: Int, needsDecision: Int) {
        var queued = 0
        var needsDecision = 0
        for candidate in updates {
            switch await enqueue(candidate.downloadRequest, priority: priority) {
            case .queued: queued += 1
            case .needsDecision: needsDecision += 1
            case .rejected, .skipped: break
            }
        }
        return (queued, needsDecision)
    }

    func acknowledgeNotice(_ id: UUID) {
        pendingNotices.removeAll { $0.id == id }
    }

    // MARK: - Transfer observer

    nonisolated func downloadTransfer(_ jobID: DownloadJobIdentifier, progress: DownloadTransferProgress) {
        Task { @MainActor in
            self.apply(progress, to: jobID)
        }
    }

    nonisolated func downloadTransfer(_ jobID: DownloadJobIdentifier, finished: DownloadTransferFinish) {
        Task { @MainActor in
            await self.apply(finished, to: jobID)
        }
    }

    // MARK: - Scheduling

    private func scheduleNextJobs() {
        guard restoreState != .running else { return }
        let running = jobs.filter(\.isTransferring).count
        let slots = maximumConcurrentTransfers - running
        guard slots > 0 else { return }
        for job in jobs.filter(\.isQueued).prefix(slots) {
            let id = job.id
            Task { await self.beginTransfer(id) }
        }
    }

    private func beginTransfer(_ id: DownloadJobIdentifier) async {
        ensureObserving()
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isQueued else { return }
        guard let store else {
            fail(id, stage: .connecting, summary: "Download storage is not available.", detail: nil, retryable: false)
            return
        }
        let directory: URL
        do {
            directory = try await store.prepareIncomingDirectory(jobID: id)
        } catch {
            fail(id, stage: .connecting, summary: "ZynSign could not prepare a private folder for this download.", detail: nil, retryable: true)
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isQueued else { return }
        let resume = jobs[index].resumeFact == .held ? await store.loadResumeData(jobID: id) : nil
        if jobs[index].resumeFact == .held && resume == nil {
            jobs[index].resumeFact = .notCaptured
            jobs[index].progress = .empty
            appendLog(to: &jobs[index], DownloadResumeFact.notCaptured.explanation)
        }
        jobs[index].state = .connecting
        jobs[index].startedAt = jobs[index].startedAt ?? now()
        jobs[index].attemptCount += 1
        jobs[index].controlRequest = nil
        speedSamples[id] = [SpeedSample(time: now(), bytes: jobs[index].progress.receivedBytes)]
        appendLog(to: &jobs[index], resume == nil ? "Connecting." : "Connecting with saved resume data.")
        persist()
        transfer.start(DownloadTransferRequest(
            jobID: id,
            url: jobs[index].request.remoteURL,
            destinationDirectory: directory,
            resumeData: resume
        ))
    }

    private func apply(_ progress: DownloadTransferProgress, to id: DownloadJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .connecting || jobs[index].state == .downloading else { return }
        if progress.receivedBytes > 0 && jobs[index].state == .connecting {
            jobs[index].state = .downloading
            appendLog(to: &jobs[index], "Downloading.")
        }
        var facts = jobs[index].progress
        facts.receivedBytes = max(facts.receivedBytes, progress.receivedBytes)
        if let expected = progress.expectedBytes, expected > 0 {
            facts.expectedBytes = expected
        }
        let sample = SpeedSample(time: now(), bytes: facts.receivedBytes)
        var samples = speedSamples[id] ?? []
        samples.append(sample)
        let windowStart = sample.time.addingTimeInterval(-4)
        samples.removeAll { $0.time < windowStart }
        speedSamples[id] = samples
        if let first = samples.first, sample.time.timeIntervalSince(first.time) >= 0.5 {
            let elapsed = sample.time.timeIntervalSince(first.time)
            let delta = Double(sample.bytes - first.bytes)
            facts.bytesPerSecond = delta > 0 && elapsed > 0 ? delta / elapsed : facts.bytesPerSecond
        }
        if let started = jobs[index].startedAt,
           let fraction = facts.fraction,
           let speed = facts.bytesPerSecond,
           speed > 1,
           let remaining = facts.remainingBytes,
           now().timeIntervalSince(started) >= Self.estimateMinimumSeconds,
           fraction >= Self.estimateMinimumFraction {
            facts.estimatedRemainingSeconds = Double(remaining) / speed
        } else {
            facts.estimatedRemainingSeconds = nil
        }
        jobs[index].progress = facts
    }

    private func apply(_ finish: DownloadTransferFinish, to id: DownloadJobIdentifier) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch finish {
        case let .completed(fileURL, byteCount):
            jobs[index].progress.receivedBytes = max(jobs[index].progress.receivedBytes, byteCount)
            jobs[index].state = .validating
            jobs[index].controlRequest = nil
            appendLog(to: &jobs[index], "Validating the downloaded file.")
            persist()
            let expected = jobs[index].request.expectedSHA256
            let validation = await validator.validate(fileAt: fileURL, expectedSHA256: expected)
            await finishValidation(id, validation: validation, fileURL: fileURL)
        case let .paused(resumeData):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            if let resumeData, !resumeData.isEmpty {
                try? await store?.storeResumeData(resumeData, jobID: id)
                jobs[index].resumeFact = .held
            } else {
                jobs[index].resumeFact = .notCaptured
                await store?.removeJobFiles(jobID: id, includingArtifact: false)
            }
            jobs[index].state = .paused
            jobs[index].controlRequest = nil
            appendLog(to: &jobs[index], "Paused. \(jobs[index].resumeFact.explanation)")
            persist()
            scheduleNextJobs()
        case let .failed(summary, detail, retryable, resumeData):
            if let resumeData, !resumeData.isEmpty {
                try? await store?.storeResumeData(resumeData, jobID: id)
                if let index = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[index].resumeFact = .held
                }
            } else if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].resumeFact = .notCaptured
            }
            let stage: DownloadJobStage = {
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { return DownloadJobStage.connecting }
                return jobs[index].state == .downloading ? .downloading : .connecting
            }()
            fail(id, stage: stage, summary: summary, detail: detail, retryable: retryable)
        case .cancelled:
            await store?.removeJobFiles(jobID: id, includingArtifact: false)
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            settleCancelled(at: index, message: "Cancelled.")
        }
    }

    private func finishValidation(
        _ id: DownloadJobIdentifier,
        validation: DownloadArtifactValidation,
        fileURL: URL
    ) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].validation = validation
        if validation.isImportReady {
            guard let store else {
                fail(id, stage: .validating, summary: "Download storage is not available. The file was not imported.", detail: nil, retryable: false)
                return
            }
            do {
                try await store.promoteToArtifact(from: fileURL, jobID: id)
            } catch {
                fail(id, stage: .validating, summary: "The file validated, but ZynSign could not store it. It was not imported.", detail: nil, retryable: true)
                return
            }
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].state = .importReady
            jobs[index].finishedAt = now()
            jobs[index].handoff = nil
            appendLog(to: &jobs[index], "Validation passed. The file is ready to import. Signing was not started.")
            recordHistory(for: jobs[index], passed: true, retained: true)
            postNotice(kind: .downloadCompleted, title: "Download completed", message: "\(jobs[index].request.displayName) is ready to import.", jobID: id)
            let replacements = jobs[index].replacesJobIDs
            noteRunSettled()
            persist()
            for replaced in replacements where replaced != id {
                removeReplacedDownload(replaced)
            }
        } else {
            try? await store?.isolate(from: fileURL, jobID: id)
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].state = .failed(DownloadJobFailure(
                stage: .validating,
                summary: validation.summary,
                detail: validation.detail,
                isRetryable: true,
                occurredAt: now()
            ))
            jobs[index].finishedAt = now()
            appendLog(to: &jobs[index], "Validation failed. The file was kept isolated and was not imported.")
            recordHistory(for: jobs[index], passed: false, retained: false)
            postNotice(kind: .validationFailed, title: "Validation failed", message: validation.summary, jobID: id)
            noteRunSettled()
            persist()
        }
        scheduleNextJobs()
    }

    private func removeReplacedDownload(_ id: DownloadJobIdentifier) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        for index in history.indices where history[index].jobID == id.rawValue {
            history[index].fileRetained = false
        }
        persist()
        Task { await self.store?.removeJobFiles(jobID: id, includingArtifact: true) }
    }

    // MARK: - Failure and notices

    private func fail(_ id: DownloadJobIdentifier, stage: DownloadJobStage, summary: String, detail: String?, retryable: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let started = jobs[index].attemptCount > 0 || jobs[index].isTransferring
        jobs[index].state = .failed(DownloadJobFailure(
            stage: stage,
            summary: summary,
            detail: detail,
            isRetryable: retryable,
            occurredAt: now()
        ))
        jobs[index].finishedAt = now()
        jobs[index].controlRequest = nil
        appendLog(to: &jobs[index], summary)
        postNotice(kind: .validationFailed, title: "Download failed", message: summary, jobID: id)
        if started { noteRunSettled() }
        persist()
        scheduleNextJobs()
    }

    private func settleCancelled(at index: Int, message: String) {
        jobs[index].state = .cancelled
        jobs[index].finishedAt = now()
        jobs[index].controlRequest = nil
        appendLog(to: &jobs[index], message)
        if jobs[index].attemptCount > 0 { noteRunSettled() }
        persist()
        scheduleNextJobs()
    }

    private func noteRunSettled() {
        runsSettledSinceIdle += 1
        let busy = jobs.contains { $0.isQueued || $0.isTransferring || $0.isPaused }
        guard !busy, runsSettledSinceIdle > 0 else { return }
        postNotice(kind: .queueFinished, title: "Queue finished", message: "Every download in the queue has settled.", jobID: nil)
        runsSettledSinceIdle = 0
    }

    private func postNotice(kind: DownloadNotice.Kind, title: String, message: String, jobID: DownloadJobIdentifier?) {
        let notice = DownloadNotice(kind: kind, title: title, message: message, jobID: jobID, createdAt: now())
        pendingNotices.append(notice)
        if pendingNotices.count > Self.noticeCapacity {
            pendingNotices.removeFirst(pendingNotices.count - Self.noticeCapacity)
        }
        if let notifier {
            Task { await notifier.notify(notice) }
        }
    }

    private func recordHistory(for job: Job, passed: Bool, retained: Bool) {
        history.insert(DownloadHistoryEntry(
            jobID: job.id.rawValue,
            appName: job.request.displayName,
            version: job.request.version,
            sourceName: job.request.sourceName,
            bundleIdentifier: job.request.bundleIdentifier,
            completedAt: now(),
            validationSummary: job.validation?.summary ?? job.failure?.summary ?? job.statusText,
            validationPassed: passed,
            fileRetained: retained
        ), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    private func appendSessionLog(_ message: String) {
        _ = message
    }

    private func appendLog(to job: inout Job, _ message: String) {
        job.log.append(DownloadLogEntry(timestamp: now(), message: message))
        if job.log.count > Self.logCapacity {
            job.log.removeFirst(job.log.count - Self.logCapacity)
        }
    }

    // MARK: - Duplicates and catalogs

    private func urlIsInConfiguredCatalogs(_ url: URL) -> Bool {
        let absolute = url.absoluteString
        for catalog in catalogs() {
            for app in catalog.apps {
                if app.latest.downloadURL == absolute || app.versions.contains(where: { $0.downloadURL == absolute }) {
                    return true
                }
            }
        }
        return false
    }

    private func conflicts(for request: DownloadRequest) async -> [DownloadDuplicateConflict] {
        guard let bundle = request.bundleIdentifier else { return [] }
        var conflicts: [DownloadDuplicateConflict] = []
        for job in jobs where job.request.bundleIdentifier == bundle {
            let comparison = DeclaredVersionOrder.compare(
                version: job.request.version,
                build: job.request.build,
                with: request.version,
                build: request.build
            )
            let differentSource = job.request.sourceName != request.sourceName
                || job.request.sourceIdentifier != request.sourceIdentifier
            if job.isImportReady, comparison == .orderedSame {
                conflicts.append(DownloadDuplicateConflict(
                    kind: .sameVersionDownloaded,
                    existingName: job.request.displayName,
                    existingVersion: job.request.version,
                    existingSource: job.request.sourceName,
                    downloadJobID: job.id.rawValue
                ))
            } else if job.isImportReady, comparison == .orderedDescending {
                conflicts.append(DownloadDuplicateConflict(
                    kind: .newerVersionHeld,
                    existingName: job.request.displayName,
                    existingVersion: job.request.version,
                    existingSource: job.request.sourceName,
                    downloadJobID: job.id.rawValue
                ))
            } else if differentSource && (job.isImportReady || job.isQueued || job.isTransferring || job.isPaused) {
                conflicts.append(DownloadDuplicateConflict(
                    kind: .sameAppDifferentSource,
                    existingName: job.request.displayName,
                    existingVersion: job.request.version,
                    existingSource: job.request.sourceName,
                    downloadJobID: job.isImportReady ? job.id.rawValue : nil
                ))
            }
        }
        let installed = await installedApplications()
        for app in installed where app.bundleIdentifier == bundle {
            let comparison = DeclaredVersionOrder.compare(
                version: app.version,
                build: app.build,
                with: request.version,
                build: request.build
            )
            if comparison == .orderedSame {
                conflicts.append(DownloadDuplicateConflict(
                    kind: .sameVersionImported,
                    existingName: app.name,
                    existingVersion: app.version,
                    existingSource: "Library",
                    downloadJobID: nil
                ))
            } else if comparison == .orderedDescending {
                conflicts.append(DownloadDuplicateConflict(
                    kind: .newerVersionHeld,
                    existingName: app.name,
                    existingVersion: app.version,
                    existingSource: "Library",
                    downloadJobID: nil
                ))
            }
        }
        return conflicts
    }

    private func insertionIndex(for priority: DownloadJobPriority) -> Int {
        let queued = jobs.indices.filter { jobs[$0].isQueued }
        if let lower = queued.first(where: { jobs[$0].priority.sortRank > priority.sortRank }) {
            return lower
        }
        if let last = queued.last { return last + 1 }
        return jobs.count
    }

    // MARK: - Persistence

    private func persist() {
        guard let store else { return }
        revision += 1
        let snapshot = DownloadCenterSnapshot(
            revision: revision,
            jobs: jobs.map(Self.record(from:)),
            history: history,
            ignoredVersions: ignoredVersions,
            announcedUpdates: announcedUpdates,
            scheduling: .unused
        )
        let revisionAtSave = revision
        saveTask = Task { @MainActor in
            do {
                try await store.save(snapshot)
            } catch {
                self.noteSaveFailure(revisionAtSave)
            }
        }
    }

    /// Waits for the latest snapshot write. Tests use this so a second center
    /// restores what this one saved. A stale write is refused by the store.
    func flushPersistence() async {
        await saveTask?.value
    }

    private func noteSaveFailure(_ savedRevision: Int) {
        guard !reportedSaveFailure, savedRevision == revision else { return }
        reportedSaveFailure = true
        postNotice(
            kind: .validationFailed,
            title: "Downloads could not be saved",
            message: "The queue is still running, but it may not survive a restart. Imported apps were not changed.",
            jobID: nil
        )
    }

    private static func record(from job: Job) -> DownloadJobRecord {
        DownloadJobRecord(
            id: job.id.rawValue,
            displayName: job.request.displayName,
            bundleIdentifier: job.request.bundleIdentifier,
            version: job.request.version,
            build: job.request.build,
            sourceName: job.request.sourceName,
            sourceKind: job.request.sourceKind,
            sourceIdentifier: job.request.sourceIdentifier,
            remoteURL: job.request.remoteURL.absoluteString,
            iconURL: job.request.iconURL?.absoluteString,
            expectedSHA256: job.request.expectedSHA256,
            expectedByteCount: job.request.expectedByteCount,
            releaseNotes: job.request.releaseNotes,
            releaseDate: job.request.releaseDate,
            versionHistory: job.request.versionHistory,
            priority: job.priority.rawValue,
            state: token(for: job.state),
            stage: job.stage.rawValue,
            failureSummary: job.failure?.summary,
            failureDetail: job.failure?.detail,
            failureRetryable: job.failure?.isRetryable,
            failureAt: job.failure?.occurredAt,
            resumeFact: job.resumeFact.rawValue,
            receivedBytes: job.progress.receivedBytes,
            expectedTransferBytes: job.progress.expectedBytes,
            enqueuedAt: job.enqueuedAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            attemptCount: job.attemptCount,
            validation: job.validation,
            handoff: job.handoff?.rawValue,
            importJobIDs: job.importJobIDs,
            replacesJobIDs: job.replacesJobIDs.map(\.rawValue),
            duplicateChoice: job.duplicateChoice?.rawValue,
            log: job.log
        )
    }

    private static func request(from record: DownloadJobRecord, remoteURL: URL) -> DownloadRequest {
        DownloadRequest(
            displayName: record.displayName,
            bundleIdentifier: record.bundleIdentifier,
            version: record.version,
            build: record.build,
            sourceName: record.sourceName,
            sourceKind: record.sourceKind,
            sourceIdentifier: record.sourceIdentifier,
            remoteURL: remoteURL,
            iconURL: record.iconURL.flatMap(URL.init(string:)),
            expectedSHA256: record.expectedSHA256,
            expectedByteCount: record.expectedByteCount,
            releaseNotes: record.releaseNotes,
            releaseDate: record.releaseDate,
            versionHistory: record.versionHistory
        )
    }

    private static func state(from record: DownloadJobRecord) -> Job.State {
        switch record.state {
        case "queued": return .queued
        case "connecting": return .connecting
        case "downloading": return .downloading
        case "paused": return .paused
        case "validating": return .validating
        case "importReady": return .importReady
        case "cancelled": return .cancelled
        case "failed":
            return .failed(DownloadJobFailure(
                stage: DownloadJobStage(rawValue: record.stage) ?? .downloading,
                summary: record.failureSummary ?? "The download failed.",
                detail: record.failureDetail,
                isRetryable: record.failureRetryable ?? true,
                occurredAt: record.failureAt ?? record.finishedAt ?? record.enqueuedAt
            ))
        default:
            return .failed(DownloadJobFailure(
                stage: .queued,
                summary: "This download was saved in a form this version of ZynSign does not run.",
                detail: nil,
                isRetryable: false,
                occurredAt: record.enqueuedAt
            ))
        }
    }

    private static func token(for state: Job.State) -> String {
        switch state {
        case .queued: return "queued"
        case .connecting: return "connecting"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .validating: return "validating"
        case .importReady: return "importReady"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private struct SpeedSample {
        let time: Date
        let bytes: Int64
    }
}
