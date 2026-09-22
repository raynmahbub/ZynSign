/// The workflow stages ZynSign is organised around, in pipeline order.
///
/// The stage set and its order follow the architecture. Listing a stage here
/// describes the product's shape only: no stage is implemented in the
/// foundation build, and stages remain independently exposed capabilities with
/// separate boundaries, security models, and failure domains.
enum WorkflowStage: String, CaseIterable, Hashable {
    case inspection
    case signing
    case verification
    case packaging
    case installation

    /// A human-readable stage name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .inspection: return "Inspection"
        case .signing: return "Signing"
        case .verification: return "Verification"
        case .packaging: return "Packaging"
        case .installation: return "Installation"
        }
    }
}
