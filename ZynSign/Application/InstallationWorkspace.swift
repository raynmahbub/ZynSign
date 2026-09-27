import Foundation

/// One application the Installation Workspace presents: the library entry,
/// the signing run behind it, and the newest export for it, joined.
///
/// A candidate is assembled from what ZynSign holds, all optional except
/// the library entry. The workspace reads the joined facts; it never
/// mutates them, and a candidate with nothing behind it is still a
/// candidate — its readiness report simply says what is missing.
struct InstallationCandidate: Equatable, Sendable {

    /// The library record, with its artifact's current availability.
    let entry: LibraryEntry

    /// The most recent signing run for this application the journal holds,
    /// when it does.
    let signingRecord: SigningRecord?

    /// The newest export for this application, with its artifact's current
    /// availability, when the catalog holds one.
    let exportEntry: ExportEntry?

    /// The application's name, preferring the export's captured name, then
    /// the library record's declared name, then the identifier.
    var displayName: String {
        if let exportEntry { return exportEntry.record.displayName }
        if let declared = entry.record.identity.displayName, !declared.isEmpty { return declared }
        return entry.record.bundleIdentifier.rawValue
    }

    /// The declared bundle identifier.
    var bundleIdentifier: String { entry.record.bundleIdentifier.rawValue }

    /// The declared marketing version, preferring the export's.
    var shortVersion: String? {
        exportEntry?.record.shortVersion ?? entry.record.identity.shortVersionString
    }

    /// The declared build, preferring the export's.
    var buildVersion: String? {
        exportEntry?.record.buildVersion ?? entry.record.identity.buildVersion
    }

    /// The declared version and build, in the form people read them.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Version not declared"
        }
    }

    /// Whether the library artifact behind the entry is held.
    var isLibraryArtifactAvailable: Bool { entry.isArtifactAvailable }
}

/// The Installation Workspace use case: everything ZynSign can establish
/// about taking a signed application from the library to a device record —
/// and nothing it cannot.
///
/// **What it does.** It joins the library, the signing journal, the export
/// catalog, and the installed-applications records into candidates,
/// evaluates readiness from evidence those stores already hold, runs
/// independent verification on demand, records the attempts the user
/// starts and the installations the user confirms, and projects the
/// flattened history.
///
/// **What it never does.** It never installs anything — the capability
/// assessment stays `noDeliveryMechanism`, and no method here changes
/// that. It never confirms an attempt on its own authority, never marks an
/// interrupted delivery as installed, never deletes an export while
/// recording an installation, and never presents a readiness report as a
/// prediction of the platform's decision.
///
/// The type is stateless: the stores own the facts, and every method reads
/// them at call time, so what a screen shows is always what storage holds.
struct InstallationWorkspace {

    /// The library whose signed applications become candidates.
    private let library: ApplicationLibrary

    /// The signing journal, when composed. Candidates without it lose
    /// their signing facts, which readiness reports honestly.
    private let history: (any SigningHistoryStore)?

    /// The export catalog and its artifacts.
    private let exports: ExportCenter

    /// The installed-applications records, when composed.
    private let installed: (any InstalledApplicationStore)?

    /// The independent verifier, when composed. `nil` only in tests that
    /// install no verification; the verify action is then offered nowhere.
    private let verification: VerifyExportedArtifact?

    /// The store's byte-count reader, so the storage report can include the
    /// installed records without the workspace knowing where they live.
    private let installedByteCount: (@Sendable () async -> Int?)?

    init(
        library: ApplicationLibrary,
        history: (any SigningHistoryStore)?,
        exports: ExportCenter,
        installed: (any InstalledApplicationStore)?,
        verification: VerifyExportedArtifact? = nil,
        installedByteCount: (@Sendable () async -> Int?)? = nil
    ) {
        self.library = library
        self.history = history
        self.exports = exports
        self.installed = installed
        self.verification = verification
        self.installedByteCount = installedByteCount
    }

    // MARK: - Candidates

