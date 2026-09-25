import Foundation

/// One signing job as the interface submits it to the queue.
///
/// The submission is everything the *user chose*: which application, which
/// identity, which profile, which entitlements layout. The queue turns it
/// into an execution request when the job runs — deriving the source and
/// output locations through the library's and the composition root's own
/// conventions — so no screen ever computes a file location for a signing
/// job, and a restored job rebuilds its request exactly the way a fresh one
/// was built.
///
/// The profile bytes are the one heavy payload a submission carries. The
/// queue keeps them (and, for persistence, a queue-owned copy on disk) only
/// for as long as the job is listed; removing a job discards both.
struct SigningJobSubmission: Equatable, Sendable {

    /// The library record the job signs.
    let recordID: ApplicationRecordIdentifier

    /// The artifact the record refers to; the source location is derived
    /// from it through the library's own convention.
    let artifactID: ArtifactIdentifier

    /// The application's display name, captured for the queue's list.
    let applicationName: String

    /// The declared bundle identifier, captured for the queue's list and
    /// the history record.
    let bundleIdentifier: String

    /// The declared versions as one display line, when available.
    let versionText: String?

    /// The signing identity to sign with.
    let identityID: SigningIdentityIdentifier

    /// The identity's display name, captured for the job detail screen.
    let identityDisplayName: String?

    /// The certificate's SHA-256 fingerprint, captured for the history
    /// record the run writes.
    let certificateFingerprint: CertificateFingerprint?

    /// The replacement profile's bytes. Read for this job; the queue's
    /// persistence keeps its own copy only while the job is listed.
    let profile: Data

    /// The profile's display name, captured for the job detail screen.
    let profileDisplayName: String?

    /// The profile's team identifier, captured for the job detail screen.
    let profileTeamIdentifier: String?

    /// Whether to emit the deterministic DER entitlements blob and use
    /// CodeDirectory v0x20400 (iOS 15+).
    let emitDEREntitlements: Bool

    /// The preset the configuration came from, when one. Reserved for the
    /// presets milestone; carried now so the queue's schema does not change
    /// later.
    let presetID: PresetIdentifier?

    init(
        recordID: ApplicationRecordIdentifier,
        artifactID: ArtifactIdentifier,
        applicationName: String,
        bundleIdentifier: String,
        versionText: String? = nil,
        identityID: SigningIdentityIdentifier,
        identityDisplayName: String? = nil,
        certificateFingerprint: CertificateFingerprint? = nil,
        profile: Data,
        profileDisplayName: String? = nil,
        profileTeamIdentifier: String? = nil,
        emitDEREntitlements: Bool = false,
        presetID: PresetIdentifier? = nil
    ) {
        self.recordID = recordID
        self.artifactID = artifactID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.versionText = versionText
        self.identityID = identityID
        self.identityDisplayName = identityDisplayName
        self.certificateFingerprint = certificateFingerprint
        self.profile = profile
        self.profileDisplayName = profileDisplayName
        self.profileTeamIdentifier = profileTeamIdentifier
        self.emitDEREntitlements = emitDEREntitlements
        self.presetID = presetID
    }
}

/// One signing job as the executor receives it: fully resolved locations
/// and configuration, plus the display metadata the history record needs.
///
/// The executor runs exactly one job. Everything it needs is here, and
/// nothing here is shared with another job: the source is read-only, the
/// output name is the job's own, and the run's working copy is created
/// fresh per attempt by the pipeline.
struct SigningJobExecutionRequest: Equatable, Sendable {

    /// The job being executed.
    let jobID: SigningJobIdentifier

    /// Which run of the job this is: 1 for the first, 2 after one retry.
    let attempt: Int

    /// The source container to sign. Read but never modified.
    let sourceURL: URL

    /// Where the signed, verified container is delivered. Unique per job.
    let outputURL: URL

    /// The replacement profile's bytes.
    let profile: Data

    /// The signing identity to sign with.
    let identityID: SigningIdentityIdentifier

    /// Whether to emit the DER entitlements blob (CodeDirectory v0x20400).
    let emitDEREntitlements: Bool

