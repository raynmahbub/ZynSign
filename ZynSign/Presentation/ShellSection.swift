import Foundation

/// The sections of the ZynSign shell.
///
/// The six primary tabs are the navigation foundation the whole app is built
/// on: Files, Library, Home, App Store, Downloads, Settings. Certificates and
/// Profiles are real, complete areas that are reached from Settings rather
/// than the tab bar; their place in the shell is a presentation decision, not
/// a statement about the features themselves.
///
/// The shell is a pure presentation concern — it decides order, titles and
/// icons, nothing about workflow logic.
enum ShellSection: Hashable, CaseIterable, Identifiable {
    case home
    case library
    case certificates
    case profiles
    case settings
    case files
    case appStore
    case downloads
    case presets
    case install

    var id: Self { self }

    /// The tab-capable sections, in the order the user sees them:
    /// Files · Library · Home · App Store · Downloads · Settings.
    ///
    /// Certificates and Profiles are deliberately *not* tabs. They remain
    /// complete, reachable areas reached from Settings → Browse, because
    /// the bottom bar is for the six areas a user moves between constantly
    /// and six is already the practical ceiling on a phone.
    ///
    /// This is the full list, not the list a given release shows — use
    /// `primaryTabs` for that.
    static let allTabs: [ShellSection] = [.files, .library, .home, .appStore, .downloads, .settings]

    /// The staged feature that unlocks this section, or `nil` when the
    /// section is part of the core shell and always present.
    ///
    /// The release train exposes features progressively, so a section that
    /// belongs to a staged feature must not be reachable before its stop.
    /// Certificates, Profiles, the Store, Downloads, Presets and the
    /// Installation Workspace all arrive at a named stop; Files, Library,
    /// Home and Settings are the core the dev stops exist to prove.
    var requiredFeature: ReleaseFeature? {
        switch self {
        case .certificates: return .certificateStudio
        case .profiles: return .provisioningProfileManager
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .presets: return .signingPresets
        case .install: return .installationWorkspace
        case .home, .library, .settings, .files: return nil
        }
    }

    /// The tabs a release shows, given an availability test.
    ///
    /// Taking the test as a parameter — rather than reading the train
    /// directly — is what lets the gating be tested at every stop without
    /// pretending the test host is running at some other stage.
    static func primaryTabs(where isAvailable: (ReleaseFeature) -> Bool) -> [ShellSection] {
        allTabs.filter { $0.requiredFeature.map(isAvailable) ?? true }
    }

    /// The sections that appear as tabs in the bottom navigation at the
    /// release this build is cut for.
    ///
    /// A tab can therefore be absent before its stop. That is a deliberate
    /// change of direction: the bar used to be exempt from the gate, because
    /// a tab that comes and goes is a tab a user cannot rely on. The release
    /// strategy outranks that argument — a development stop exists to prove
    /// the pipeline and is documented as showing the core only, so a Store
    /// tab in it would misrepresent the release. Every caller that remembers
    /// a tab across launches must go through `RootView.visibleSelection(for:)`,
    /// which clamps to a tab this stop actually shows.
    static var primaryTabs: [ShellSection] {
        primaryTabs(where: ReleaseTrain.isAvailable)
    }

    /// The navigation title of the section.
    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .certificates: return "Certificates"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        case .files: return "Files"
        case .appStore: return "Store"
        case .downloads: return "Downloads"
        case .presets: return "Presets"
        case .install: return "Install"
        }
    }

    /// The SF Symbol shown for the section's tab and navigation entry.
    var symbolName: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .certificates: return "signature"
        case .profiles: return "person.text.rectangle"
        case .settings: return "gearshape.fill"
        case .files: return "folder.fill"
        case .appStore: return "bag.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .presets: return "rectangle.stack.fill"
        case .install: return "arrow.down.app.fill"
    }
    }

    /// The symbol for the unselected state (used where a filled variant is too heavy).
    var symbolNameUnselected: String {
        switch self {
        case .home: return "house"
        case .library: return "square.grid.2x2"
        case .certificates: return "signature"
        case .profiles: return "person.text.rectangle"
        case .settings: return "gearshape"
        case .files: return "folder"
        case .appStore: return "bag"
        case .downloads: return "arrow.down.circle"
        case .presets: return "rectangle.stack"
        case .install: return "arrow.down.app"
        }
    }

    /// An honest description of what the section is for. Used by
    /// `PlaceholderFeatureView` only if a section has no dedicated view yet —
    /// none of the eight do, so this is a fallback for previews and
    /// diagnostics.
    var statusSummary: String {
        switch self {
        case .home:
            return "Overview of the library, quick actions, and what was imported most recently."
        case .library:
            return "Imported packages recorded in ZynSign's library — searchable, sortable, kept across launches, with the files inside each application bundle listed read-only."
        case .certificates:
            return "Signing identities in the Keychain — imported from .p12 containers, inspected, and never exportable with their private keys."
        case .profiles:
            return "Imported provisioning profiles — searchable, sortable, and filterable, with expiration countdowns, pre-sign compatibility checks, actionable diagnostics, and per-app suggestions."
        case .settings:
            return "Signing preferences, appearance, storage, diagnostics, and the honest capability screens."
        case .files:
            return "Browse and manage files ZynSign keeps — imported packages, working copies, and exported artifacts. Import, share, move and delete without leaving the app."
        case .appStore:
            return "Discover and download applications from your configured sources."
        case .downloads:
            return "Download packages, validate them before import, and review updates from configured sources."
        case .presets:
            return "Reusable signing presets — certificate and profile references, options, and live compatibility. Presets do not store secrets."
        case .install:
            return "The Installation Workspace — readiness checklists, the Installed Apps Library, delivery attempts you confirm yourself, history, and storage. ZynSign validates and records; delivery is yours."
        }
    }
}

extension LandingTab {

    /// The shell section a landing-tab preference names.
    ///
    /// The mapping lives here rather than in the preference so a change to the
    /// shell's tabs does not change what a stored preference means.
    var shellSection: ShellSection {
        switch self {
        case .files: return .files
        case .library: return .library
        case .home: return .home
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .settings: return .settings
        case .certificates: return .certificates
        case .profiles: return .profiles
        }
    }
}