    /// Joins every library entry with the signing run and export ZynSign
    /// holds for it.
    ///
    /// The join is by the library record's identifier first — the precise
    /// link signing runs and exports record — and by declared bundle
    /// identifier second, which is the most an entry signed before the
    /// journal learned record identifiers can say. When several runs or
    /// exports match, the most recent wins.
    func candidates() async throws -> [InstallationCandidate] {
        let entries = try await library.entries()
        let journal = (try? await history?.allRecords()) ?? []
        let exportEntries = (try? await exports.entries()) ?? []
        return entries.map { entry in
            InstallationCandidate(
                entry: entry,
                signingRecord: Self.newestSigningRecord(matching: entry, in: journal),
                exportEntry: Self.newestExportEntry(matching: entry, in: exportEntries)
            )
        }
    }

    /// Assembles the candidate for one library record, when the entry
    /// still exists.
    func candidate(for recordID: ApplicationRecordIdentifier) async throws -> InstallationCandidate? {
        guard let entry = try await library.entry(withID: recordID) else { return nil }
        let journal = (try? await history?.allRecords()) ?? []
        let exportEntries = (try? await exports.entries()) ?? []
        return InstallationCandidate(
            entry: entry,
            signingRecord: Self.newestSigningRecord(matching: entry, in: journal),
            exportEntry: Self.newestExportEntry(matching: entry, in: exportEntries)
        )
    }

    /// The export entry with `id`, with its artifact's current
    /// availability, when the catalog holds one. The workspace's update
    /// flow reads this to reach an artifact whose export outlived the
    /// library entry it was signed from.
    func exportEntry(withID id: ExportIdentifier) async -> ExportEntry? {
        try? await exports.entry(withID: id)
    }

    /// The most recent successful signing run for `entry`, by record
    /// identifier, falling back to the declared bundle identifier.
    private static func newestSigningRecord(
        matching entry: LibraryEntry,
        in journal: [SigningRecord]
    ) -> SigningRecord? {
        let recordID = entry.record.id
        let bundleIdentifier = entry.record.bundleIdentifier.rawValue
        return journal
            .filter { $0.outcome == .succeeded }
            .filter { record in
                if let source = record.sourceRecordID { return source == recordID }
                return record.sourceBundleIdentifier == bundleIdentifier
            }
            .max { $0.startedAt < $1.startedAt }
    }

    /// The newest export for `entry`, by record identifier, falling back to
    /// the declared bundle identifier.
    private static func newestExportEntry(
        matching entry: LibraryEntry,
        in entries: [ExportEntry]
    ) -> ExportEntry? {
        let recordID = entry.record.id
        let bundleIdentifier = entry.record.bundleIdentifier.rawValue
        return entries
            .filter { export in
                if let source = export.record.sourceRecordID { return source == recordID }
                return export.record.bundleIdentifier == bundleIdentifier
            }
            .max { $0.record.createdAt < $1.record.createdAt }
    }

    // MARK: - Readiness

    /// Evaluates readiness for a candidate, from evidence the stores hold.
    ///
    /// A verification whose record carries no timestamp reads as "never
    /// verified" — the default status on old records is the inconclusive
    /// one, and inconclusive is never presented as a pass.
    func readinessReport(for candidate: InstallationCandidate) -> InstallationReadinessReport {
        var evidence = InstallationReadinessEvidence(now: Date())
        evidence.signingOutcome = candidate.signingRecord?.outcome
        if let export = candidate.exportEntry?.record {
            evidence.verificationStatus = export.verificationRecordedAt != nil ? export.verificationStatus : nil
            evidence.fingerprintRecorded = export.fingerprint != nil
            evidence.artifactAvailable = candidate.exportEntry?.isAvailable
            evidence.bundleIdentifier = export.bundleIdentifier
            evidence.displayName = export.applicationName ?? candidate.entry.record.identity.displayName
            evidence.shortVersion = export.shortVersion ?? candidate.entry.record.identity.shortVersionString
        } else {
            evidence.fingerprintRecorded = nil
            evidence.artifactAvailable = nil
            evidence.bundleIdentifier = candidate.entry.record.bundleIdentifier.rawValue
            evidence.displayName = candidate.entry.record.identity.displayName
            evidence.shortVersion = candidate.entry.record.identity.shortVersionString
        }
        evidence.profileExpiresAt = candidate.signingRecord?.profileExpiresAt
        evidence.certificateExpiresAt = candidate.signingRecord?.certificateExpiresAt
        return InstallationReadinessReport.evaluate(evidence)
    }

