import Foundation

/// The signing configuration one operation ran under, recorded for auditing.
///
/// The summary names the choices the run made — how an existing signature was
/// treated, which CodeDirectory version was written, how many entitlement
/// claims were embedded, whether the DER form was emitted — and carries the
/// team identifier when the caller established one. It carries no profile
/// bytes, no key material, no password, and no certificate contents: the same
/// restrictions the diagnostic rendering follows everywhere else.
struct SigningConfigurationSummary: Equatable, Hashable, Codable, Sendable {

    /// How an existing signature was treated, in fixed language.
    let existingSignaturePolicy: String

    /// The CodeDirectory version written, e.g. `0x20400`.
    let codeDirectoryVersion: String

    /// How many entitlement claims were embedded.
    let entitlementCount: Int

    /// Whether the deterministic DER entitlements blob was requested.
    let derEntitlements: Bool

    /// The team identifier recorded in the CodeDirectory, when one was
    /// established. An identifier, never a credential.
    let teamIdentifier: String?

    init(
        existingSignaturePolicy: String,
        codeDirectoryVersion: String,
        entitlementCount: Int,
        derEntitlements: Bool,
        teamIdentifier: String? = nil
    ) {
        self.existingSignaturePolicy = existingSignaturePolicy
        self.codeDirectoryVersion = codeDirectoryVersion
        self.entitlementCount = max(0, entitlementCount)
        self.derEntitlements = derEntitlements
        self.teamIdentifier = teamIdentifier
    }

    /// The one-line rendering the operation details show.
    var summary: String {
        var parts = [
            existingSignaturePolicy,
            "CodeDirectory \(codeDirectoryVersion)",
            "\(entitlementCount) entitlement\(entitlementCount == 1 ? "" : "s")",
        ]
        if derEntitlements { parts.append("DER entitlements") }
        return parts.joined(separator: " · ")
    }
}

/// Why one operation failed, in the form the history keeps.
///
/// The summary is written once, at the failure, from fixed language: a stage,
/// a category, a short explanation in the interface's own voice, and — where
/// the failure carried one — a technical detail that still names no key, no
/// credential, and no absolute path.
struct SigningFailureSummary: Equatable, Hashable, Codable, Sendable {

    /// The stage the operation stopped at.
    let stage: SigningOperationStage

    /// The failure's category, in fixed language.
    let category: String

    /// The short explanation shown first.
    let explanation: String

    /// Technical context, shown behind a disclosure. `nil` when the failure
    /// carried none.
    let technicalDetail: String?

    init(stage: SigningOperationStage, category: String, explanation: String, technicalDetail: String? = nil) {
        self.stage = stage
        self.category = category
        self.explanation = explanation
        self.technicalDetail = technicalDetail
    }
}

