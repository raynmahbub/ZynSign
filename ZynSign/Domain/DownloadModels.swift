import Foundation

/// The stage a download reports while it is active.
///
/// The order is the order the center actually walks. A stage is shown only
/// when the job has entered it. Nothing here is a percentage.
enum DownloadJobStage: String, CaseIterable, Equatable, Hashable, Codable, Sendable {

    case queued
    case connecting
    case downloading
    case validating
    case importReady

    /// The user-presentable name.
    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .connecting: return "Connecting"
        case .downloading: return "Downloading"
        case .validating: return "Validating"
        case .importReady: return "Import Ready"
        }
    }

    /// The SF Symbol for the stage.
    var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .downloading: return "arrow.down.circle"
        case .validating: return "checkmark.shield"
        case .importReady: return "square.and.arrow.down"
        }
    }
}

/// Whether a paused or interrupted transfer has bytes the platform can try
/// to continue from.
///
/// `held` means URLSession produced resume data. It does not mean the server
/// will accept it. `notCaptured` means continuing starts the transfer again.
/// ZynSign never reports a download as resumable without one of these facts,
/// and it never reports `held` as a guarantee.
enum DownloadResumeFact: String, Equatable, Hashable, Codable, Sendable {

    /// No resume data was captured. Continuing starts over.
    case notCaptured

    /// Resume data is stored. Continuing may work if the server accepts it;
    /// if the server refuses, the transfer starts again.
    case held

    /// What the interface should say. Honest in both cases.
    var explanation: String {
        switch self {
        case .notCaptured:
            return "This transfer cannot continue from where it stopped. Resume starts it again."
        case .held:
            return "Resume data was saved. Continuing depends on the server. If the server refuses it, the download starts again."
        }
    }
}

/// Why a download failed, in the center's terms.
struct DownloadJobFailure: Equatable, Hashable, Sendable, Codable {

    /// The stage the transfer or validation stopped at.
    let stage: DownloadJobStage

    /// A short explanation. Never a path, a credential, or a raw server body.
    let summary: String

    /// Technical detail for the expanded failure view. Still redacted.
    let detail: String?

    /// Whether the user may run the job again. A retry is a new attempt. It
    /// continues from resume data only when that data was actually captured.
    let isRetryable: Bool

    /// When the failure was recorded.
    let occurredAt: Date
}

/// Bytes observed for one transfer. A missing expected size is not zero.
struct DownloadTransferProgressFacts: Equatable, Hashable, Sendable, Codable {

    /// Bytes written for this attempt.
    var receivedBytes: Int64

    /// The size the server declared, when it declared one. Catalog sizes are
    /// not stored here: they are hints, not measurements.
    var expectedBytes: Int64?

    /// Recent throughput in bytes per second, when it can be measured.
    var bytesPerSecond: Double?

    /// Seconds remaining, only after the center has enough evidence to estimate.
    var estimatedRemainingSeconds: TimeInterval?

    /// Fraction in `0...1` when the server declared a size. `nil` when it did
    /// not — the interface must not invent a percentage.
    var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    /// Bytes still expected, when the server declared a size.
    var remainingBytes: Int64? {
        guard let expectedBytes else { return nil }
        return max(0, expectedBytes - receivedBytes)
    }

    static let empty = DownloadTransferProgressFacts(
        receivedBytes: 0,
        expectedBytes: nil,
        bytesPerSecond: nil,
        estimatedRemainingSeconds: nil
    )
}

/// What the center concluded about a downloaded file.
///
/// A passing result means the file could be read as an archive, had the
/// expected package layout, was safe to consider for extraction, and declared
/// readable metadata. It is not a signature, trust, or installability claim.
/// A failing result keeps the original file isolated. It is never imported.
struct DownloadArtifactValidation: Equatable, Hashable, Sendable, Codable {

    /// The container's entry table could be read.
    let archiveReadable: Bool

    /// Structural examination accepted a single application bundle.
    let ipaStructureAccepted: Bool