    /// Evaluates readiness for the library record with `recordID`, when the
    /// entry exists.
    func readinessReport(forRecordID recordID: ApplicationRecordIdentifier) async throws -> InstallationReadinessReport? {
        guard let candidate = try await candidate(for: recordID) else { return nil }
        return readinessReport(for: candidate)
    }

    // MARK: - Verification on demand

    /// Reopens the artifact behind `id` and verifies it independently,
    /// recording the outcome on the export record — the same write the
    /// signing pipeline and the export verification path make.
    ///
    /// - Returns: The updated record, carrying the fresh verification.
    /// - Throws: A typed error when the export or its artifact is gone;
    ///   never a failure report — verification reports its own findings.
    func verifyExport(_ id: ExportIdentifier) async throws -> ExportRecord {
        guard let verification else {
            throw ZynSignError.installationWorkspaceCapabilityUnavailable(detail:
                 "No verifier is composed, so export verification cannot run."
            )
        }
        guard let entry = try await exports.entry(withID: id) else {
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "No export record carries identifier '\(id.rawValue)'."
            )
        }
        guard entry.isAvailable, let fileURL = entry.fileURL else {
            throw ZynSignError.exportArtifactUnavailable(
                diagnosticDetail: "Export storage holds no artifact for export '\(id.rawValue)'."
            )
        }
        let report = try await verification.verify(artifactAt: fileURL)
        return try await exports.recordVerification(report, for: id)
    }

    // MARK: - Installed records

    /// Whether the workspace can keep records at all. Screens check this
    /// before offering record actions.
    var recordsInstalledApplications: Bool { installed != nil }

    /// Every installed-application record, most recently updated first.
    func installedRecords() async throws -> [InstalledApplicationRecord] {
        guard let installed else { return [] }
        return try await installed.allRecords()
    }

    /// The record for `bundleIdentifier`, when one exists. One application,
    /// one record: updates and reinstalls append events rather than
    /// creating records.
    func installedRecord(forBundleIdentifier bundleIdentifier: String) async throws -> InstalledApplicationRecord? {
        guard let installed else { return nil }
        return try await installed.allRecords().first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Records one confirmed installation, creating the record on first
    /// confirmation and appending an event afterwards.
    ///
    /// The caller supplies what ZynSign established about the delivery —
    /// the export and signing run behind it, what verification last said —
    /// and the channel the user reported. Nothing here observes the
    /// delivery; the record's honesty rests on being explicit that the
    /// user confirmed it.
    @discardableResult
    func recordInstallation(
        intent: InstallationEventKind,
        bundleIdentifier: String,
        displayName: String?,
        libraryRecordIdentifier: String?,
        export: ExportRecord?,
        signingRecord: SigningRecord?,
        channel: InstallationChannel,
        now: Date = Date()
    ) async throws -> InstalledApplicationRecord {
        guard let installed else {
            throw ZynSignError.installationWorkspaceCapabilityUnavailable(detail:
                 "No installed-applications store is composed, so installations cannot be recorded."
            )
        }
        let event = InstalledApplicationEvent(
            kind: intent,
            at: now,
            shortVersion: export?.shortVersion,
            buildVersion: export?.buildVersion,
            exportIdentifier: export?.id.rawValue,
            exportFileName: export?.fileName,
            signingRecordIdentifier: signingRecord?.id.rawValue,
            verificationStatus: export?.verificationStatus,
            channel: channel
        )
        let existing = try await installed.allRecords().first { $0.bundleIdentifier == bundleIdentifier }
        let record: InstalledApplicationRecord
        if let existing {
            record = existing.appending(event, libraryRecordIdentifier: libraryRecordIdentifier, now: now)
        } else {
            record = InstalledApplicationRecord(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName ?? bundleIdentifier,
                events: [event],
                libraryRecordIdentifier: libraryRecordIdentifier,
                recordedAt: now,
                updatedAt: now
            )
        }
        try await installed.write(record)
        return record
    }

    /// Removes one installed-application record. The exports, the journal,
    /// and the library are untouched: removing the record of an
    /// installation never deletes the signed artifact behind it.
    func removeInstalledRecord(_ id: InstalledApplicationIdentifier) async throws {
        guard let installed else { return }
        try await installed.remove(recordWithID: id)
    }

    /// Removes every installed-application record. Same scope as the
    /// single removal: records only, never artifacts.
    func removeAllInstalledRecords() async throws {
        guard let installed else { return }
        try await installed.removeAllRecords()
    }

    /// Renames a record when the library has learned a better display name
    /// for the application. A no-op when the record does not exist.
    func renameInstalledRecord(_ id: InstalledApplicationIdentifier, to newName: String, now: Date = Date()) async throws {
        guard let installed else { return }
        let records = try await installed.allRecords()
        guard let record = records.first(where: { $0.id == id }) else { return }
        try await installed.write(record.renaming(to: newName, now: now))
    }

    // MARK: - Attempts

    /// Starts a delivery attempt: the user committed to delivering an
    /// artifact through a channel, and ZynSign holds the attempt open until
    /// they say what happened.
    ///
    /// Starting an attempt never touches the artifact, never claims an
    /// outcome, and never starts anything on the platform. It creates the
    /// pending state that makes "what did that delivery become?" an open,
    /// visible question.
    @discardableResult
    func startAttempt(
        intent: InstallationEventKind,
        candidate: InstallationCandidate,
        channel: InstallationChannel,
        now: Date = Date()
    ) async throws -> PendingInstallationAttempt {
        guard let installed else {
            throw ZynSignError.installationWorkspaceCapabilityUnavailable(detail:
                 "No installed-applications store is composed, so attempts cannot be tracked."
            )
        }
        let attempt = PendingInstallationAttempt(
            intent: intent,
            bundleIdentifier: candidate.bundleIdentifier,
            displayName: candidate.displayName,
            libraryRecordIdentifier: candidate.entry.record.id.rawValue,
            exportIdentifier: candidate.exportEntry?.record.id.rawValue,
            exportFileName: candidate.exportEntry?.record.fileName,
            shortVersion: candidate.shortVersion,
            buildVersion: candidate.buildVersion,
            signingRecordIdentifier: candidate.signingRecord?.id.rawValue,
            verificationStatus: candidate.exportEntry?.record.verificationStatus,
            channel: channel,
            startedAt: now
        )
        try await installed.write(attempt)
        return attempt
    }

    /// Every pending attempt, oldest first. An attempt restored from disk
    /// is exactly as pending as it was when the process ended.
    func pendingAttempts() async throws -> [PendingInstallationAttempt] {
        guard let installed else { return [] }
        return try await installed.allAttempts()
    }

    /// Confirms an attempt: the user says the delivery happened. Appends
    /// the attempt's intent as an event, resolves the attempt, and returns
    /// the record it produced.
    ///
    /// The confirmation is the user's, always. No code path calls this on a
    /// timer, on launch, or on any signal ZynSign could observe — because
    /// ZynSign observes no delivery signal at all.
    @discardableResult
    func confirmAttempt(withID id: InstallationEventIdentifier, now: Date = Date()) async throws -> InstalledApplicationRecord {
        guard let installed else {
            throw ZynSignError.installationWorkspaceCapabilityUnavailable(detail:
                 "No installed-applications store is composed, so attempts cannot be confirmed."
            )
        }
        let attempts = try await installed.allAttempts()
        guard let attempt = attempts.first(where: { $0.id == id }) else {
            throw ZynSignError.installationAttemptNotFound(identifier: id.rawValue)
        }
        // Confirmation snapshots only what ZynSign can still see. The
        // lookups are awaited sequentially — the export, then the journal
        // run — so a fact removed since the attempt started is simply
        // absent from the event, never described from memory.
        var export: ExportRecord?
        if let raw = attempt.exportIdentifier {
            export = await exportRecordIfHeld(ExportIdentifier(rawValue: raw))
        }
        var signingRecord: SigningRecord?
        if let raw = attempt.signingRecordIdentifier {
            signingRecord = await journalRecordIfHeld(raw)
        }
        let record = try await recordInstallation(
            intent: attempt.intent,
            bundleIdentifier: attempt.bundleIdentifier,
            displayName: attempt.displayName,
            libraryRecordIdentifier: attempt.libraryRecordIdentifier,
            export: export,
            signingRecord: signingRecord,
            channel: attempt.channel,
            now: now
        )
        try await installed.removeAttempt(withID: id)
        return record
    }

    /// Abandons an attempt: the user says the delivery did not happen, or
    /// they no longer intend it to. The attempt is resolved; no event is
    /// recorded, so the history never gains an installation that did not
    /// happen. The signed artifact, the export, and every earlier event are
    /// untouched.
    func abandonAttempt(withID id: InstallationEventIdentifier) async throws {
        guard let installed else { return }
        try await installed.removeAttempt(withID: id)
    }

    // MARK: - Update state

    /// The newest held export for `bundleIdentifier`, when one exists.
    private func newestHeldExport(forBundleIdentifier bundleIdentifier: String) async -> ExportRecord? {
        guard let entries = try? await exports.entries() else { return nil }
        return entries
            .filter { $0.record.bundleIdentifier == bundleIdentifier && $0.isAvailable }
            .max { $0.record.createdAt < $1.record.createdAt }?
            .record
    }

    /// What the update state is for one installed record: whether ZynSign
    /// holds a newer signed output than the one recorded as installed.
    func updateState(for record: InstalledApplicationRecord) async -> InstallationUpdateState {
        let newest = await newestHeldExport(forBundleIdentifier: record.bundleIdentifier)
        return InstallationUpdateState.evaluate(installed: record, newestExport: newest)
    }

    /// The update states for many records, resolved with one pass over the
    /// export catalog so a list of hundreds of records costs one read.
    func updateStates(for records: [InstalledApplicationRecord]) async -> [InstalledApplicationIdentifier: InstallationUpdateState] {
        var states: [InstalledApplicationIdentifier: InstallationUpdateState] = [:]
        guard !records.isEmpty else { return states }
        var newestByBundleIdentifier: [String: ExportRecord] = [:]
        if let entries = try? await exports.entries() {
            for entry in entries where entry.isAvailable {
                let bundleIdentifier = entry.record.bundleIdentifier
                if let existing = newestByBundleIdentifier[bundleIdentifier],
                   existing.createdAt >= entry.record.createdAt { continue }
                newestByBundleIdentifier[bundleIdentifier] = entry.record
            }
        }
        for record in records {
            states[record.id] = InstallationUpdateState.evaluate(
                installed: record,
                newestExport: newestByBundleIdentifier[record.bundleIdentifier]
            )
        }
        return states
    }

    // MARK: - History

    /// The flattened installation history, newest first, optionally
    /// limited. Derived from the records' events, so it can never disagree
    /// with them.
    func history(limit: Int? = nil) async throws -> [InstallationHistoryEntry] {
        let records = try await installedRecords()
        var entries: [InstallationHistoryEntry] = []
        for record in records {
            for event in record.events {
                entries.append(InstallationHistoryEntry(
                    event: event,
                    recordID: record.id,
                    bundleIdentifier: record.bundleIdentifier,
                    appName: record.displayOrIdentifier
                ))
            }
        }
        entries.sort { $0.event.at > $1.event.at }
        if let limit, entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        return entries
    }

    // MARK: - Storage

    /// The size of the installed-records store, for the storage report.
    /// `nil` when the store cannot measure itself.
    func installedRecordsByteCount() async -> Int? {
        guard let installedByteCount else { return nil }
        return await installedByteCount()
    }

    // MARK: - Journal and export helpers

    /// The export record with `id`, when the catalog holds one and the
    /// artifact is currently held. Confirmation snapshots what ZynSign can
    /// still see; an artifact removed since the attempt started stays
    /// absent from the event rather than being described from memory.
    private func exportRecordIfHeld(_ id: ExportIdentifier) async -> ExportRecord? {
        guard let entry = try? await exports.entry(withID: id), entry.isAvailable else { return nil }
        return entry.record
    }

    /// The signing record with `raw`, when the journal still holds it.
    private func journalRecordIfHeld(_ raw: String) async -> SigningRecord? {
        guard let journal = try? await history?.allRecords() else { return nil }
        return journal.first { $0.id.rawValue == raw }
    }
}
