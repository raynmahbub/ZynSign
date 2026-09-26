/// The stage an item in the Import Hub's queue is at, in the vocabulary the
/// queue shows: Waiting, Preparing, Validating, Analyzing, Importing,
/// Complete, Failed.
///
/// The pipeline itself reports finer `ImportStage`s; this is the user-facing
/// grouping of them. An item moves forward through the track and ends in
/// exactly one of the two terminal stages. An item that was cancelled or
/// skipped ends in `complete` — nothing more will happen to it — and its own
/// status line says which.
enum ImportQueueStage: String, CaseIterable, Hashable, Sendable {

    /// Queued, not yet started, or confirmed and waiting its turn to be
    /// stored.
    case waiting

    /// Checking the file and making ZynSign's own working copy of it.
    case preparing

    /// Checking that the working copy is a readable, safe package.
    case validating

    /// Reading the application's icon, identity, and contents, and
    /// comparing it with the library.
    case analyzing

    /// Storing the application in the library.
    case importing

    /// Finished: nothing more will happen to the item.
    case complete

    /// Finished without importing, for a reason the item explains.
    case failed

    /// The stages a successful import passes through, in order.
    static let track: [ImportQueueStage] = [.waiting, .preparing, .validating, .analyzing, .importing, .complete]

    /// The label shown for the stage.
    var displayName: String {
        switch self {
        case .waiting: return "Waiting"
        case .preparing: return "Preparing"
        case .validating: return "Validating"
        case .analyzing: return "Analyzing"
        case .importing: return "Importing"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }

    /// The SF Symbol shown for the stage.
    var symbolName: String {
        switch self {
        case .waiting: return "clock"
        case .preparing: return "doc.on.doc"
        case .validating: return "checkmark.shield"
        case .analyzing: return "sparkle.magnifyingglass"
        case .importing: return "tray.and.arrow.down"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Whether the stage is one an item ends in.
    var isTerminal: Bool {
        self == .complete || self == .failed
    }

    /// The number of track stages that still follow this one before the
    /// item is complete. Terminal stages have none left.
    var remainingStepCount: Int {
        guard !isTerminal, let index = Self.track.firstIndex(of: self) else { return 0 }
        // The final track stage, `complete`, is an outcome rather than a
        // step of work.
        return max(0, Self.track.count - 2 - index)
    }

    /// The queue stage a pipeline stage belongs to.
    static func stage(for pipelineStage: ImportStage) -> ImportQueueStage {
        switch pipelineStage {
        case .preparing, .copying: return .preparing
        case .examiningStructure: return .validating
        case .examiningMetadata, .checkingForDuplicates: return .analyzing
        case .storing: return .importing
        case .finished: return .complete
        }
    }
}
