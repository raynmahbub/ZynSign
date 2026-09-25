/// The stages one import moves through, in the order it moves through them.
///
/// The stages are the import pipeline seen from the outside: a selected
/// document is prepared, copied into ZynSign's own working storage, examined
/// structurally, examined for the metadata its application declares, checked
/// against the library, and — when it is accepted — taken into the library.
/// Every stage name states what is happening to *the user's file*, never what
/// it proves about the package: examination establishes structure and
/// declared values, and the last stage stores bytes. Nothing here claims that
/// a package is genuine, signed, or installable.
///
/// Each stage carries a weight, so a determinate overall progress value can
/// be derived from the stage a job is in and how far that stage has come.
/// Copying carries the largest weight because it is the only stage whose cost
/// grows with the size of the file; the examination stages are bounded work
/// and are weighted as such.
enum ImportStage: String, CaseIterable, Hashable, Sendable {

    /// The selected document is being checked before anything is copied:
    /// that it exists, that it carries the accepted extension, and that it
    /// is a non-empty archive container.
    case preparing

    /// The document's bytes are being copied into ZynSign's staging storage.
    /// The original is only ever read.
    case copying

    /// The copied archive's entry table is being read and checked against
    /// the structural rules for an application package.
    case examiningStructure

    /// The information file the package's application declares is being read
    /// and checked within its bound.
    case examiningMetadata

    /// The library is being asked whether it already relates to this
    /// package, and what the user wants done about it when it does.
    case checkingForDuplicates

    /// The accepted package is being taken into the library.
    case storing

    /// The import has produced an outcome. A terminal state; it measures no
    /// work of its own.
    case finished

    /// The stages in pipeline order.
    static var ordered: [ImportStage] { allCases }

    /// The user-presentable name of the stage, phrased as work in progress.
    var displayName: String {
        switch self {
        case .preparing: return "Checking the file"
        case .copying: return "Copying into ZynSign"
        case .examiningStructure: return "Checking the package"
        case .examiningMetadata: return "Reading declared information"
        case .checkingForDuplicates: return "Checking the library"
        case .storing: return "Adding to the library"
        case .finished: return "Finished"
        }
    }

    /// The short name used where space is tight, such as a progress caption.
    var shortName: String {
        switch self {
        case .preparing: return "Checking"
        case .copying: return "Copying"
        case .examiningStructure: return "Inspecting"
        case .examiningMetadata: return "Reading"
        case .checkingForDuplicates: return "Comparing"
        case .storing: return "Storing"
        case .finished: return "Done"
        }
    }

    /// The SF Symbol shown beside the stage.
    var symbolName: String {
        switch self {
        case .preparing: return "doc.text.magnifyingglass"
        case .copying: return "arrow.down.doc"
        case .examiningStructure: return "shippingbox"
        case .examiningMetadata: return "doc.badge.gearshape"
        case .checkingForDuplicates: return "square.on.square"
        case .storing: return "tray.and.arrow.down"
        case .finished: return "checkmark.circle"
        }
    }

    /// The position of this stage in pipeline order, counting from zero.
    var order: Int {
        ImportStage.allCases.firstIndex(of: self) ?? 0
    }

    /// Whether the pipeline has reached this stage: `self` is at or after
    /// `other` in pipeline order.
    func isAtOrAfter(_ other: ImportStage) -> Bool {
        order >= other.order
    }

    // MARK: - Progress weighting

    /// How much of an import's total work this stage represents. The weights
    /// are policy, declared once, and add up to one.
    var weight: Double {
        switch self {
        case .preparing: return 0.02
        case .copying: return 0.50
        case .examiningStructure: return 0.12
        case .examiningMetadata: return 0.08
        case .checkingForDuplicates: return 0.06
        case .storing: return 0.22
        case .finished: return 0
        }
    }

    /// The sum of every stage's weight. Always one, because the weights are
    /// declared to add up; computed rather than assumed so a weight change
    /// cannot silently skew every progress value.
    static var totalWeight: Double {
        allCases.reduce(0) { $0 + $1.weight }
    }

    /// The fraction of the whole import that has completed when this stage
    /// begins.
    var startingFraction: Double {
        let preceding = ImportStage.allCases.prefix(while: { $0 != self })
        return preceding.reduce(0) { $0 + $1.weight } / ImportStage.totalWeight
    }

    /// The fraction of the whole import this stage spans.
    var fractionSpan: Double {
        weight / ImportStage.totalWeight
    }

    /// The overall fraction completed, given how far through `stage` the
    /// import is. Clamped to `0...1` so a stage that reports more work than
    /// it promised cannot produce a bar past its end.
    static func fraction(of stage: ImportStage, stageFraction: Double) -> Double {
        let withinStage = min(max(stageFraction, 0), 1)
        return min(max(stage.startingFraction + stage.fractionSpan * withinStage, 0), 1)
    }
}
