import Foundation

/// One entry in the in-app version history.
struct VersionHistoryEntry: Equatable, Hashable, Sendable {
    /// The release tag, e.g. `v0.0.1-dev.2`.
    let tag: String
    /// The marketing version the entry shipped as.
    let marketingVersion: String
    /// The build number the entry shipped as.
    let buildNumber: Int
    /// The date the stop was cut.
    let releasedAt: DateComponents
    /// One line of what this stop is about.
    let headline: String
    /// The changes worth reading, one bullet each.
    let highlights: [String]
    /// Whether this is the stop the current build is cut from.
    var isCurrent: Bool = false
}

/// The in-app version history: every stop on the release train this build
/// knows about, newest first, with the honest summary of what each stop
/// switched on. The data mirrors `CHANGELOG.md`; the file remains the
/// complete record, and this catalog is the readable digest the interface
/// shows.
enum VersionHistoryCatalog {

    /// Every entry, newest first.
    static let entries: [VersionHistoryEntry] = [
        VersionHistoryEntry(
            tag: "v0.0.1",
            marketingVersion: "0.0.1",
            buildNumber: 5,
            releasedAt: DateComponents(year: 2026, month: 10, day: 1),
            headline: "The first build: the whole shell, import, Library, and the honest Settings — no staged feature switches on.",
            highlights: [
                "Settings gains its Security row: the app lock, session timeout, and sensitive-data rules are reachable at last.",
                "The landing-tab picker offers only tabs the bar can actually select.",
                "The first stop past the development rehearsals; it switches on no staged feature of its own.",
                "The dev.3 gate drift is carried, not resolved: four surfaces stay open ahead of their declared stops.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.0.1-dev.3",
            marketingVersion: "0.0.1",
            buildNumber: 4,
            releasedAt: DateComponents(year: 2026, month: 10, day: 1),
            headline: "The last rehearsal before the first build: the import, identity and shell fixes, with the gate drift recorded as it stands.",
            highlights: [
                "A `.p12` import no longer demands a Keychain protection class the platform cannot set.",
                "An Open In hand-off opens the Import Hub once ZynSign is active again.",
                "The bar never asks UIKit for a sixth tab, so no tab is pushed into a nested stack.",
                "Reset Library reports its failure instead of counting zero removals.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.0.1-dev.2",
            marketingVersion: "0.0.1",
            buildNumber: 3,
            releasedAt: DateComponents(year: 2026, month: 9, day: 30),
            headline: "Proves the pipeline and the core; no staged feature switches on.",
            highlights: [
                "Release gate now applied to Certificate Studio, Profiles, Store and Downloads.",
                "Smart Workspace construction gated to its declared stop.",
                "Version badge tooling fixed for every pre-release form.",
                "Local pre-flight for the quality gates added.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.1.0-alpha.3",
            marketingVersion: "0.1.0",
            buildNumber: 2,
            releasedAt: DateComponents(year: 2026, month: 9, day: 29),
            headline: "Ten staged features, seven first reachable in a Release build.",
            highlights: [
                "Certificate Studio, Library power features, Smart Sign.",
                "Provisioning Profile Manager and Professional Signing Queue.",
                "Intelligent signing presets and the Developer Identity Center.",
                "App Store with repository health, Download Center, Entitlements Studio.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.0.1-dev.1",
            marketingVersion: "0.0.1",
            buildNumber: 2,
            releasedAt: DateComponents(year: 2026, month: 9, day: 29),
            headline: "First stop on the release train: the core, nothing staged.",
            highlights: [
                "Files, Library, Home and Settings shell in a Release build.",
                "Import boundary, durable library, and bundle explorer wired.",
                "Release train and staged-feature gate established.",
            ]
        ),
    ]

    /// The entries with the current stop marked.
    static func entries(currentTag: String) -> [VersionHistoryEntry] {
        entries.map { entry in
            var marked = entry
            marked.isCurrent = entry.tag == currentTag
            return marked
        }
    }
}