    /// The entry table had no unsafe path the structure rules reject, and the
    /// layout was accepted. No extraction is performed by this check.
    let extractionReady: Bool

    /// The bundle information file was present and declared readable metadata.
    let metadataAvailable: Bool

    /// Whether a declared checksum matched. `nil` when the source declared none.
    /// A match is not trust. A mismatch fails the artifact.
    let checksumMatched: Bool?

    /// The short explanation shown on the job.
    let summary: String

    /// The first technical finding, when examination produced one.
    let detail: String?

    /// When the check finished.
    let checkedAt: Date

    /// Whether the file may be offered for import. Every required check passed.
    var isImportReady: Bool {
        archiveReadable
            && ipaStructureAccepted
            && extractionReady
            && metadataAvailable
            && checksumMatched != false
    }
}

/// One version note carried from repository metadata.
struct DownloadVersionNote: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// The declared version.
    let version: String

    /// The release date as the source declared it, if it declared one.
    let date: String?

    /// What the source said changed, if it said anything.
    let notes: String?

    var id: String { version + "|" + (date ?? "") }
}

/// The address and display facts of one download request.
///
/// This is metadata the user or a validated catalog supplied. It is not
/// evidence the bytes will match, and it carries no file-system location.
struct DownloadRequest: Equatable, Hashable, Sendable, Codable {

    /// The name shown on the job.
    var displayName: String

    /// The bundle identifier, when the source declared one.
    var bundleIdentifier: String?

    /// The declared marketing version, when known.
    var version: String?

    /// The declared build, when known.
    var build: String?

    /// The source's display name. A direct link uses the host.
    var sourceName: String

    /// A stable kind token. Known values are `configuredRepository`,
    /// `directLink`, and `update`. Unknown tokens are preserved so a future
    /// source can round-trip without being dropped.
    var sourceKind: String

    /// The configured repository's identifier, when the request came from one.
    var sourceIdentifier: String?

    /// The https address that will be requested.
    var remoteURL: URL

    /// An https icon address, when the catalog declared a valid one.
    var iconURL: URL?

    /// A declared SHA-256 hex digest, when the catalog included a well-formed one.
    var expectedSHA256: String?

    /// A declared size hint. Not a measurement, and not used as trust.
    var expectedByteCount: Int64?

    /// Release notes for this version, when the catalog included them.
    var releaseNotes: String?

    /// The release date string the catalog declared, if any.
    var releaseDate: String?

    /// Older notes from the same catalog entry, newest first when the catalog
    /// could be ordered.
    var versionHistory: [DownloadVersionNote]

    /// Known source kinds. Others are still stored.
    static let kindRepository = "configuredRepository"
    static let kindDirectLink = "directLink"
    static let kindUpdate = "update"

    /// Whether this request claims to come from a configured repository.
    var isRepositoryBacked: Bool {
        sourceKind == Self.kindRepository || sourceKind == Self.kindUpdate
    }
}

/// How a new download relates to something ZynSign already holds.
enum DownloadDuplicateKind: String, Equatable, Hashable, Codable, Sendable, CaseIterable {

    /// The same bundle and version already has a completed download.
    case sameVersionDownloaded

    /// The library already holds the same bundle and version.
    case sameVersionImported

    /// The library or a completed download holds a newer version.
    case newerVersionHeld

    /// Another source already offers or has transferred the same bundle.
    case sameAppDifferentSource

    var displayName: String {
        switch self {
        case .sameVersionDownloaded: return "Already Downloaded"
        case .sameVersionImported: return "Already Imported"
        case .newerVersionHeld: return "Newer Version Kept"
        case .sameAppDifferentSource: return "Another Source"
        }
    }
}

/// One conflict the user must decide before a download is queued.
struct DownloadDuplicateConflict: Equatable, Hashable, Sendable, Codable, Identifiable {

    let id: UUID
    let kind: DownloadDuplicateKind

    /// The existing item's name.
    let existingName: String

