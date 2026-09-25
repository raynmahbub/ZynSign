import Foundation

/// The bundle checks the signing engine runs before it signs anything.
///
/// Every identifier is a fixed part of the validation vocabulary rather than
/// free-form text, so a refusal names the check that refused in a way tests,
/// diagnostics, and the interface can all switch on.
enum BundleValidationCheckIdentifier: String, CaseIterable, Hashable, Sendable {

    /// The container carries a `Payload/` layout with exactly one application
    /// bundle, and the application bundle name is a bundle name.
    case payloadStructure

    /// The bundle's information file is present, readable, and declares the
    /// application's identifier and executable.
    case informationFile

    /// The declared executable exists at the declared location and is a
    /// readable Mach-O image this build can sign.
    case executableFile

    /// The files the application bundle must carry — the information file and
    /// the declared executable — are present exactly once, with the kinds the
    /// layout requires.
    case requiredFiles

    /// Every nested bundle's information file and executable could be read,
    /// so nested signing will not discover an unreadable container later.
    case nestedBundles

    /// The container uses only layouts this build signs. Existing signatures,
    /// universal binaries, and unsupported code kinds are detected here,
    /// before any signing work begins.
    case supportedLayout

    /// The check's name in the interface.
    var title: String {
        switch self {
        case .payloadStructure: return "Payload structure"
        case .informationFile: return "Information file"
        case .executableFile: return "Executable"
        case .requiredFiles: return "Required files"
        case .nestedBundles: return "Nested bundles"
        case .supportedLayout: return "Supported layout"
        }
    }
}

/// One validation check's outcome.
struct BundleValidationCheck: Equatable, Sendable {

    /// Which check ran.
    let identifier: BundleValidationCheckIdentifier

    /// Whether the check passed.
    let passed: Bool

    /// What the check established, in bounded diagnostic language.
    /// Bundle-relative locations may be named; identities, keys, and profile
    /// content never are.
    let detail: String

    /// The check's title.
    var title: String { identifier.title }
}

/// What bundle validation established about one container.
///
/// The report is a fact collection, not a verdict on the application: a valid
/// report means the bundle is structurally signable by this build, and says
/// nothing about trust, provisioning authorization, or installability.
struct BundleValidationReport: Equatable, Sendable {

    /// The checks, in the fixed order they ran.
    let checks: [BundleValidationCheck]

    /// The bundle's location inside the container, when structure established
    /// one.
    let bundlePath: ArchivePath?

    /// The number of nested code targets the container holds, when discovery
    /// established them.
    let nestedTargetCount: Int

    /// Whether every check passed.
    var isAccepted: Bool { checks.allSatisfy(\.passed) }

    /// The first failing check, in run order. `nil` when the container passed.
    var failure: BundleValidationCheck? {
        checks.first { !$0.passed }
    }

    /// A one-line summary of the report for diagnostics.
    var summary: String {
        if isAccepted {
            return "Bundle validation passed \(checks.count) of \(checks.count) checks"
        }
        let failed = checks.filter { !$0.passed }.count
        return "Bundle validation failed \(failed) of \(checks.count) checks"
    }
}
