import Foundation

/// The stable identity of one exported artifact within ZynSign.
///
/// An export identifier names one delivery of signed output — the artifact a
/// signing run produced and ZynSign kept — not the library record it came
/// from and not the bytes it holds. It is opaque, minted by ZynSign, and
/// never derived from application metadata, so nothing inside a package can
/// influence where its signed output is kept.
struct ExportIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {

    /// The underlying uniqueness value.
    let rawValue: String

    /// Mints a fresh identifier for a newly exported artifact.
    init() { self.rawValue = UUID().uuidString }

    /// Reuses a persisted identifier.
    init(rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }
}

/// What export storage reports about one record's artifact when asked to look
/// for it: whether a file is held under the record's own file name and, if
/// so, how large it is. An observation is a fact about storage; it is
/// compared against what the record captured when the artifact was exported
/// to produce an `ExportAvailability`.
enum StoredExportObservation: Equatable, Hashable, Sendable {

    /// A regular file is held, with the observed size in bytes.
    case present(byteCount: Int)

    /// Nothing is held.
    case absent
}

/// Whether an export record's artifact is where the record says it is.
///
/// Availability is derived every time it is asked for. It is never persisted,
/// and a record whose artifact is missing stays listed with its metadata
/// intact: the Export Center marks it unavailable, refuses to offer an export
/// action it cannot honour, and leaves the signing history beside it alone.
/// Nothing is silently recreated, and a missing artifact is never reported as
/// available.
enum ExportAvailability: Equatable, Hashable, Sendable {

    /// The artifact is held and its size matches the record.
    case available

    /// Nothing is held under the record's file name.
    case missing

    /// A file is held, but its size differs from the size recorded when the
    /// export was committed. The bytes were replaced, truncated, or damaged
    /// behind the record's back.
    case inconsistent(recordedByteCount: Int, observedByteCount: Int)

    /// Whether the artifact can be relied on to be the recorded bytes.
    var isAvailable: Bool { self == .available }

    /// The state a row shows for this availability.
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Unavailable"
        case .inconsistent: return "Changed"
        }
    }

    /// What the state means, in fixed language.
    var explanation: String {
        switch self {
        case .available:
            return "The signed artifact is in ZynSign's export storage."
        case .missing:
            return "No file is held under this artifact's name. It may have been moved, deleted from the Files app, or removed by restoring a backup. The record stays so the operation remains readable."
        case .inconsistent(let recorded, let observed):
            let recordedText = ByteCountFormatter.string(fromByteCount: Int64(recorded), countStyle: .file)
            let observedText = ByteCountFormatter.string(fromByteCount: Int64(observed), countStyle: .file)
            return "A file is held under this artifact's name, but it is \(observedText) rather than the \(recordedText) that was exported. The bytes were replaced, truncated, or damaged after the export, so ZynSign will not present them as this artifact."
        }
    }

    /// Whether the user can act on the artifact: sharing, verifying, and
    /// revealing in Files all need the recorded bytes.
    var permitsArtifactActions: Bool { isAvailable }

    /// Derives availability from a storage observation and the byte count the
    /// record captured at export time.
    static func derive(from observation: StoredExportObservation, recordedByteCount: Int) -> ExportAvailability {
        switch observation {
        case .absent:
            return .missing
        case .present(let byteCount):
            return byteCount == recordedByteCount
                ? .available
                : .inconsistent(recordedByteCount: recordedByteCount, observedByteCount: byteCount)
        }
    }
}

/// A content fingerprint of one exported artifact, in the persisted form.
///
/// The domain's `ArtifactFingerprint` is not `Codable` — it is a value type
/// owned by the artifact lifecycle — so the export catalog records the same
/// fact as two primitives: the algorithm's name and the lowercase digest
/// text. The conversion is checked in both directions, so a catalog entry
/// whose algorithm or digest length does not hold is refused at read time
/// rather than presented as a fingerprint.
///
/// A fingerprint identifies bytes. It is not a signature, not a trust
/// statement, and not evidence that the artifact is genuine or installable.
struct ExportFingerprint: Equatable, Hashable, Codable, Sendable {

    /// The digest algorithm's name, e.g. `sha256`.
    let algorithm: String

    /// The digest as lowercase hexadecimal text.
    let hexDigest: String

    /// Records a domain fingerprint in the persisted form.
    init(_ fingerprint: ArtifactFingerprint) {
        self.algorithm = fingerprint.algorithm.rawValue
        self.hexDigest = fingerprint.hexDigest
    }

