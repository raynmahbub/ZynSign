import Foundation

/// One past signing operation. The library keeps a bounded, on-device
/// journal of these so users can see what was signed, when, with what
/// certificate, and where the output IPA went.
///
/// The journal is private to the application container and never leaves
/// the device. It holds metadata, not artifacts: the signed IPAs live
/// in `Documents/Signed` and are referenced by file name. A record whose
/// output file has been removed by the user remains listed as "missing".
struct SigningRecord: Equatable, Hashable, Identifiable, Sendable, Codable {

    /// What happened when the signing pipeline ran.
    enum Outcome: String, Equatable, Hashable, Codable, Sendable, CaseIterable {
        case succeeded
        case failed
        case cancelled

        var displayName: String {
            switch self {
            case .succeeded: return "Succeeded"
            case .failed:    return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    /// Stable identifier.
    let id: SigningRecordIdentifier

    /// The signing preset used, if any.
    let presetID: PresetIdentifier?

    /// The certificate fingerprint used. Captured even when the signing
    /// failed, so users can see which identity produced a refusal.
    let certificateFingerprint: CertificateFingerprint?

    /// The bundle identifier of the source application. Captured at sign
    /// time so the journal makes sense after the source is removed.
    let sourceBundleIdentifier: String?

    /// The display name of the source application, when available.
    let sourceDisplayName: String?

    /// The pipeline stage at which the operation stopped (succeeded,
    /// failed, or cancelled). When `outcome == .succeeded` the value is
    /// `verification` — the final stage.
    let stoppingStage: String?

    /// The error code returned by the pipeline, when applicable.
    let errorCode: String?

    /// The full path of the produced IPA, relative to the user's
    /// `Documents/Signed` directory. `nil` when no IPA was produced.
    let outputFileName: String?

    /// The byte size of the produced IPA, when known.
    let outputByteCount: Int?

    /// When the signing started.
    let startedAt: Date

    /// How long the signing took. For cancelled records this is the
    /// time spent before cancellation; for failed records, the time to
    /// the failure point.
    let duration: TimeInterval

    /// The identifier of the library record that was signed, in its
    /// canonical string form. Lets the library attribute a signing to the
    /// exact entry rather than to every entry sharing a bundle identifier.
    /// `nil` in journal entries written before the field existed, and for
    /// signings that did not start from a library record.
    let sourceRecordID: String?

    /// When the provisioning profile the signing used expires, as the
    /// profile declared it. `nil` when unknown. Lets the library warn
    /// before a signed output stops launching.
    let profileExpiresAt: Date?

    /// When the signing certificate stops being valid (its notAfter date).
    /// `nil` when unknown.
    let certificateExpiresAt: Date?

    init(
        id: SigningRecordIdentifier = SigningRecordIdentifier(),
        presetID: PresetIdentifier?,
        certificateFingerprint: CertificateFingerprint?,
        sourceBundleIdentifier: String?,
        sourceDisplayName: String?,
        stoppingStage: String?,
        errorCode: String?,
        outputFileName: String?,
        outputByteCount: Int?,
        startedAt: Date,
        duration: TimeInterval,
        sourceRecordID: String? = nil,
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil
    ) {
        self.id = id
        self.presetID = presetID
        self.certificateFingerprint = certificateFingerprint
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceDisplayName = sourceDisplayName
        self.stoppingStage = stoppingStage
        self.errorCode = errorCode
        self.outputFileName = outputFileName
        self.outputByteCount = outputByteCount
        self.startedAt = startedAt
        self.duration = duration
        self.sourceRecordID = sourceRecordID
        self.profileExpiresAt = profileExpiresAt
        self.certificateExpiresAt = certificateExpiresAt
    }

    /// The outcome derived from the captured fields.
    var outcome: Outcome {
        if outputFileName != nil { return .succeeded }
        if stoppingStage == nil { return .cancelled }
        return .failed
    }

    /// Sort: most recent first.
    static func sortByRecency(_ lhs: SigningRecord, _ rhs: SigningRecord) -> Bool {
        lhs.startedAt > rhs.startedAt
    }
}

/// A signing journal entry identifier — opaque and stable.
struct SigningRecordIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    init() { self.rawValue = UUID().uuidString }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