    /// The existing item's version, when it has one.
    let existingVersion: String?

    /// The existing item's source, when it has one.
    let existingSource: String?

    /// A download job this choice may replace. Never a library record.
    /// `nil` when the conflict is an imported application: those are not
    /// deleted from the Download Center.
    let downloadJobID: String?

    init(
        id: UUID = UUID(),
        kind: DownloadDuplicateKind,
        existingName: String,
        existingVersion: String?,
        existingSource: String?,
        downloadJobID: String?
    ) {
        self.id = id
        self.kind = kind
        self.existingName = existingName
        self.existingVersion = existingVersion
        self.existingSource = existingSource
        self.downloadJobID = downloadJobID
    }
}

/// The user's choice when a download would collide with something already held.
///
/// `replace` replaces a Download Center copy only, and only after the new
/// file validates. It never deletes an imported application.
enum DownloadDuplicateChoice: String, Equatable, Hashable, Codable, Sendable {

    case replace
    case keepBoth
    case skip

    var displayName: String {
        switch self {
        case .replace: return "Replace"
        case .keepBoth: return "Keep Both"
        case .skip: return "Skip"
        }
    }
}

/// A decision waiting on the user. Nothing is transferred until they choose.
struct DownloadDuplicatePrompt: Equatable, Identifiable, Sendable {

    let id: UUID
    let request: DownloadRequest
    let priority: DownloadJobPriority
    let conflicts: [DownloadDuplicateConflict]

    /// The explanation shown with the choices. States what Replace will not do.
    var explanation: String {
        let first = conflicts.first
        let subject = first.map { "\($0.kind.displayName): \($0.existingName)" } ?? "An existing copy"
        return "\(subject). Replace removes a previous download only after this one validates. Imported applications are not deleted from here. Keep Both saves a separate download. Skip does not download."
    }
}

/// What the user asked to do with a validated file. Signing is never started
/// by recording one of these.
enum DownloadHandoff: String, Equatable, Hashable, Codable, Sendable {

    /// The file is being kept in the Download Center. Nothing was imported.
    case kept

    /// The user asked to import. The Import Hub owns the rest.
    case imported

    /// The user asked to queue signing after import. The file is imported.
    /// Signing does not start until a later, separate confirmation.
    case signingRequested
}

/// One in-app notification the Download Center posts.
struct DownloadNotice: Equatable, Hashable, Sendable, Identifiable {

    enum Kind: String, Equatable, Hashable, Sendable {
        case downloadCompleted
        case validationFailed
        case updateAvailable
        case queueFinished

        var symbolName: String {
            switch self {
            case .downloadCompleted: return "arrow.down.circle.fill"
            case .validationFailed: return "exclamationmark.shield.fill"
            case .updateAvailable: return "arrow.triangle.2.circlepath"
            case .queueFinished: return "checklist"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let message: String
    let jobID: DownloadJobIdentifier?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        message: String,
        jobID: DownloadJobIdentifier? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.jobID = jobID
        self.createdAt = createdAt
    }
}

/// A lightweight history row. It does not hold the file, and removing it
/// never removes a library application.
struct DownloadHistoryEntry: Equatable, Hashable, Sendable, Codable, Identifiable {

    let id: UUID
    /// The download job that produced the row, when it is still known.
    let jobID: String?
    let appName: String
    let version: String?
    let sourceName: String
    let bundleIdentifier: String?
    let completedAt: Date
    let validationSummary: String
    let validationPassed: Bool

    /// Whether the Download Center still has the file. Independent of the library.
    var fileRetained: Bool

    /// The library record identifier, when import later reported one. Optional
    /// and never required to reopen: the bundle identifier is enough to find
    /// the app in the library.
    var libraryRecordID: String?