    /// Rehydrates a persisted fingerprint, or returns `nil` when the
    /// algorithm is unknown or the digest is not a complete digest for it.
    init?(algorithm: String, hexDigest: String) {
        guard let known = ArtifactFingerprint.Algorithm(rawValue: algorithm),
              let fingerprint = ArtifactFingerprint(algorithm: known, hexDigest: hexDigest) else {
            return nil
        }
        self.algorithm = fingerprint.algorithm.rawValue
        self.hexDigest = fingerprint.hexDigest
    }

    /// The domain fingerprint this value records, when it still parses.
    var fingerprint: ArtifactFingerprint? {
        guard let known = ArtifactFingerprint.Algorithm(rawValue: algorithm) else { return nil }
        return ArtifactFingerprint(algorithm: known, hexDigest: hexDigest)
    }

    /// The canonical rendering, `algorithm:digest`.
    var displayString: String { "\(algorithm):\(hexDigest)" }
}

/// One exported artifact: the durable record of signed output ZynSign
/// produced and kept for the user.
///
/// An export record holds metadata and one file name. It does not hold bytes,
/// paths, signing material, or credentials: the artifact lives in export
/// storage and is reached through the export store by identifier, and the
/// record's `fileName` is the predictable name the artifact was given — never
/// a location. The record is evidence that a signing run delivered output,
/// and nothing about trust: it says which application was signed, when, with
/// which certificate and profile *identified* (never reproduced), what
/// independent verification concluded, and whether the user has since shared
/// it out.
///
/// The record deliberately survives the deletion of the library entry it came
/// from, and deletion of the record never touches the library's own artifact.
struct ExportRecord: Equatable, Hashable, Identifiable, Codable, Sendable {

    /// The export's own stable identity.
    let id: ExportIdentifier

    /// The library record the artifact was signed from, when it is still
    /// known. Stored as its raw identifier so the export can be listed even
    /// after the library entry is removed.
    let sourceRecordIdentifier: String?

    /// The library artifact the source bytes came from, when known.
    let sourceArtifactIdentifier: String?

    /// The application's declared display name at export time, when it had
    /// one. Captured, not re-derived: the export must stay readable after the
    /// source is gone.
    let applicationName: String?

    /// The signed application's bundle identifier, as declared.
    let bundleIdentifier: String

    /// The declared marketing version, when the bundle declared one.
    let shortVersion: String?

    /// The declared build version, when the bundle declared one.
    let buildVersion: String?

    /// The file name the artifact was given in export storage: a predictable
    /// name derived from the application's declarations, never a path and
    /// never derived from a user-selected document's name.
    let fileName: String

    /// The artifact's size in bytes, measured when the export was committed.
    let byteCount: Int

    /// The artifact's content fingerprint, measured when the export was
    /// committed. `nil` only for records written before a fingerprint could
    /// be measured; presentation then says "not recorded" rather than
    /// inventing one.
    let fingerprint: ExportFingerprint?

    /// When the artifact was committed to export storage.
    let createdAt: Date

    /// The outcome of the signing run that produced the artifact. Exports are
    /// only created for delivered output, so this is `.succeeded` for every
    /// record this build writes; it is recorded rather than assumed so a
    /// future path cannot present an export as something it was not.
    let signingOutcome: SigningRecord.Outcome

    /// What independent verification last concluded about the artifact.
    let verificationStatus: ArtifactVerificationStatus

    /// When verification last ran, when it has.
    let verificationRecordedAt: Date?

    /// The findings worth keeping from the last verification: errors,
    /// warnings, and the observations verification could not complete, each
    /// already in fixed language. Passing observations are not stored —
    /// "this check passed" is what the status already says. `nil` for a
    /// record written before verification ran.
    let verificationFindings: [String]?

    /// How many checks the last verification ran, when it ran.
    let verificationChecksRun: Int?

    /// When the user last shared, saved, or opened the artifact out of
    /// ZynSign. `nil` means the artifact has been kept but never delivered —
    /// the honest reading of "not exported yet".
    let deliveredAt: Date?