/// One past signing operation. The library keeps a bounded, on-device journal
/// of these so users can see what was signed, when, with which identity and
/// profile *identified*, what verification concluded, where the output went,
/// and — when it failed — exactly where it stopped and why.
///
/// The journal is private to the application container and never leaves the
/// device. It holds metadata, not artifacts: signed IPA files live in export
/// storage and are referenced by file name, and a record whose output has been
/// removed remains listed and says so. No record carries a private key, a
/// password, profile bytes, or any other signing material.
///
/// Schema notes: this record grew with export-centre support. Every field
/// added after the first journal schema is optional, so a journal written by
/// an earlier build still decodes; the fields it never knew simply read as
/// absent, and nothing is invented to fill them.
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

        /// Whether the operation delivered output.
        var isSuccess: Bool { self == .succeeded }

        /// The mark the history row shows.
        var displayMark: String {
            switch self {
            case .succeeded: return "✓"
            case .failed: return "✕"
            case .cancelled: return "⊘"
            }
        }
    }

    /// Stable identifier.
    let id: SigningRecordIdentifier

    /// The signing preset used, if any.
    let presetID: PresetIdentifier?

    /// The certificate fingerprint used. Captured even when the signing
    /// failed, so users can see which identity produced a refusal. A
    /// fingerprint identifies a certificate; it is not a trust statement.
    let certificateFingerprint: CertificateFingerprint?

    /// The bundle identifier of the source application. Captured at sign
    /// time so the journal makes sense after the source is removed.
    let sourceBundleIdentifier: String?

    /// The display name of the source application, when available.
    let sourceDisplayName: String?

    /// The library record the operation signed, when it is known. Kept as the
    /// raw identifier so the operation stays readable after the library entry
    /// is removed, and so "retry" can find the application again when it is
    /// still there.
    let sourceRecordIdentifier: String?

    /// The declared marketing version of the source application.
    let shortVersion: String?

    /// The declared build of the source application.
    let buildVersion: String?

    /// The certificate's own display name as the Keychain presents it, e.g.
    /// `Apple Development: A. Example (AB12CD34)`. An identifier for
    /// auditing; never key material.
    let certificateDisplayName: String?

    /// The team identifier the run recorded, when one was established.
    let teamIdentifier: String?

    /// The provisioning profile's declared name, when the run had one. The
    /// profile's bytes are never stored.
    let provisioningProfileName: String?

    /// The configuration the run used.
    let configuration: SigningConfigurationSummary?

    /// The pipeline stage at which the operation stopped (succeeded,
    /// failed, or cancelled). The raw stage name the pipeline reported, kept
    /// for continuity with earlier builds.
    let stoppingStage: String?

    /// The error code returned by the pipeline, when applicable. A code, not
    /// a message: the fixed-language explanation lives in `failure`.
    let errorCode: String?

    /// Why the operation failed, when it did.
    let failure: SigningFailureSummary?

    /// The file name of the produced artifact, as it appears in export
    /// storage. `nil` when no artifact was produced.
    let outputFileName: String?

    /// The byte size of the produced artifact, when known.
    let outputByteCount: Int?

    /// The produced artifact's content fingerprint, when it was measured.
    let outputFingerprint: ExportFingerprint?

    /// The Export Center record that holds the artifact, when one was
    /// committed. `nil` when the run produced no artifact, or the artifact
    /// was produced before export storage existed.
    let exportIdentifier: String?

    /// What independent verification concluded during the run.
    let verificationStatus: ArtifactVerificationStatus?

    /// When that verification ran.
    let verificationRecordedAt: Date?

    /// The verification findings worth keeping: errors, warnings, and
    /// observations verification could not complete. Fixed language; no
    /// secrets.
    let verificationFindings: [String]?

    /// The stage-by-stage account of the operation.
    let timeline: [SigningTimelineEntry]?

    /// The outcome the run reported, when it reported one. `nil` for records
    /// written by builds that derived the outcome instead, and for records
    /// that were cancelled without a reported stage.
    let result: Outcome?

    /// When the signing started.
    let startedAt: Date

    /// How long the signing took. For cancelled records this is the
    /// time spent before cancellation; for failed records, the time to
    /// the failure point.
    let duration: TimeInterval

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
        result: Outcome? = nil,
        sourceRecordIdentifier: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        certificateDisplayName: String? = nil,
        teamIdentifier: String? = nil,
        provisioningProfileName: String? = nil,
        configuration: SigningConfigurationSummary? = nil,
        failure: SigningFailureSummary? = nil,
        outputFingerprint: ExportFingerprint? = nil,
        exportIdentifier: String? = nil,
        verificationStatus: ArtifactVerificationStatus? = nil,
        verificationRecordedAt: Date? = nil,
        verificationFindings: [String]? = nil,
        timeline: [SigningTimelineEntry]? = nil
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
        self.duration = max(0, duration)
        self.result = result
        self.sourceRecordIdentifier = sourceRecordIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.certificateDisplayName = certificateDisplayName
        self.teamIdentifier = teamIdentifier
        self.provisioningProfileName = provisioningProfileName
        self.configuration = configuration
        self.failure = failure
        self.outputFingerprint = outputFingerprint
        self.exportIdentifier = exportIdentifier
        self.verificationStatus = verificationStatus
        self.verificationRecordedAt = verificationRecordedAt
        self.verificationFindings = verificationFindings
        self.timeline = timeline
    }

    /// The outcome of the operation.
    ///
    /// A run that reported its own outcome is taken at its word. Records
    /// written by earlier builds reported no outcome, so one is derived from
    /// what they did capture: output means success, a stopping stage without
    /// output means failure, and neither means the operation was cancelled
    /// before it reached a stage.
    var outcome: Outcome {
        if let result { return result }
        if outputFileName != nil { return .succeeded }
        if stoppingStage == nil { return .cancelled }
        return .failed
    }

    /// The application's name as the history shows it.
    var displayName: String {
        if let sourceDisplayName, !sourceDisplayName.isEmpty { return sourceDisplayName }
        return sourceBundleIdentifier ?? "Unknown Application"
    }

    /// The declared version and build, in the form people read them.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Not recorded"
        }
    }

    /// When the operation finished, when its start and duration establish it.
    var finishedAt: Date { startedAt.addingTimeInterval(duration) }

    /// The stage account of the operation. A record written before timelines
    /// existed reads as an operation whose stages were not recorded.
    var stages: SigningTimeline { SigningTimeline(entries: timeline ?? []) }

    /// The linked Export Center record's identifier, when one is recorded and
    /// still parses.
    var exportID: ExportIdentifier? {
        exportIdentifier.map { ExportIdentifier(rawValue: $0) }
    }

    /// The library record this operation signed, when the stored identifier
    /// still names one.
    var sourceRecordID: ApplicationRecordIdentifier? {
        sourceRecordIdentifier.flatMap { ApplicationRecordIdentifier(rawValue: $0) }
    }

    /// Whether the operation produced an artifact that was committed to
    /// export storage.
    var deliveredArtifact: Bool { outcome == .succeeded && exportIdentifier != nil }

    /// The stage the operation stopped at, in the timeline's vocabulary, when
    /// the record carries a timeline or a failure.
    var stoppedStage: SigningOperationStage? {
        if let failure { return failure.stage }
        if let stage = stages.failedStage { return stage }
        return nil
    }

    /// The line the history row shows under the application name: what
    /// happened, and where.
    var outcomeSummary: String {
        switch outcome {
        case .succeeded:
            return deliveredArtifact ? "Signed successfully" : "Signed"
        case .failed:
            if let stage = stoppedStage { return "Signing failed at \(stage.displayName)" }
            return "Signing failed"
        case .cancelled:
            return "Signing cancelled"
        }
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