    /// The application's display name, for the history record.
    let applicationName: String

    /// The declared bundle identifier, for the history record.
    let bundleIdentifier: String

    /// The declared versions as one display line.
    let versionText: String?

    /// The identity's display name, for the job detail screen.
    let identityDisplayName: String?

    /// The certificate's SHA-256 fingerprint, for the history record.
    let certificateFingerprint: CertificateFingerprint?

    /// The profile's display name, for the job detail screen.
    let profileDisplayName: String?

    /// The profile's team identifier, for the job detail screen.
    let profileTeamIdentifier: String?

    /// The preset the configuration came from, when one.
    let presetID: PresetIdentifier?

    init(
        jobID: SigningJobIdentifier,
        attempt: Int,
        sourceURL: URL,
        outputURL: URL,
        profile: Data,
        identityID: SigningIdentityIdentifier,
        emitDEREntitlements: Bool,
        applicationName: String,
        bundleIdentifier: String,
        versionText: String? = nil,
        identityDisplayName: String? = nil,
        certificateFingerprint: CertificateFingerprint? = nil,
        profileDisplayName: String? = nil,
        profileTeamIdentifier: String? = nil,
        presetID: PresetIdentifier? = nil
    ) {
        self.jobID = jobID
        self.attempt = attempt
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.profile = profile
        self.identityID = identityID
        self.emitDEREntitlements = emitDEREntitlements
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.versionText = versionText
        self.identityDisplayName = identityDisplayName
        self.certificateFingerprint = certificateFingerprint
        self.profileDisplayName = profileDisplayName
        self.profileTeamIdentifier = profileTeamIdentifier
        self.presetID = presetID
    }
}

/// How one execution ended, as the executor reports it.
///
/// A typed failure is a result, not an exception: the executor returns it
/// for everything the pipeline refused or could not finish, with the stage,
/// the explanation, and the retryability already decided. Only
/// infrastructure the executor itself could not reach throws, and
/// cancellation propagates as `CancellationError` like every other use
/// case — the queue settles a cancelled run as cancelled, never as failed.
enum SigningJobExecutionOutcome: Equatable, Sendable {

    /// Every stage passed and the verified container was delivered.
    case completed(SigningJobCompletion)

    /// A stage refused the run or the run failed. Nothing was delivered.
    case failed(SigningJobFailure)
}

/// Receives progress from a signing job as the run produces it.
///
/// Progress is produced on whichever context the work runs on, so
/// implementations are called from more than one thread and must be safe to
/// call concurrently. Reporting is advisory: an implementation that drops
/// reports, coalesces them, or delivers them out of order changes only what
/// the interface shows; it cannot change what the run does. The queue keeps
/// the delivered values monotonic per job.
protocol SigningJobProgressReporting: AnyObject, Sendable {

    /// Reports the job's current stage and, where the stage measures
    /// countable work, how much of it is done.
    func report(_ progress: SigningJobProgress)
}

/// The boundary the signing queue drives: one job, signed once.
///
/// The port exists so the queue — which owns scheduling, priorities,
/// retries, cancellation, notices, and persistence — depends on the
/// *capability* of signing a job rather than on the concrete pipeline.
/// `PipelineSigningExecutor` is the capability's only production
/// implementation, and a test can substitute a controllable one without a
/// filesystem, a container, or a Keychain.
protocol SigningQueueExecuting {

    /// Runs one signing job to an outcome.
    ///
    /// - Parameters:
    ///   - request: the fully resolved job to run. Read-only inputs; the
    ///     output location is the job's own.
    ///   - progress: where the run reports the stages it reaches, or `nil`
    ///     when the caller does not want progress.
    ///
    /// A refused or failed run is a returned outcome, never a thrown
    /// error. `CancellationError` propagates when the run is cancelled.
    /// Anything else that throws is an infrastructure failure the queue
    /// records as a retryable job failure.
    func execute(
        _ request: SigningJobExecutionRequest,
        reporting progress: (any SigningJobProgressReporting)?
    ) async throws -> SigningJobExecutionOutcome
}
