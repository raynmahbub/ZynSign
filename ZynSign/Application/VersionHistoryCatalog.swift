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
            tag: "v3.0.0",
            marketingVersion: "3.0.0",
            buildNumber: 12,
            releasedAt: DateComponents(year: 2026, month: 10, day: 30),
            headline: "3.0.0 completes the Nova release train with unified Free Apple ID and Paid Certificate signing, wire-free loopback device installation, the zero-slot multi-app container, and full package/tweak/WebDAV workspace tooling.",
            highlights: [
                "Unified Signing & Provisioning Hub: choose Free Apple ID (SRP-6a + 2FA + automatic CSR, certificate, Wildcard App ID, App Group, and 7-day profile renewal) or Paid .p12/.zcert Certificates in one workflow.",
                "Wire-Free On-Device Installer & Multi-App Container: stream signed IPAs over loopback lockdownd + AFC + mobile.installation_proxy with a pairing record, or install unlimited ad-hoc signed guest apps inside ZynSign's zero-slot host container.",
                "Tweak & Binary Studio: .deb (ar + gzip/xz/lzma tar) extraction, Mach-O load-command and rpath inspector, per-dylib injection toggles, Liquid Glass SDK v26 patcher, and PPQ protection.",
                "LAN WebDAV & Portable Workspace: browser drag-and-drop plus Finder/Windows Explorer WebDAV server, Documents/ZynSignPortable mirror, Plist/Hex/Text file editors, and encrypted DNS shield generator.",
                "Build & Hygiene Hardening: resolved Xcode 26.3 API mismatches across local transfer, version comparison, archive permissions, tweak bundle staging, and PKCS#12 file pickers, and removed retired scaffolding.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v3.0.0-nova.1",
            marketingVersion: "3.0.0",
            buildNumber: 11,
            releasedAt: DateComponents(year: 2026, month: 10, day: 28),
            headline: "3.0.0-nova.1 switches on the last staged feature — the Nova Assistant — beside the Sideload Studio, the screen that keeps a free Apple ID's seven-day builds running.",
            highlights: [
                "Nova Assistant: on-device, rule-based suggestions about expiring certificates and profiles, missing signing materials, duplicate bundle identifiers, apps no profile covers, and a backup that is overdue. Every suggestion opens the screen that owns the work; none of them acts.",
                "Sideload Studio: one row per signed application, the earlier of its profile and certificate expiry, the account that signed it against the limits that account publishes, and a re-sign that hands the build back to the ordinary signing flow.",
                "Zeus: violet lightning over deep indigo, and the theme a new install opens on. Every earlier theme stays selectable and a stored choice is never rewritten.",
                "Home gains a refresh row that says what stops launching next, and stays out of the way until the journal has something to report.",
                "The one stop that carried no new gate — v2.0.0 — ships its depth and fixes here; every staged feature the train has carried is now visible.",
                "The three limits stay recorded and unchanged: in-app installation, pairing/JIT/mux, and off-device measurement.",
            ]
        ),
        VersionHistoryEntry(
            tag: "v1.0.0",
            marketingVersion: "1.0.0",
            buildNumber: 10,
            releasedAt: DateComponents(year: 2026, month: 10, day: 28),
            headline: "1.0.0 switches on every staged feature the train has carried — including the Export Center and the signing history that make what you signed findable again.",
            highlights: [
                "Export Center: every signed artifact in one list, with its verification, its provenance, sharing, reveal in Library, and deletion. An artifact whose file is gone stays listed and says so.",
                "Signing History: the journal's own screen, including the runs that produced no artifact — the only place a failed signing is explained in full.",
                "Entitlements Studio, the Developer Identity Center, Mission Control, the installation delivery hand-off, the local activity journal, the Installation Workspace, the Performance Engine dashboard, the Smart Workspace, and the Signing Health Score.",
                "Home becomes the command center: greeting, widgets ordered by what you open, and Continue Last Session. Its import doors are unchanged.",
                "The Nova Assistant is the one staged feature still ahead: it ships at v3.0.0-nova.1.",
            ]
        ),
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
