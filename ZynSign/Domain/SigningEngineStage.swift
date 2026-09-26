import Foundation

/// The stages one on-device signing run is executed and presented in.
///
/// The execution order is fixed and dependency-first: the run prepares an
/// isolated working copy, validates the bundle it holds, finalizes every
/// nested binary from the inside out, signs the host application last,
/// verifies the signed result independently, and only then packages the
/// container.
///
/// The enum is the single vocabulary shared by the coordinator that executes
/// the pipeline, the progress tracker that reports it, and the interface that
/// presents it. Adding a stage means adding it here once, with its weight and
/// its title; nothing else enumerates the execution order.
///
/// A stage name states what the stage does, never what it proved: a completed
/// stage means the work finished, not that any trust, authorization, or
/// installability conclusion follows from it.
enum SigningEngineStage: String, CaseIterable, Hashable, Sendable {

    /// The isolated working copy is created and the original container is
    /// fingerprinted so its preservation can be established afterwards.
    case preparing

    /// The working copy's bundle is validated and the source container is
    /// structurally checked before anything is signed.
    case validating

    /// Every framework bundle is signed, inner code first.
    case signingFrameworks

    /// Every bundled dynamic library is signed, inner code first.
    case signingDynamicLibraries

    /// Every application extension (`.appex`) is signed, inner code first.
    case signingExtensions

    /// Every nested application bundle is signed, inner code first.
    case signingNestedApplications

    /// The host application's resources are sealed and its main executable is
    /// signed with the selected identity, entitlements, and embedded profile.
    case signingApplication

    /// The signed artifact is re-read and independently verified. Nothing the
    /// signing stages believed is taken on trust.
    case verifying

    /// The verified bundle is packaged as a deterministic `Payload/` container
    /// and the written container is validated.
    case packaging

    /// The run finished and the container was delivered.
    case complete

    /// The stage's name in the interface and in diagnostics.
    var title: String {
        switch self {
        case .preparing: return "Preparing"
        case .validating: return "Validating"
        case .signingFrameworks: return "Signing Frameworks"
        case .signingDynamicLibraries: return "Signing Dynamic Libraries"
        case .signingExtensions: return "Signing Extensions"
        case .signingNestedApplications: return "Signing Nested Applications"
        case .signingApplication: return "Signing App"
        case .verifying: return "Verifying"
        case .packaging: return "Packaging"
        case .complete: return "Complete"
        }
    }

    /// One line describing what the stage does, shown beneath its name.
    var summary: String {
        switch self {
        case .preparing: return "Creating an isolated working copy — the original stays untouched"
        case .validating: return "Checking structure, information file, executable, and nested bundles"
        case .signingFrameworks: return "Signing framework bundles, inner code first"
        case .signingDynamicLibraries: return "Signing bundled dynamic libraries, inner code first"
        case .signingExtensions: return "Signing application extensions, inner code first"
        case .signingNestedApplications: return "Signing nested applications, inner code first"
        case .signingApplication: return "Sealing resources and signing the main executable"
        case .verifying: return "Re-reading the signed artifact and verifying it independently"
        case .packaging: return "Building the deterministic Payload/ container and validating it"
        case .complete: return "Delivered — the signed container is ready"
        }
    }

    /// The SF Symbol the interface shows beside the stage.
    var systemImageName: String {
        switch self {
        case .preparing: return "shippingbox"
        case .validating: return "checklist"
        case .signingFrameworks: return "square.stack.3d.up"
        case .signingDynamicLibraries: return "shippingbox.and.arrow.backward"
        case .signingExtensions: return "puzzlepiece.extension"
        case .signingNestedApplications: return "square.on.square"
        case .signingApplication: return "signature"
        case .verifying: return "checkmark.shield"
        case .packaging: return "archivebox"
        case .complete: return "checkmark.seal"
        }
    }

    /// The stage's share of the run's total work, used by the progress
    /// tracker's estimate. The weights sum to one across `allCases`, so the
    /// fraction completed is always comparable, whether a run signs twenty
    /// nested targets or none.
    var weight: Double {
        switch self {
        case .preparing: return 0.05
        case .validating: return 0.15
        case .signingFrameworks: return 0.10
        case .signingDynamicLibraries: return 0.05
        case .signingExtensions: return 0.10
        case .signingNestedApplications: return 0.05
        case .signingApplication: return 0.25
        case .verifying: return 0.15
        case .packaging: return 0.10
        case .complete: return 0.0
        }
    }

    /// The nested-code kind this stage signs, for the four nested stages.
    /// `nil` for every other stage.
    var nestedCodeKind: NestedCodeKind? {
        switch self {
        case .signingFrameworks: return .framework
        case .signingDynamicLibraries: return .dynamicLibrary
        case .signingExtensions: return .applicationExtension
        case .signingNestedApplications: return .application
        case .preparing, .validating, .signingApplication, .verifying, .packaging, .complete:
            return nil
        }
    }

    /// Whether the stage signs nested code, one kind at a time.
    var isNestedSigningStage: Bool { nestedCodeKind != nil }

    /// The stage that signs one kind of nested code, when the kind is signed
    /// as nested code at all.
    ///
    /// The root application is not a nested target: `NestedCodeKind.application`
    /// names the host bundle itself, which the last signing stage handles.
    static func nestedSigningStage(for kind: NestedCodeKind) -> SigningEngineStage? {
        switch kind {
        case .framework: return .signingFrameworks
        case .dynamicLibrary: return .signingDynamicLibraries
        case .applicationExtension: return .signingExtensions
        case .application: return .signingNestedApplications
        }
    }

    /// The stage that follows the validating stage once signing begins.
    static var firstSigningStage: SigningEngineStage { .signingFrameworks }
}