    init(
        id: UUID = UUID(),
        jobID: String? = nil,
        appName: String,
        version: String?,
        sourceName: String,
        bundleIdentifier: String?,
        completedAt: Date,
        validationSummary: String,
        validationPassed: Bool,
        fileRetained: Bool,
        libraryRecordID: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.appName = appName
        self.version = version
        self.sourceName = sourceName
        self.bundleIdentifier = bundleIdentifier
        self.completedAt = completedAt
        self.validationSummary = validationSummary
        self.validationPassed = validationPassed
        self.fileRetained = fileRetained
        self.libraryRecordID = libraryRecordID
    }
}

/// A version the user asked not to be offered again.
struct IgnoredAppVersion: Equatable, Hashable, Sendable, Codable {
    let bundleIdentifier: String
    let version: String
}

/// Storage the Download Center accounts for.
///
/// Imported applications are not a category here. Cleanup of these numbers
/// cannot reach the library. Completed-download bytes are a subset of the
/// downloaded-IPA bytes, so the total does not add them twice.
struct DownloadStorageReport: Equatable, Sendable {

    /// Validated package files the center still holds.
    var downloadedIPABytes: Int64
    var downloadedIPACount: Int

    /// Completed jobs whose files are still in the downloaded-IPA set.
    var completedDownloadCount: Int
    var completedRetainedBytes: Int64

    /// Partials, isolated rejects, and resume data. Not validated packages.
    var temporaryBytes: Int64
    var temporaryCount: Int

    var totalBytes: Int64 { downloadedIPABytes + temporaryBytes }

    static let empty = DownloadStorageReport(
        downloadedIPABytes: 0,
        downloadedIPACount: 0,
        completedDownloadCount: 0,
        completedRetainedBytes: 0,
        temporaryBytes: 0,
        temporaryCount: 0
    )
}

/// Reserved scheduler fields. Stored so a future release can add scheduling
/// or sync without replacing the snapshot. This build does not execute them.
struct DownloadSchedulingReservation: Equatable, Hashable, Sendable, Codable {
    var maximumConcurrentTransfers: Int?
    var automationLabel: String?
    var syncGeneration: Int?

    static let unused = DownloadSchedulingReservation(
        maximumConcurrentTransfers: nil,
        automationLabel: nil,
        syncGeneration: nil
    )
}

/// One log line on a download job. Fixed language, no paths or credentials.
struct DownloadLogEntry: Equatable, Hashable, Sendable, Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

/// The persisted form of one download job.
///
/// State is a token so a future token this build does not know can be refused
/// at restore time instead of being decoded as success.
struct DownloadJobRecord: Equatable, Hashable, Sendable, Codable {

    var id: String
    var displayName: String
    var bundleIdentifier: String?
    var version: String?
    var build: String?
    var sourceName: String
    var sourceKind: String
    var sourceIdentifier: String?
    var remoteURL: String
    var iconURL: String?
    var expectedSHA256: String?
    var expectedByteCount: Int64?
    var releaseNotes: String?
    var releaseDate: String?
    var versionHistory: [DownloadVersionNote]
    var priority: String
    var state: String
    var stage: String
    var failureSummary: String?
    var failureDetail: String?
    var failureRetryable: Bool?
    var failureAt: Date?
    var resumeFact: String
    var receivedBytes: Int64
    var expectedTransferBytes: Int64?
    var enqueuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var attemptCount: Int
    var validation: DownloadArtifactValidation?
    var handoff: String?
    var importJobIDs: [String]
    var replacesJobIDs: [String]
    var duplicateChoice: String?
    var log: [DownloadLogEntry]
}

/// The versioned snapshot the store writes.
struct DownloadCenterSnapshot: Equatable, Sendable, Codable {
    var revision: Int
    var jobs: [DownloadJobRecord]
    var history: [DownloadHistoryEntry]
    var ignoredVersions: [IgnoredAppVersion]
    var announcedUpdates: [IgnoredAppVersion]
    var scheduling: DownloadSchedulingReservation
}

/// The outcome of asking the center to queue a download.
enum DownloadEnqueueResult: Equatable, Sendable {
    case queued(DownloadJobIdentifier)
    case needsDecision(UUID)
    case rejected(String)
    case skipped
}
