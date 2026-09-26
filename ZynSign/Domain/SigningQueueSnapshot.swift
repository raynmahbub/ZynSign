import Foundation

/// The persisted shape of the signing queue.
///
/// A snapshot is what the queue writes when its list changes and reads back
/// after an interruption. The persistence contract is deliberately narrow:
///
/// - Settled jobs (completed, failed, cancelled) are preserved exactly as
///   they settled — an unfinished job is never marked completed, because
///   only a settlement writes one.
/// - Waiting jobs are preserved with their setup descriptor, so a job the
///   user configured before the interruption can run again after it. The
///   descriptor references the profile by a queue-owned copy's file name;
///   when the copy is gone the job cannot honestly run and is restored as a
///   failure that says so.
/// - A job that was *running* when the snapshot was written cannot be
///   resumed — its working copy belongs to a dead process — so restoration
///   records it as an interrupted failure. Recovery never pretends the work
///   happened.
///
/// The snapshot holds metadata and references only: no private key material
/// (that never leaves the Keychain), and profile bytes live beside the
/// snapshot as separate queue-owned copies, removed when their job is
/// removed or when recovery finds them orphaned.
struct SigningQueueSnapshot: Equatable, Sendable, Codable {

    /// Monotonically increasing save counter. The store refuses to write a
    /// snapshot older than the one it holds, so out-of-order saves can
    /// never resurrect stale queue state.
    var revision: Int

    /// When the snapshot was written.
    var savedAt: Date

    /// The jobs, in queue display order.
    var jobs: [StoredSigningJob]

    init(revision: Int, savedAt: Date, jobs: [StoredSigningJob]) {
        self.revision = revision
        self.savedAt = savedAt
        self.jobs = jobs
    }
}

/// One persisted signing job: the queue's public job value plus the setup
/// descriptor a waiting job needs to run again.
struct StoredSigningJob: Equatable, Sendable, Codable {

    /// The job identifier's canonical string form.
    let id: String

    /// The application's display name, captured when the job was accepted.
    var applicationName: String

    /// The declared bundle identifier.
    var bundleIdentifier: String

    /// The declared versions as one display line, when the package declared
    /// any.
    var versionText: String?

    /// The library record identifier's canonical string form.
    let recordID: String

    /// The library artifact identifier's canonical string form. The source
    /// URL is re-derived from it on restoration through the library's own
    /// location convention — a snapshot never stores a location.
    let artifactID: String

    /// The job's priority.
    var priority: SigningJobPriority

    /// Where the job was asked for.
    var origin: SigningJobOrigin

    /// When the job was accepted.
    var enqueuedAt: Date

    /// When the job's current run started, when it has.
    var startedAt: Date?

    /// When the job settled, when it has.
    var finishedAt: Date?

    /// How many runs the job has made: 1 for a job that ran once, 2 after
    /// one retry, and so on.
    var attemptCount: Int

    /// The lifecycle state as it settled or waits.
    var state: SigningJobState

    /// The last stage the job reported, when it reported one. Progress
    /// percentages are runtime observations and are not persisted; the
    /// stage names where a run stopped or waits.
    var lastStageRawValue: String?

    /// The job's own log, capped by the queue before it is written.
    var log: [SigningJobLogEntry]

    /// The setup a re-run needs, when the job still has one. `nil` for a
    /// settled job whose setup was discarded, and for a restored job whose
    /// setup could not be recovered.
    var setup: StoredSigningJobSetup?

    init(
        id: String,
        applicationName: String,
        bundleIdentifier: String,
        versionText: String?,
        recordID: String,
        artifactID: String,
        priority: SigningJobPriority,
        origin: SigningJobOrigin,
        enqueuedAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        attemptCount: Int,
        state: SigningJobState,
        lastStageRawValue: String?,
        log: [SigningJobLogEntry],
        setup: StoredSigningJobSetup?
    ) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.versionText = versionText
        self.recordID = recordID
        self.artifactID = artifactID
        self.priority = priority
        self.origin = origin
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attemptCount = attemptCount
        self.state = state
        self.lastStageRawValue = lastStageRawValue
        self.log = log
        self.setup = setup
    }
}

/// The persisted setup descriptor of one signing job.
///
/// Everything a fresh run needs except two things that are deliberately not
/// stored here: the source location (re-derived from the artifact
/// identifier through the library's own convention) and the profile bytes
/// (held as a queue-owned copy named by `profileFileName`). Identifiers are
/// stored in their canonical string forms and re-parsed on restoration; a
/// descriptor whose identifier no longer parses restores as a failure
/// rather than a job that silently lost its configuration.
struct StoredSigningJobSetup: Equatable, Sendable, Codable {

    /// The signing identity identifier's canonical string form. The
    /// identity itself lives in the Keychain; only its opaque identifier is
    /// stored.
    let identityID: String

    /// The identity's display name, captured for the detail screen.
    let identityDisplayName: String?

    /// The certificate's SHA-256 fingerprint, captured for the history
    /// record a re-run writes.
    let certificateFingerprint: CertificateFingerprint?

    /// The queue-owned profile copy's file name, or `nil` when no copy was
    /// stored. A waiting job without a copy cannot run again honestly.
    let profileFileName: String?

    /// The profile's display name, captured at configuration time.
    let profileDisplayName: String?

    /// The profile's team identifier, captured at configuration time for
    /// the detail screen.
    let profileTeamIdentifier: String?

    /// Whether the run emits the deterministic DER entitlements blob and
    /// CodeDirectory v0x20400.
    let emitDEREntitlements: Bool

    /// The preset identifier's canonical string form, when the job was
    /// configured from a preset. Reserved for the presets milestone; the
    /// queue carries it so a future preset integration does not change the
    /// snapshot schema.
    let presetID: String?

    init(
        identityID: String,
        identityDisplayName: String?,
        certificateFingerprint: CertificateFingerprint?,
        profileFileName: String?,
        profileDisplayName: String?,
        profileTeamIdentifier: String?,
        emitDEREntitlements: Bool,
        presetID: String?
    ) {
        self.identityID = identityID
        self.identityDisplayName = identityDisplayName
        self.certificateFingerprint = certificateFingerprint
        self.profileFileName = profileFileName
        self.profileDisplayName = profileDisplayName
        self.profileTeamIdentifier = profileTeamIdentifier
        self.emitDEREntitlements = emitDEREntitlements
        self.presetID = presetID
    }
}
