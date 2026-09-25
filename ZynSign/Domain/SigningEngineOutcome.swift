import Foundation

/// How one signing stage finished.
enum SigningEngineStageStatus: String, CaseIterable, Hashable, Sendable {

    /// The stage did its work and it completed.
    case succeeded

    /// The stage had no work to do — an empty nested kind, for example.
    case skipped

    /// The stage refused the run or failed. The run stopped there.
    case failed
}

/// What one signing stage produced, structurally.
///
/// Every stage returns one of these: the coordinator never continues on a
/// stage whose outcome is anything other than a success, and a failure is a
/// typed value rather than a thrown string.
struct SigningEngineStageOutcome: Equatable, Sendable {

    /// The stage this outcome belongs to.
    let stage: SigningEngineStage

    /// How the stage finished.
    let status: SigningEngineStageStatus

    /// What the stage established, in bounded diagnostic language.
    let detail: String

    /// The stage's countable results, when it has any.
    let metrics: SigningEngineStageMetrics

    /// How long the stage took, in seconds.
    let duration: TimeInterval
}

/// The countable results one stage produced. Every field is optional because
/// a stage reports only the counts it actually established; nothing is
/// inferred to fill a blank.
struct SigningEngineStageMetrics: Equatable, Sendable {

    /// Container entries involved in the stage.
    var entryCount: Int? = nil

    /// Nested targets the stage signed.
    var nestedTargetCount: Int? = nil

    /// Binaries the stage signed, including the main executable.
    var signedBinaryCount: Int? = nil

    /// Resources the sealing step sealed by content.
    var sealedResourceCount: Int? = nil

    /// Verification checks the stage ran.
    var verificationCheckCount: Int? = nil

    /// Verification checks that passed.
    var verificationPassedCount: Int? = nil

    /// The packaged container's size in bytes.
    var containerByteCount: Int? = nil

    /// The main executable's cryptographic signature size in bytes.
    var signatureByteCount: Int? = nil

    init(
        entryCount: Int? = nil,
        nestedTargetCount: Int? = nil,
        signedBinaryCount: Int? = nil,
        sealedResourceCount: Int? = nil,
        verificationCheckCount: Int? = nil,
        verificationPassedCount: Int? = nil,
        containerByteCount: Int? = nil,
        signatureByteCount: Int? = nil
    ) {
        self.entryCount = entryCount
        self.nestedTargetCount = nestedTargetCount
        self.signedBinaryCount = signedBinaryCount
        self.sealedResourceCount = sealedResourceCount
        self.verificationCheckCount = verificationCheckCount
        self.verificationPassedCount = verificationPassedCount
        self.containerByteCount = containerByteCount
        self.signatureByteCount = signatureByteCount
    }

    /// An empty metric set, for stages that establish no counts of their own.
    static let none = SigningEngineStageMetrics()
}

/// The run's summary: what the delivered container is and what the run did to
/// produce it.
struct SigningEngineSummary: Equatable, Sendable {

    /// The bundle's name inside the container.
    let bundleName: String

    /// The bundle's declared identifier.
    let bundleIdentifier: String

    /// The bundle's declared executable name.
    let executableName: String

    /// The container's entry count.
    let entryCount: Int

    /// The number of nested targets the run signed.
    let nestedTargetCount: Int

    /// The number of binaries the run signed: nested targets plus the main
    /// executable.
    let signedBinaryCount: Int

    /// The number of resources sealed by content.
    let sealedResourceCount: Int

    /// The packaged container's size in bytes.
    let containerByteCount: Int

    /// The number of independent verification checks that ran, and how many
    /// passed.
    let verificationCheckCount: Int
    let verificationPassedCount: Int

    /// How long the whole run took.
    let duration: TimeInterval

    /// Whether every independent verification check passed.
    var verificationPassed: Bool {
        verificationCheckCount > 0 && verificationCheckCount == verificationPassedCount
    }
}

/// Why one signing run failed, with the recovery facts attached.
struct SigningEngineFailure: Error, Equatable, Sendable {

    /// The stage that refused the run or failed.
    let stage: SigningEngineStage

    /// What went wrong, in fixed diagnostic language. Bundle-relative
    /// locations may be named; identities, keys, and profile content never
    /// are.
    let detail: String

    /// The failure's category — the stable, programmatically usable part.
    let category: DiagnosticCategory

    /// A user-presentable explanation, free of technical detail.
    let userMessage: String

    /// Whether the original container was re-checked after the failure and
    /// found byte-identical to what the run read.
    let originalUnchanged: Bool

    /// Whether the run's working copy was discarded.
    let workingCopyDiscarded: Bool

    /// Whether the run removed everything it wrote, so no partial artifact
    /// remains anywhere.
    let outputRemoved: Bool

    /// Whether the delivery location already held a container when the run
    /// began. A failed run never overwrites what was already there, and says
    /// so rather than leaving the fact to be inferred.
    var outputPreexisted: Bool = false

    /// The stage detail lines the run had produced when it failed, in stage
    /// order. Useful for diagnosis; never key material, profile bytes, or
    /// user data.
    let diagnostics: [String]

    /// Whether re-running with the same inputs could plausibly succeed.
    ///
    /// Input faults — malformed, unsupported, or ambiguous content — are not
    /// retryable: the same inputs would fail the same way. Unavailable
    /// capabilities, storage failures, cancellations, and internal conditions
    /// are retryable, because the input was not what refused.
    var isRetryable: Bool {
        switch category {
        case .invalidInput, .unsupportedInput, .ambiguousInput:
            return false
        case .capabilityUnavailable, .cancelled, .storageFailure, .internalFailure:
            return true
        }
    }
}

/// Whether one signing run produced a signed container.
enum SigningEngineStatus: String, Equatable, Sendable {

    /// Every stage passed, the artifact verified independently, and the
    /// container was delivered.
    case signed

    /// A stage refused or failed. Nothing was delivered.
    case failed
}
