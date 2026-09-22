/// The machine-readable identity of one structural validation finding.
///
/// Codes are the stable, programmatically usable part of a finding:
/// presentation and diagnostics switch on the code first, then read the
/// finding's technical detail. The set covers structural examination only —
/// archive readability, path safety, bundle presence, and basic metadata
/// shape. Cryptographic and platform evaluations will carry their own finding
/// vocabularies when those stages exist; they are not extensions of this
/// enumeration.
enum ValidationIssueCode: String, CaseIterable, Hashable {

    /// The container could not be read as an archive.
    case unreadableArchive

    /// An entry path is absolute, escaping, or otherwise unsafe.
    case unsafePath

    /// Two entries claim the same path or colliding paths.
    case conflictingPaths

    /// The expected top-level payload directory is absent.
    case missingPayloadDirectory

    /// No application bundle could be discovered.
    case missingApplicationBundle

    /// More than one application bundle candidate was found, so no single
    /// bundle can be safely chosen.
    case multipleApplicationBundles

    /// A discovered bundle has no readable bundle information file.
    case missingInfoPlist

    /// A bundle information file could not be parsed.
    case unreadableInfoPlist

    /// Required metadata has an unacceptable type or value.
    case malformedMetadata

    /// Declared metadata values contradict each other or the archive layout.
    case inconsistentMetadata

    /// The declared executable is absent or not a readable regular file.
    case missingExecutable

    /// The input is structurally coherent but uses a container feature
    /// outside deliberately supported capability.
    case unsupportedArchiveFeature

    /// The diagnostic category this issue belongs to. Ambiguity and
    /// unsupported input keep their honest categories; every other
    /// structural issue reports invalid input.
    var category: DiagnosticCategory {
        switch self {
        case .multipleApplicationBundles:
            return .ambiguousInput
        case .unsupportedArchiveFeature:
            return .unsupportedInput
        default:
            return .invalidInput
        }
    }
}
