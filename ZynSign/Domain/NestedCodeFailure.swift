import Foundation

/// The stable reason one nested-code discovery rejected an application bundle.
///
/// A reason is safe to expose to application code and to render to a user. It
/// covers the distinctions the discovery pipeline actually decides: the
/// application's own structure, path safety, the shape of a binary, ambiguous
/// executables, the coherence of the dependency graph, unsupported nested
/// structures, and the resource policy. Diagnostic detail passed alongside a
/// reason must stay redacted: bundle-relative locations, counts, and
/// structural facts are acceptable; bytes, file contents, key material,
/// credentials, profile bodies, device identifiers, and foreign error text
/// are not.
enum NestedCodeFailure: String, CaseIterable, Hashable {

    /// The managed application bundle's own structure is not usable: its
    /// declared executable is absent, is not a regular file at the bundle
    /// root, or could not be read.
    case invalidApplicationBundle

    /// A located path cannot be expressed as a location inside the managed
    /// bundle, or an item's executable is not inside its own container. A
    /// location that would leave the bundle is not representable, so reaching
    /// this reason means the structure itself contradicts the model.
    case invalidPath

    /// A symbolic link or an unmodelled entry form sits where code would be
    /// expected — the application's executable, a code bundle, or a file
    /// inside a supported code directory. The target was not read and was
    /// never followed; discovery refuses the bundle rather than planning
    /// around content it cannot establish.
    case pathSafetyViolation

    /// The bytes at a location discovery must establish as code are not a
    /// Mach-O image in any recognized form.
    case notMachO

    /// The bytes begin like a Mach-O image but are structurally unusable.
    case malformedMachO

    /// The bytes are a recognized Mach-O form this build does not model.
    case unsupportedMachO

    /// A container records more than one plausible executable and neither a
    /// declaration nor the bundle-name convention chooses between them.
    case ambiguousExecutable

    /// The dependency graph would contain the same item twice.
    case duplicateItem

    /// Two items in the dependency graph name the same executable location.
    case duplicateExecutablePath

    /// An item's dependency names the item itself, which no valid signing
    /// order can satisfy.
    case selfDependency

    /// The dependency graph contains a cycle. Discovery refuses to resolve it
    /// by falling back on an arbitrary order, because any order for a cyclic
    /// graph would place one component after something that must precede it.
    case dependencyCycle

    /// A dependency names an item the graph does not contain.
    case missingDependency

    /// The application contains nested code in a form this build deliberately
    /// does not traverse — a nested application bundle, an extension or
    /// framework bundle outside its supported location, or a code bundle of a
    /// kind whose signing semantics are not established here.
    case unsupportedNestedCode

    /// Two bundles inside the managed application declare the same bundle
    /// identifier, so the plan's declaration record contradicts itself.
    case conflictingBundleIdentifier

    /// The bundle describes more items, deeper nesting, more directories, or
    /// more content than the discovery resource policy accepts.
    case resourceLimitExceeded

    /// The diagnostic category this reason belongs to.
    ///
    /// Unsupported forms and the resource policy report unsupported input;
    /// an ambiguous executable reports ambiguity; everything else reports
    /// invalid input. No reason is reported as an internal failure, because
    /// every one of them describes the application bundle rather than a
    /// defect in ZynSign.
    var category: DiagnosticCategory {
        switch self {
        case .unsupportedMachO, .unsupportedNestedCode, .resourceLimitExceeded:
            return .unsupportedInput
        case .ambiguousExecutable:
            return .ambiguousInput
        default:
            return .invalidInput
        }
    }

    /// A user-presentable explanation, free of technical and sensitive detail.
    var userMessage: String {
        switch self {
        case .invalidApplicationBundle:
            return "ZynSign could not establish the application's own executable."
        case .invalidPath:
            return "The application contains a location ZynSign cannot express safely."
        case .pathSafetyViolation:
            return "The application contains a link or an entry form where ZynSign expected code, so it cannot plan a signing order."
        case .notMachO:
            return "A file ZynSign must inspect is not an executable file it can read."
        case .malformedMachO:
            return "An executable file ZynSign must inspect is damaged."
        case .unsupportedMachO:
            return "An executable file uses a form ZynSign does not support."
        case .ambiguousExecutable:
            return "A bundle records more than one possible executable, so ZynSign cannot choose between them."
        case .duplicateItem:
            return "The signing plan would contain the same component twice."
        case .duplicateExecutablePath:
            return "Two components in the signing plan name the same executable."
        case .selfDependency:
            return "A component in the signing plan depends on itself."
        case .dependencyCycle:
            return "The signing plan's dependencies form a cycle, so ZynSign cannot establish an order."
        case .missingDependency:
            return "The signing plan refers to a component it does not contain."
        case .unsupportedNestedCode:
            return "The application contains nested code in a form ZynSign does not support."
        case .conflictingBundleIdentifier:
            return "Two bundles in the application declare the same bundle identifier."
        case .resourceLimitExceeded:
            return "The application's nested code is larger or more complex than ZynSign will inspect."
        }
    }

    /// A short, log-safe summary for diagnostics.
    var displayName: String { rawValue }
}

/// One structured nested-code discovery failure.
///
/// The failure carries the stable reason, the bundle-relative location it
/// concerns when it concerns one, and technical detail written for logs and
/// reports. It carries no bytes, no absolute path, no archive location, and no
/// foreign error text; `detail` stays subject to the redaction rules. The
/// reason is what callers switch on, and it is the only part of the failure
/// that may be promoted into user-facing text — through
/// `NestedCodeFailure.userMessage`.
struct NestedCodeDiscoveryError: Error, Equatable {

    let reason: NestedCodeFailure

    /// The bundle-relative location the failure concerns, when it concerns
    /// exactly one. `nil` means the failure concerns the bundle as a whole.
    let path: BundlePath?

    /// Technical diagnostic context: structural facts and bundle-relative
    /// locations only.
    let detail: String

    init(_ reason: NestedCodeFailure, at path: BundlePath? = nil, detail: String) {
        self.reason = reason
        self.path = path
        self.detail = detail
    }

    /// A one-line, log-safe rendering. It names the reason and the location
    /// and omits the detail, matching the short rendering of `ZynSignError`.
    var description: String {
        if let path {
            return "zynsign.nestedCode(\(reason.rawValue)): \(path.rawValue)"
        }
        return "zynsign.nestedCode(\(reason.rawValue))"
    }
}
