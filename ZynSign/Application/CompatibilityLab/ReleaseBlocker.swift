import Foundation

/// How badly an issue blocks a release.
///
/// The classification exists so release decisions stay consistent: the
/// action a level demands is written down once, here, and the Lab, the QA
/// checklist and the release notes all read the same answer. The severity of
/// a *check* is what a failure of that check would mean, which is why a
/// check that cannot run still carries a severity — an unrun check is an
/// open question, and the table says how much that costs the release.
enum ReleaseBlockerSeverity: String, CaseIterable, Codable, Sendable, Comparable {

    /// Breaks a core workflow, loses or corrupts user data, or exposes
    /// signing material.
    case critical

    /// Breaks a major workflow with no acceptable workaround.
    case high

    /// Degrades a workflow that still completes, or breaks an edge case.
    case medium

    /// Cosmetic, rare, or already documented as a known limitation.
    case low

    /// The action this level demands of the release train.
    var action: String {
        switch self {
        case .critical: return "Block the release candidate"
        case .high: return "Fix before RC 2"
        case .medium: return "Fix during the RC cycle"
        case .low: return "Can wait for 1.0.x"
        }
    }

    /// The level's name.
    var displayName: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Whether an open issue at this level stops this candidate from being
    /// called an RC.
    var blocksReleaseCandidate: Bool { self == .critical }

    /// Whether an open issue at this level must be closed before the next
    /// candidate is cut.
    var blocksNextCandidate: Bool { self == .critical || self == .high }

    /// One sentence on what qualifies, so two people classify alike.
    var guidance: String {
        switch self {
        case .critical:
            return "A core workflow cannot complete, data is lost or corrupted, or signing material is exposed."
        case .high:
            return "A major workflow fails or is unreachable, and no workaround completes it."
        case .medium:
            return "A workflow completes but degrades, or a bounded edge case misbehaves."
        case .low:
            return "Cosmetic, rare, or a limitation ZynSign already documents honestly."
        }
    }

    static func < (lhs: ReleaseBlockerSeverity, rhs: ReleaseBlockerSeverity) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ severity: ReleaseBlockerSeverity) -> Int {
        switch severity {
        case .critical: return 3
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }
}

/// One tracked issue, in the state it is in today.
///
/// The registry is deliberately short and honest: it records what ZynSign
/// cannot do — because the platform does not allow it, or because a check
/// has not been executed on a device — rather than only what it can. An
/// entry nobody has to discover twice is the point.
struct ReleaseBlockerRecord: Identifiable, Codable, Equatable, Sendable {

    /// Whether the record is still open.
    enum State: String, Codable, CaseIterable, Sendable {
        /// Open and awaiting work or a decision.
        case open
        /// Accepted for this release with a documented workaround or limit.
        case accepted
        /// Resolved; kept so the release notes can name it.
        case resolved

        var displayName: String {
            switch self {
            case .open: return "Open"
            case .accepted: return "Accepted"
            case .resolved: return "Resolved"
            }
        }

        /// Whether this record still counts against the release.
        var countsAgainstRelease: Bool { self == .open }
    }

    let id: String
    let title: String
    let severity: ReleaseBlockerSeverity
    let area: CompatibilityCategory
    let state: State
    /// What ZynSign does today instead, or what the user should do.
    let disposition: String

    /// The records ZynSign ships with, in the order a reviewer should read
    /// them: the platform facts first, then what still needs a device.
    ///
    /// Every entry is a real, documented limit of this build. None is
    /// invented to populate the table, and none is closed by calling it
    /// closed: `accepted` records name what the user does instead.
    static let registry: [ReleaseBlockerRecord] = [
        ReleaseBlockerRecord(
            id: "installation.deliveryMechanism",
            title: "In-app installation has no available mechanism",
            severity: .low,
            area: .iOSCompatibility,
            state: .accepted,
            disposition: "ZynSign builds the OTA manifest, the install link and the QR code and hands off; it never claims an install. Settings → Installation keeps the typed assessment."
        ),
        ReleaseBlockerRecord(
            id: "compatibility.deviceLab",
            title: "Device and iOS matrices need physical-device confirmation",
            severity: .medium,
            area: .deviceCompatibility,
            state: .open,
            disposition: "The Lab executes on the device it runs on and records every other row as not run. Run the Lab on each supported device class and iOS version, then import the reports."
        ),
        ReleaseBlockerRecord(
            id: "compatibility.signingExecution",
            title: "Signing scenarios stop at preparation without signing material",
            severity: .medium,
            area: .signingPipeline,
            state: .open,
            disposition: "Scenarios verify the reproducible preparation stages — structure, metadata, nested discovery, plan validation. Executing a real signature needs an identity and a profile on the device."
        ),
        ReleaseBlockerRecord(
            id: "performance.simulatorOnly",
            title: "Performance figures measured on a simulator are not device figures",
            severity: .low,
            area: .performance,
            state: .accepted,
            disposition: "The report names the device class it ran on. A row measured on a simulator is marked as such and is never compared against a device benchmark."
        )
    ]

    /// The records that still count against this release candidate.
    static var openRecords: [ReleaseBlockerRecord] {
        registry.filter { $0.state.countsAgainstRelease }
    }

    /// The worst severity still counting against the release.
    static var worstOpenSeverity: ReleaseBlockerSeverity? {
        openRecords.map(\.severity).max()
    }
}