    init(
        id: ExportIdentifier = ExportIdentifier(),
        sourceRecordIdentifier: String?,
        sourceArtifactIdentifier: String?,
        applicationName: String?,
        bundleIdentifier: String,
        shortVersion: String?,
        buildVersion: String?,
        fileName: String,
        byteCount: Int,
        fingerprint: ExportFingerprint?,
        createdAt: Date,
        signingOutcome: SigningRecord.Outcome = .succeeded,
        verificationStatus: ArtifactVerificationStatus = .unsupported,
        verificationRecordedAt: Date? = nil,
        verificationFindings: [String]? = nil,
        verificationChecksRun: Int? = nil,
        deliveredAt: Date? = nil
    ) {
        self.id = id
        self.sourceRecordIdentifier = sourceRecordIdentifier
        self.sourceArtifactIdentifier = sourceArtifactIdentifier
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.fileName = fileName
        self.byteCount = max(0, byteCount)
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.signingOutcome = signingOutcome
        self.verificationStatus = verificationStatus
        self.verificationRecordedAt = verificationRecordedAt
        self.verificationFindings = verificationFindings
        self.verificationChecksRun = verificationChecksRun
        self.deliveredAt = deliveredAt
    }

    /// The library record this export came from, when the stored identifier
    /// still names one.
    var sourceRecordID: ApplicationRecordIdentifier? {
        sourceRecordIdentifier.flatMap { ApplicationRecordIdentifier(rawValue: $0) }
    }

    /// The library artifact the source bytes came from, when the stored
    /// identifier still names one.
    var sourceArtifactID: ArtifactIdentifier? {
        sourceArtifactIdentifier.flatMap { ArtifactIdentifier(rawValue: $0) }
    }

    /// The name a row shows: the declared display name, otherwise the bundle
    /// identifier. Never invented, never empty.
    var displayName: String {
        if let applicationName, !applicationName.isEmpty { return applicationName }
        return bundleIdentifier
    }

    /// The declared version and build in the form people read them, with the
    /// missing parts simply absent.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Not declared"
        }
    }

    /// Whether the artifact has ever been shared, saved, or opened out of
    /// ZynSign.
    var hasBeenDelivered: Bool { deliveredAt != nil }

    /// A short reference for the artifact, suitable for copying: the
    /// predictable file name, which is how the artifact is named everywhere
    /// it appears. It contains no location and no credential.
    var reference: String { fileName }

    /// A copy of this record with verification's outcome recorded.
    ///
    /// The findings kept are the ones that bear on the conclusion — errors,
    /// warnings, and the observations verification could not complete — so a
    /// re-verification months later leaves the same detail available as one
    /// run moments ago.
    func recordingVerification(_ report: ArtifactVerificationReport) -> ExportRecord {
        ExportRecord(
            id: id,
            sourceRecordIdentifier: sourceRecordIdentifier,
            sourceArtifactIdentifier: sourceArtifactIdentifier,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            fileName: fileName,
            byteCount: byteCount,
            fingerprint: fingerprint,
            createdAt: createdAt,
            signingOutcome: signingOutcome,
            verificationStatus: report.status,
            verificationRecordedAt: report.verifiedAt,
            verificationFindings: report.recordedFindings,
            verificationChecksRun: report.checksRun,
            deliveredAt: deliveredAt
        )
    }

    /// A copy of this record with the delivery time recorded.
    func recordingDelivery(at date: Date) -> ExportRecord {
        ExportRecord(
            id: id,
            sourceRecordIdentifier: sourceRecordIdentifier,
            sourceArtifactIdentifier: sourceArtifactIdentifier,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            fileName: fileName,
            byteCount: byteCount,
            fingerprint: fingerprint,
            createdAt: createdAt,
            signingOutcome: signingOutcome,
            verificationStatus: verificationStatus,
            verificationRecordedAt: verificationRecordedAt,
            verificationFindings: verificationFindings,
            verificationChecksRun: verificationChecksRun,
            deliveredAt: date
        )
    }
}

/// One export record together with the current state of its artifact, and
/// where the artifact is.
///
/// The record is what persistence holds; availability is derived from export
/// storage each time an entry is produced, and the file URL is the one
/// location the presentation layer may hand to the system share sheet. The
/// URL is present exactly when the artifact is available, so a view cannot
/// offer an action it cannot honour.
struct ExportEntry: Equatable, Hashable, Identifiable, Sendable {

    /// The persisted record.
    let record: ExportRecord

    /// Whether the artifact is where the record says it is, as observed when
    /// the entry was produced.
    let availability: ExportAvailability

    /// The artifact's current location, when it is held.
    let fileURL: URL?

    var id: ExportIdentifier { record.id }

    /// Whether the artifact can be relied on to be the recorded bytes.
    var isAvailable: Bool { availability.isAvailable }

    /// Whether the presentation layer may offer share, verify, and reveal
    /// actions for this entry.
    var permitsArtifactActions: Bool { availability.permitsArtifactActions && fileURL != nil }
}
