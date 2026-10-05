import Foundation

/// One entry in the in-app version history.
struct VersionHistoryEntry: Equatable, Hashable, Sendable {
    /// The release tag, e.g. `v0.0.1-dev.2`.
    let tag: String
    /// The marketing version assigned to this train stop.
    let marketingVersion: String
    /// The build number assigned to this train stop.
    let buildNumber: Int
    /// The date this train stop was cut.
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
            tag: "v0.1.0-alpha.2",
            marketingVersion: "0.1.0",
            buildNumber: 8,
            releasedAt: DateComponents(year: 2026, month: 10, day: 5),
            headline: "Alpha 2 opens the signing workflow — Smart Sign, the Professional Signing Queue, and Intelligent Signing Presets — on a new Storefront shell dressed in liquid glass.",
            highlights: [
                "Sign applications from the Library, watch jobs move through the queue's stages, and plan bulk runs from reusable presets: the three surfaces this stage switches on.",
                "Import reads a document's content, not its name: an iCloud file that has not finished downloading is awaited and staged instead of refused, and a renamed or extension-less .p12 imports while a foreign format is refused with the reason.",
                "Settings → Updates now raises each workflow in its own navigation context, closing the last nested-container crash class in the tab; the audit that guards this behaviour covers split views too.",
                "The main screen draws exactly five tabs — Home, Library, Store, Downloads, and Settings — with Files one Settings row away.",
                "The interface renders in liquid glass end to end — cards, tab bar, toolbars, toasts — with a switch to turn it off under Settings → Appearance.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.1.0-alpha.1",
            marketingVersion: "0.1.0",
            buildNumber: 7,
            releasedAt: DateComponents(year: 2026, month: 10, day: 3),
            headline: "Alpha 1 brings Library Power Features to Release builds.",
            highlights: [
                "Organize imported artifacts with favorites, recent items, and custom collections.",
                "Refine Library results with advanced search, filters, bulk selection, and quick actions.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v0.0.2-dev.1",
            marketingVersion: "0.0.2",
            buildNumber: 6,
            releasedAt: DateComponents(year: 2026, month: 10, day: 1),
            headline: "A fixes-only follow-up: stronger external-file imports, a dynamic Features catalogue, and categorized release automation.",
            highlights: [
                "IPA and TIPA picker registration accepts provider-backed file types while keeping archive validation in the import pipeline.",
                "PKCS#12 reads coordinate external-file access, honor security-scoped URLs, and report typed failures.",
                "The Features catalogue is populated from the registered core, release, and unsupported-feature sets.",
                "Release notes are categorized automatically and can be synchronized into the changelog through a reviewable pull request.",
            ]
        ),
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
